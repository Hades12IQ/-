import Foundation
import Observation

private nonisolated struct AgentMissionPointer: Codable, Equatable, Sendable {
    let ownerID: String
    let jobID: String?
    let cid: String
    let task: String
    let title: String
    let tier: ModelTier
    let language: AppLanguage
    let startedAt: Date

    func with(jobID: String) -> AgentMissionPointer {
        AgentMissionPointer(
            ownerID: ownerID,
            jobID: jobID,
            cid: cid,
            task: task,
            title: title,
            tier: tier,
            language: language,
            startedAt: startedAt
        )
    }
}

nonisolated struct AgentStepRow: Equatable, Identifiable, Sendable {
    let id: String
    let step: AgentStep
}

nonisolated struct AgentToolRow: Equatable, Identifiable, Sendable {
    let id: String
    let tool: AgentTool
}

nonisolated struct AgentSpeechRow: Equatable, Identifiable, Sendable {
    let id: String
    let text: String
}

@MainActor
@Observable
final class AgentStore {
    private(set) var currentJob: AgentJob?
    private(set) var pendingTask = ""
    private(set) var pendingTitle = ""
    private(set) var startedAt: Date?
    private(set) var isStarting = false
    private(set) var activeJobID: String?
    private(set) var sharedArtifactURLs: [Int: URL] = [:]
    private(set) var stepRows: [AgentStepRow] = []
    private(set) var toolRows: [AgentToolRow] = []
    private(set) var speechRows: [AgentSpeechRow] = []
    var errorMessage: String?

    @ObservationIgnored private let api: FirasAPI
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var owningTask: Task<Void, Never>?

    private static let pointerMapKey = "firas.ios.agent-missions.v1"

    init(
        session: SessionStore,
        api: FirasAPI = FirasAPI(),
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.api = api
        self.defaults = defaults
    }

    var isRunning: Bool {
        isStarting || (currentJob?.phase.isTerminal == false) || activeJobID != nil
    }

    var activity: AgentActivity? { currentJob?.surface }
    var steps: [AgentStep] { currentJob?.steps ?? [] }
    var files: [AgentFile] { activity?.files ?? [] }
    var finalText: String {
        guard let raw = currentJob?.final, !raw.isEmpty else { return "" }
        let marker = "```firas-agent"
        guard let start = raw.range(of: marker),
              let close = raw.range(of: "\n```", options: .backwards),
              start.upperBound <= close.lowerBound
        else { return raw }
        let payload = raw[start.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = payload.data(using: .utf8),
              let fenced = try? JSONDecoder().decode(AgentJob.self, from: data)
        else { return raw }
        return fenced.final
    }

    func start(
        task: String,
        tier: ModelTier,
        language: AppLanguage
    ) {
        let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTask.isEmpty, !isRunning else { return }
        guard session.isAuthenticated, let ownerID = session.identityID else {
            errorMessage = language == .arabic
                ? "سجّل الدخول لبدء مهمة Agent وحفظها في السحابة."
                : "Sign in to start an Agent mission and keep it running in the cloud."
            return
        }

        let pointer = AgentMissionPointer(
            ownerID: ownerID,
            jobID: nil,
            cid: stableIdentifier(),
            task: String(cleanTask.prefix(120_000)),
            title: suggestedTitle(cleanTask),
            tier: tier,
            language: language,
            startedAt: Date()
        )

        pendingTask = pointer.task
        pendingTitle = pointer.title
        startedAt = pointer.startedAt
        currentJob = nil
        activeJobID = nil
        sharedArtifactURLs = [:]
        stepRows = []
        toolRows = []
        speechRows = []
        errorMessage = nil
        isStarting = true
        persist(pointer)

        // This task is owned by the store. A product switch may remove the
        // screen, but it never calls the server cancellation route and the
        // durable mission continues. The pointer reattaches after relaunch.
        owningTask = Task {
            await self.enqueueAndPoll(pointer)
        }
    }

    func resumeIfNeeded() {
        guard owningTask == nil, activeJobID == nil else { return }
        guard let ownerID = session.identityID,
              let pointer = persistedPointer(for: ownerID)
        else { return }

        pendingTask = pointer.task
        pendingTitle = pointer.title
        startedAt = pointer.startedAt
        activeJobID = pointer.jobID
        isStarting = pointer.jobID == nil
        errorMessage = nil

        owningTask = Task {
            if pointer.jobID == nil {
                await self.enqueueAndPoll(pointer)
            } else {
                await self.poll(pointer)
            }
        }
    }

    func clearFinishedMission() {
        guard !isRunning else { return }
        if let ownerID = session.identityID {
            removePersistedPointer(for: ownerID)
        }
        currentJob = nil
        pendingTask = ""
        pendingTitle = ""
        startedAt = nil
        errorMessage = nil
        sharedArtifactURLs = [:]
        stepRows = []
        toolRows = []
        speechRows = []
    }

    func downloadArtifact(at index: Int) async {
        guard sharedArtifactURLs[index] == nil,
              let jobID = currentJob?.id ?? activeJobID,
              files.indices.contains(index)
        else { return }

        errorMessage = nil
        do {
            let artifact = try await api.agentArtifact(jobID: jobID, index: index, download: true)
            let url = try await Task.detached(priority: .userInitiated) {
                try AgentArtifactWriter.write(artifact)
            }.value
            sharedArtifactURLs[index] = url
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func enqueueAndPoll(_ initialPointer: AgentMissionPointer) async {
        guard session.identityID == initialPointer.ownerID else {
            finishLocalOwnership()
            return
        }

        var recoveryAttempt = 0
        while !Task.isCancelled {
            do {
                // The quota route and queue are both idempotent for this cid.
                // If the app stopped between them, resume repeats the same cid.
                _ = try await api.chargeUsage(product: .agent, cid: initialPointer.cid)

                let request = ChatJobRequest(
                    messages: [
                        ChatMessage(
                            role: .user,
                            content: initialPointer.task,
                            lang: initialPointer.language.rawValue
                        )
                    ],
                    tier: initialPointer.tier,
                    thinking: true,
                    cid: initialPointer.cid,
                    product: .agent,
                    kind: .agentRun,
                    languageCode: initialPointer.language.rawValue,
                    task: initialPointer.task,
                    title: initialPointer.title
                )
                let start = try await startJobWithRetry(request)
                guard session.identityID == initialPointer.ownerID else {
                    finishLocalOwnership()
                    return
                }

                let pointer = initialPointer.with(jobID: start.jobId)
                persist(pointer)
                activeJobID = start.jobId
                isStarting = false
                requestCompletionNotifications(language: initialPointer.language)
                await poll(pointer)
                return
            } catch {
                guard session.identityID == initialPointer.ownerID else {
                    finishLocalOwnership()
                    return
                }

                errorMessage = message(for: error)
                guard retryable(error) else {
                    removePersistedPointer(for: initialPointer.ownerID)
                    isStarting = false
                    activeJobID = nil
                    owningTask = nil
                    return
                }

                // A response may be lost after the server accepted the job.
                // Stay attached to the same cid and retry in the store; never
                // expose a fresh composer that could overwrite this pointer.
                recoveryAttempt += 1
                isStarting = true
                do {
                    try await Task.sleep(for: recoveryDelay(attempt: recoveryAttempt))
                } catch {
                    return
                }
            }
        }
    }

    private func poll(_ pointer: AgentMissionPointer) async {
        guard let jobID = pointer.jobID else { return }
        activeJobID = jobID
        isStarting = false
        var misses = 0
        var failures = 0
        let pollingBegan = Date()

        while !Task.isCancelled {
            guard session.identityID == pointer.ownerID else {
                finishLocalOwnership()
                return
            }

            do {
                if let job = try await api.agentJobStatus(id: jobID) {
                    misses = 0
                    failures = 0

                    if job.phase.isTerminal {
                        guard await FirasCompletionCue.prepareForReveal(
                            product: .agent,
                            jobID: jobID
                        ),
                        !Task.isCancelled,
                        session.identityID == pointer.ownerID
                        else { return }

                        currentJob = job
                        updateRows(from: job)
                        errorMessage = nil
                        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
                            product: .agent,
                            jobID: jobID,
                            chatID: nil,
                            outcome: job.phase == .done ? .completed : .failed
                        )
                        removePersistedPointer(for: pointer.ownerID)
                        activeJobID = nil
                        owningTask = nil
                        if job.phase == .fail, !job.error.isEmpty {
                            errorMessage = job.error
                        }
                        return
                    } else {
                        currentJob = job
                        updateRows(from: job)
                        errorMessage = nil
                    }
                } else {
                    misses += 1
                    if misses >= 5 {
                        throw APIError.invalidResponse
                    }
                }
            } catch {
                failures += 1
                if failures >= 3 {
                    errorMessage = message(for: error)
                }
            }

            let elapsed = Date().timeIntervalSince(pollingBegan)
            let delay: Duration = elapsed < 20 ? .milliseconds(700)
                : elapsed < 120 ? .milliseconds(1_200) : .milliseconds(2_500)
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func startJobWithRetry(_ request: ChatJobRequest) async throws -> ChatJobStartResponse {
        let delays: [Duration] = [.milliseconds(350), .milliseconds(800)]
        for attempt in 0...delays.count {
            do {
                return try await api.startChatJob(request)
            } catch {
                guard attempt < delays.count, retryable(error) else { throw error }
                try await Task.sleep(for: delays[attempt])
            }
        }
        throw APIError.transport(code: -1, message: "The Agent mission could not be queued.")
    }

    private func updateRows(from job: AgentJob) {
        stepRows = job.steps.enumerated().map { index, step in
            AgentStepRow(id: "\(job.id)-step-\(index)", step: step)
        }
        toolRows = (job.surface?.tools ?? []).enumerated().map { index, tool in
            AgentToolRow(id: "\(job.id)-tool-\(index)", tool: tool)
        }
        let says = job.surface?.says ?? []
        let live = job.surface?.live ?? []
        let narration = says.isEmpty ? live : says
        speechRows = narration.enumerated().map { index, text in
            AgentSpeechRow(id: "\(job.id)-speech-\(index)", text: text)
        }
    }

    private func retryable(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .transport:
            true
        case .httpStatus(let code, _):
            (500...599).contains(code)
        case .invalidResponse, .decoding:
            true
        case .invalidURL, .invalidRequest, .encoding:
            false
        }
    }

    private func recoveryDelay(attempt: Int) -> Duration {
        switch attempt {
        case ...1: .seconds(2)
        case 2: .seconds(4)
        case 3: .seconds(8)
        default: .seconds(15)
        }
    }

    private func requestCompletionNotifications(language: AppLanguage) {
        Task {
            _ = await NotificationCoordinator.shared.requestAuthorizationIfNeeded(
                context: .durableJobStarted,
                preferredLanguageCode: language.rawValue
            )
        }
    }

    private func finishLocalOwnership() {
        currentJob = nil
        activeJobID = nil
        isStarting = false
        owningTask = nil
        errorMessage = nil
    }

    private func suggestedTitle(_ task: String) -> String {
        let line = task
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(line.prefix(80))
    }

    private func stableIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func pointerMap() -> [String: AgentMissionPointer] {
        guard let data = defaults.data(forKey: Self.pointerMapKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentMissionPointer].self, from: data)) ?? [:]
    }

    private func persistedPointer(for ownerID: String) -> AgentMissionPointer? {
        pointerMap()[ownerID]
    }

    private func persist(_ pointer: AgentMissionPointer) {
        var map = pointerMap()
        map[pointer.ownerID] = pointer
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.pointerMapKey)
    }

    private func removePersistedPointer(for ownerID: String) {
        var map = pointerMap()
        map.removeValue(forKey: ownerID)
        if map.isEmpty {
            defaults.removeObject(forKey: Self.pointerMapKey)
        } else if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.pointerMapKey)
        }
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "تعذّر الاتصال بالخادم."
        }
        return error.localizedDescription
    }
}

private nonisolated enum AgentArtifactWriter {
    static func write(_ artifact: AgentArtifactDownload) throws -> URL {
        let cleanName = artifact.suggestedFilename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = cleanName.isEmpty ? "firas-artifact" : String(cleanName.prefix(160))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirasArtifacts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename, isDirectory: false)
        try artifact.data.write(to: url, options: .atomic)
        return url
    }
}
