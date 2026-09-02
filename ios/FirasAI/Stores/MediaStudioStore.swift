import Foundation
import Observation
import Photos

@MainActor
@Observable
final class MediaStudioStore {
    private(set) var creations: [MediaCreation] = []
    private(set) var isLoading = false
    private(set) var loadedOwnerID: String?
    var errorMessage: String?
    var confirmationMessage: String?

    @ObservationIgnored private let api: FirasAPI
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let repository: MediaAssetRepository
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var workTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadingTask: Task<Void, Never>?

    private static let historyMapKey = "firas.ios.media-studio.history.v1"
    private static let historyLimit = 24

    init(
        api: FirasAPI,
        session: SessionStore,
        repository: MediaAssetRepository = MediaAssetRepository(),
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.session = session
        self.repository = repository
        self.defaults = defaults
    }

    var activeCreations: [MediaCreation] {
        creations.filter(\.phase.isActive)
    }

    var finishedCreations: [MediaCreation] {
        creations.filter { !$0.phase.isActive }
    }

    /// Lets the Chat notification router distinguish a Create job from an
    /// ordinary `.ai` chat job without inventing a separate ProductKind. It can
    /// answer from the durable pointer table before Media Studio has appeared.
    func kind(forNotificationJobID jobID: String) -> MediaStudioKind? {
        guard !jobID.isEmpty, let ownerID = session.identityID else { return nil }
        if let match = creations.first(where: { $0.ownerID == ownerID && $0.jobID == jobID }) {
            return match.kind
        }
        return historyMap()[ownerID]?.first(where: { $0.jobID == jobID })?.kind
    }

    /// Reconnects a terminal push route to its durable server job. This also
    /// repairs an older local timeout/failure marker: the server notification is
    /// authoritative and the same job id can still resolve its cached result.
    func resumeNotificationJob(jobID: String, kind: MediaStudioKind) {
        guard !jobID.isEmpty, let ownerID = session.identityID else { return }
        if loadedOwnerID != ownerID {
            adopt(ownerID: ownerID, creations: historyMap()[ownerID] ?? [])
        }

        if let existing = creations.first(where: { $0.ownerID == ownerID && $0.jobID == jobID }) {
            if existing.phase == .completed, existing.resultKey != nil {
                if !hasReadableLocalAsset(existing) {
                    beginHydration(for: existing.id, language: currentLanguage())
                }
                return
            }
            update(existing.id) {
                $0.phase = .running
                $0.errorCode = nil
            }
            persistCurrentHistory()
            beginWork(for: existing.id, language: currentLanguage())
            return
        }

        let recovered = MediaCreation(
            ownerID: ownerID,
            kind: kind,
            prompt: "",
            phase: .running,
            jobID: jobID
        )
        creations.insert(recovered, at: 0)
        persistCurrentHistory()
        beginWork(for: recovered.id, language: currentLanguage())
    }

    /// Call when the authenticated identity changes and whenever the app becomes
    /// active. The owned tasks deliberately outlive the screen that displays
    /// them; leaving Media Studio never cancels a server render.
    func resumeIfNeeded() {
        let ownerID = session.identityID
        guard ownerID != nil else {
            adopt(ownerID: nil, creations: [])
            return
        }

        if loadedOwnerID == ownerID {
            resumeLoadedCreations()
            return
        }
        guard loadingTask == nil else { return }

        isLoading = true
        loadingTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCurrentOwner()
        }
    }

    func createImage(
        prompt: String,
        preset: ImageAspectPreset,
        language: AppLanguage
    ) {
        create(
            kind: .image,
            prompt: prompt,
            lyrics: nil,
            aspect: preset,
            seconds: nil,
            language: language
        )
    }

    func createVideo(
        prompt: String,
        seconds: Int,
        language: AppLanguage
    ) {
        create(
            kind: .video,
            prompt: prompt,
            lyrics: nil,
            aspect: nil,
            seconds: min(max(seconds, 2), 30),
            language: language
        )
    }

    func createMusic(
        prompt: String,
        lyrics: String,
        seconds: Int,
        language: AppLanguage
    ) {
        create(
            kind: .music,
            prompt: prompt,
            lyrics: lyrics,
            aspect: nil,
            seconds: min(max(seconds, 10), 600),
            language: language
        )
    }

    func retry(_ creation: MediaCreation, language: AppLanguage) {
        guard creation.phase == .failed else { return }
        create(
            kind: creation.kind,
            prompt: creation.prompt,
            lyrics: creation.lyrics,
            aspect: creation.aspect,
            seconds: creation.seconds,
            language: language
        )
    }

    func remove(_ creation: MediaCreation) {
        guard !creation.phase.isActive else { return }
        workTasks[creation.id]?.cancel()
        workTasks[creation.id] = nil
        creations.removeAll { $0.id == creation.id }
        persistCurrentHistory()
        if let url = creation.localFileURL {
            Task { [repository] in try? await repository.remove(url) }
        }
    }

    func saveToPhotos(_ creation: MediaCreation, language: AppLanguage) {
        guard let fileURL = creation.localFileURL,
              creation.kind == .image || creation.kind == .video
        else { return }

        Task { [weak self] in
            guard let self else { return }
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                self.errorMessage = language == .arabic
                    ? "اسمح لفِراس بإضافة الوسائط إلى الصور من إعدادات iPhone."
                    : "Allow Firas to add media to Photos in iPhone Settings."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    if creation.kind == .image {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                    }
                }
                self.confirmationMessage = language == .arabic
                    ? "تم الحفظ في الصور."
                    : "Saved to Photos."
            } catch {
                self.errorMessage = self.message(for: error, language: language)
            }
        }
    }

    func clearMessages() {
        errorMessage = nil
        confirmationMessage = nil
    }

    private func create(
        kind: MediaStudioKind,
        prompt: String,
        lyrics: String?,
        aspect: ImageAspectPreset?,
        seconds: Int?,
        language: AppLanguage
    ) {
        let cleanPrompt = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        let cleanLyrics = lyrics.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6_000))
        }
        guard !cleanPrompt.isEmpty || cleanLyrics?.isEmpty == false else { return }
        guard session.isAuthenticated, let ownerID = session.identityID else {
            errorMessage = language == .arabic
                ? "سجّل الدخول لإنشاء الوسائط وحفظ المهمة في السحابة."
                : "Sign in to create media and keep the job running in the cloud."
            return
        }

        if loadedOwnerID != ownerID {
            adopt(ownerID: ownerID, creations: historyMap()[ownerID] ?? [])
        }
        let creation = MediaCreation(
            ownerID: ownerID,
            kind: kind,
            prompt: cleanPrompt,
            lyrics: cleanLyrics,
            aspect: aspect,
            seconds: seconds
        )
        creations.insert(creation, at: 0)
        trimHistory()
        persistCurrentHistory()
        errorMessage = nil
        confirmationMessage = nil
        beginWork(for: creation.id, language: language)
    }

    private func loadCurrentOwner() async {
        defer {
            isLoading = false
            loadingTask = nil
        }
        guard let ownerID = session.identityID else {
            adopt(ownerID: nil, creations: [])
            return
        }
        adopt(ownerID: ownerID, creations: historyMap()[ownerID] ?? [])
        resumeLoadedCreations()
    }

    private func adopt(ownerID: String?, creations: [MediaCreation]) {
        guard loadedOwnerID != ownerID else { return }
        workTasks.values.forEach { $0.cancel() }
        workTasks.removeAll()
        loadedOwnerID = ownerID
        self.creations = creations.sorted { $0.createdAt > $1.createdAt }
        errorMessage = nil
        confirmationMessage = nil
    }

    private func resumeLoadedCreations() {
        guard let ownerID = loadedOwnerID, session.identityID == ownerID else { return }
        for creation in creations where creation.ownerID == ownerID {
            if creation.phase.isActive {
                beginWork(for: creation.id, language: currentLanguage())
            } else if creation.phase == .completed,
                      creation.resultKey != nil,
                      !hasReadableLocalAsset(creation) {
                beginHydration(for: creation.id, language: currentLanguage())
            }
        }
    }

    private func beginWork(for creationID: UUID, language: AppLanguage) {
        guard workTasks[creationID] == nil else { return }
        workTasks[creationID] = Task { [weak self] in
            guard let self else { return }
            await self.enqueueOrResume(creationID, language: language)
            self.workTasks[creationID] = nil
        }
    }

    private func beginHydration(for creationID: UUID, language: AppLanguage) {
        guard workTasks[creationID] == nil else { return }
        workTasks[creationID] = Task { [weak self] in
            guard let self else { return }
            await self.hydrateCompletedCreation(creationID, language: language)
            self.workTasks[creationID] = nil
        }
    }

    private func enqueueOrResume(_ creationID: UUID, language: AppLanguage) async {
        guard let initial = creation(id: creationID),
              initial.ownerID == session.identityID
        else { return }

        if let jobID = initial.jobID {
            await poll(creationID: creationID, jobID: jobID, language: language)
            return
        }

        var attempt = 0
        while !Task.isCancelled {
            guard let current = creation(id: creationID),
                  current.ownerID == session.identityID
            else { return }
            do {
                let start = try await start(current)
                guard current.ownerID == session.identityID else { return }
                update(creationID) {
                    $0.jobID = start.jobId
                    $0.resultKey = start.key
                    $0.phase = start.key == nil ? .queued : .running
                    $0.errorCode = nil
                }
                persistCurrentHistory()

                _ = await NotificationCoordinator.shared.requestAuthorizationIfNeeded(
                    context: .durableJobStarted,
                    preferredLanguageCode: language.rawValue
                )

                if let key = start.key {
                    await finish(creationID, key: key, language: language)
                } else {
                    await poll(creationID: creationID, jobID: start.jobId, language: language)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                guard retryable(error) else {
                    await fail(creationID, error: error, language: language)
                    return
                }
                if attempt >= 3 {
                    errorMessage = message(for: error, language: language)
                }
                do {
                    try await Task.sleep(for: retryDelay(attempt: attempt))
                } catch {
                    return
                }
            }
        }
    }

    private func start(_ creation: MediaCreation) async throws -> MediaJobStartResponse {
        switch creation.kind {
        case .image:
            return try await api.startImageJob(
                prompt: creation.prompt,
                preset: creation.aspect ?? .square
            )
        case .video:
            return try await api.startVideoJob(
                prompt: creation.prompt,
                seconds: creation.seconds ?? 10
            )
        case .music:
            return try await api.startMusicJob(
                prompt: creation.prompt,
                lyrics: creation.lyrics ?? "",
                seconds: creation.seconds ?? 90
            )
        }
    }

    private func poll(
        creationID: UUID,
        jobID: String,
        language: AppLanguage
    ) async {
        guard creation(id: creationID) != nil else { return }
        update(creationID) { if $0.phase != .completed { $0.phase = .running } }
        persistCurrentHistory()

        var delay: Duration = .milliseconds(1_500)
        var transportFailures = 0

        // The server owns the durable terminal state. A client-side clock must
        // never turn a still-rendering cloud job into a permanent failure.
        while !Task.isCancelled {
            guard let current = creation(id: creationID),
                  current.ownerID == session.identityID
            else { return }
            do {
                let status = try await api.mediaJobStatus(kind: current.kind, id: jobID)
                transportFailures = 0
                switch status.phase.lowercased() {
                case "done", "completed":
                    guard let key = status.key, !key.isEmpty else {
                        try await Task.sleep(for: .seconds(2))
                        continue
                    }
                    await finish(creationID, key: key, language: language)
                    return
                case "fail", "failed":
                    await fail(
                        creationID,
                        code: status.resolvedError ?? "render_failed",
                        language: language
                    )
                    return
                default:
                    update(creationID) { $0.phase = .running }
                }
            } catch is CancellationError {
                return
            } catch {
                transportFailures += 1
                if transportFailures >= 3 {
                    errorMessage = message(for: error, language: language)
                }
            }

            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            delay = nextPollDelay(delay)
        }
    }

    private func finish(_ creationID: UUID, key: String, language: AppLanguage) async {
        guard let current = creation(id: creationID),
              current.ownerID == session.identityID
        else { return }

        guard await FirasCompletionCue.prepareForReveal(
            productID: "media-\(current.kind.rawValue)",
            jobID: current.jobID ?? key
        ),
        !Task.isCancelled,
        current.ownerID == session.identityID
        else { return }

        update(creationID) {
            $0.phase = .completed
            $0.resultKey = key
            $0.errorCode = nil
        }
        persistCurrentHistory()

        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
            product: .ai,
            jobID: current.jobID ?? key,
            chatID: nil,
            mediaKind: current.kind,
            outcome: .completed
        )
        await hydrateCompletedCreation(creationID, language: language)
    }

    private func hydrateCompletedCreation(_ creationID: UUID, language: AppLanguage) async {
        guard let current = creation(id: creationID),
              current.ownerID == session.identityID,
              let key = current.resultKey,
              !hasReadableLocalAsset(current)
        else { return }

        var attempts = 0
        while !Task.isCancelled, attempts < 3 {
            do {
                let download = try await api.mediaAsset(kind: current.kind, key: key)
                let url = try await repository.save(
                    download,
                    kind: current.kind,
                    identifier: key
                )
                update(creationID) {
                    $0.localFileURL = url
                    $0.errorCode = nil
                }
                persistCurrentHistory()
                return
            } catch is CancellationError {
                return
            } catch {
                attempts += 1
                if attempts == 3 {
                    update(creationID) { $0.errorCode = "result_download_pending" }
                    persistCurrentHistory()
                    errorMessage = language == .arabic
                        ? "اكتملت النتيجة، وسنعيد تنزيلها عند عودة الاتصال."
                        : "The result is ready and will download when the connection returns."
                    return
                }
                try? await Task.sleep(for: .seconds(attempts * 2))
            }
        }
    }

    private func fail(_ creationID: UUID, error: Error, language: AppLanguage) async {
        let code: String
        if let apiError = error as? APIError {
            switch apiError {
            case .httpStatus(_, let message): code = message
            default: code = apiError.errorDescription ?? "render_failed"
            }
        } else {
            code = error.localizedDescription
        }
        await fail(creationID, code: code, language: language)
    }

    private func fail(_ creationID: UUID, code: String, language: AppLanguage) async {
        guard let current = creation(id: creationID) else { return }
        update(creationID) {
            $0.phase = .failed
            $0.errorCode = String(code.prefix(200))
        }
        persistCurrentHistory()
        errorMessage = localizedFailure(code, language: language)
        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
            product: .ai,
            jobID: current.jobID ?? current.id.uuidString,
            chatID: nil,
            mediaKind: current.kind,
            outcome: .failed
        )
    }

    private func creation(id: UUID) -> MediaCreation? {
        creations.first { $0.id == id }
    }

    private func update(_ id: UUID, mutate: (inout MediaCreation) -> Void) {
        guard let index = creations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&creations[index])
        creations[index].updatedAt = Date()
    }

    private func hasReadableLocalAsset(_ creation: MediaCreation) -> Bool {
        guard let url = creation.localFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func trimHistory() {
        creations.sort { $0.createdAt > $1.createdAt }
        guard creations.count > Self.historyLimit else { return }
        let active = creations.filter(\.phase.isActive)
        let finished = creations.filter { !$0.phase.isActive }
        creations = Array((active + finished).prefix(Self.historyLimit))
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func historyMap() -> [String: [MediaCreation]] {
        guard let data = defaults.data(forKey: Self.historyMapKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [MediaCreation]].self, from: data)) ?? [:]
    }

    private func persistCurrentHistory() {
        guard let loadedOwnerID else { return }
        trimHistory()
        var map = historyMap()
        map[loadedOwnerID] = creations
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.historyMapKey)
    }

    private func currentLanguage() -> AppLanguage {
        let raw = defaults.string(forKey: "lang") ?? "ar"
        return AppLanguage(rawValue: raw) ?? .arabic
    }

    private func nextPollDelay(_ current: Duration) -> Duration {
        switch current {
        case ..<Duration.seconds(2): .seconds(2)
        case ..<Duration.seconds(3): .seconds(3)
        case ..<Duration.seconds(4): .seconds(4)
        default: .seconds(6)
        }
    }

    private func retryDelay(attempt: Int) -> Duration {
        switch attempt {
        case 1: .milliseconds(500)
        case 2: .seconds(1)
        case 3: .seconds(2)
        case 4: .seconds(4)
        case 5: .seconds(8)
        default: .seconds(15)
        }
    }

    private func retryable(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .transport, .invalidResponse, .decoding:
            return true
        case .httpStatus(let code, let message):
            if code == 503,
               message.lowercased().contains("configured") {
                return false
            }
            return (500...599).contains(code)
        case .invalidURL, .invalidRequest, .encoding:
            return false
        }
    }

    private func localizedFailure(_ code: String, language: AppLanguage) -> String {
        let key = code.lowercased()
        if language == .arabic {
            if key.contains("signin_required") || key.contains("auth") { return "سجّل الدخول لبدء الإنشاء." }
            if key.contains("daily_limit") { return "وصلت إلى حد إنشاء الصور اليومي." }
            if key.contains("rate_window") || key.contains("rate_limited") { return "الإنشاء مزدحم الآن؛ حاول بعد قليل." }
            if key.contains("site_media_ceiling") { return "توقّف إنشاء الوسائط مؤقتاً لحماية الرصيد." }
            if key.contains("not_configured") || key.contains("unconfigured") { return "محرك الوسائط غير متاح حالياً." }
            if key.contains("timeout") { return "استغرقت المهمة وقتاً أطول من المتوقع. يمكنك المحاولة مجدداً." }
            return "تعذّر إكمال الإنشاء. جرّب وصفاً مختلفاً أو أعد المحاولة."
        }
        if key.contains("signin_required") || key.contains("auth") { return "Sign in to start creating." }
        if key.contains("daily_limit") { return "You reached today's image creation limit." }
        if key.contains("rate_window") || key.contains("rate_limited") { return "Creation is busy right now. Try again shortly." }
        if key.contains("site_media_ceiling") { return "Media creation is temporarily paused to protect capacity." }
        if key.contains("not_configured") || key.contains("unconfigured") { return "The media engine is currently unavailable." }
        if key.contains("timeout") { return "This job took longer than expected. You can try it again." }
        return "Creation could not finish. Try another brief or retry."
    }

    private func message(for error: Error, language: AppLanguage) -> String {
        if let apiError = error as? APIError {
            return localizedFailure(apiError.errorDescription ?? "network", language: language)
        }
        return language == .arabic ? "تعذّر إكمال العملية." : error.localizedDescription
    }
}

actor MediaAssetRepository {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directory = root
                .appendingPathComponent("FirasAI", isDirectory: true)
                .appendingPathComponent("MediaStudio", isDirectory: true)
        }
    }

    func save(
        _ download: AgentArtifactDownload,
        kind: MediaStudioKind,
        identifier: String
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let safeID = String(identifier.filter { $0.isLetter || $0.isNumber }.prefix(64))
        let filename = "firas-\(kind.rawValue)-\(safeID).\(fileExtension(download.mimeType, kind: kind))"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try download.data.write(to: url, options: .atomic)
        return url
    }

    func remove(_ url: URL) throws {
        let resolvedDirectory = directory.standardizedFileURL
        let resolvedURL = url.standardizedFileURL
        guard resolvedURL.deletingLastPathComponent() == resolvedDirectory else { return }
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            try FileManager.default.removeItem(at: resolvedURL)
        }
    }

    private func fileExtension(_ mimeType: String, kind: MediaStudioKind) -> String {
        let mime = mimeType.lowercased()
        if mime.contains("jpeg") { return "jpg" }
        if mime.contains("png") { return "png" }
        if mime.contains("webp") { return "webp" }
        if mime.contains("quicktime") { return "mov" }
        if mime.contains("mp4") { return "mp4" }
        if mime.contains("wav") { return "wav" }
        if mime.contains("mpeg") || mime.contains("mp3") { return "mp3" }
        return switch kind {
        case .image: "png"
        case .video: "mp4"
        case .music: "mp3"
        }
    }
}
