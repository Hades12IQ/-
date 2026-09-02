import Foundation

nonisolated struct FirasAPI: Sendable {
    private let client: APIClient

    init(baseURL: URL) {
        client = APIClient(baseURL: baseURL)
    }

    @MainActor
    init(configuration: AppConfiguration = .live) {
        self.init(baseURL: configuration.apiBaseURL)
    }

    func login(email: String, password: String) async throws -> User {
        let envelope: UserEnvelope = try await client.request(
            .post,
            path: "/api/auth/login",
            body: LoginRequest(email: email, password: password)
        )
        return envelope.user
    }

    func signInWithFirebaseIDToken(_ idToken: String) async throws -> User {
        let token = idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 20, token.count <= 8_192 else {
            throw APIError.invalidRequest("A valid Firebase ID token is required.")
        }

        let envelope: UserEnvelope = try await client.request(
            .post,
            path: "/api/auth/firebase",
            body: FirebaseIDTokenRequest(idToken: token)
        )
        return envelope.user
    }

    /// Exchanges an authorization code created by the configured iOS Google
    /// OAuth client. This deliberately does not call `/api/auth/firebase`:
    /// Google's ID token has a different issuer/audience and must first be
    /// exchanged for a Firebase ID token by Firebase Auth.
    func exchangeGoogleAuthorizationCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> GoogleOAuthCodeExchangeResponse {
        let authorizationCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorizationCode.isEmpty, authorizationCode.count <= 8_192 else {
            throw APIError.invalidRequest("A Google authorization code is required.")
        }
        guard (43...128).contains(verifier.count),
              verifier.unicodeScalars.allSatisfy(Self.isPKCEVerifierScalar)
        else {
            throw APIError.invalidRequest("The PKCE code verifier is invalid.")
        }

        return try await client.request(
            .post,
            path: "/api/oauth/google/exchange",
            body: GoogleOAuthCodeExchangeRequest(
                code: authorizationCode,
                codeVerifier: verifier
            )
        )
    }

    func signInWithGoogleNative(
        _ authorization: GoogleNativeAuthorization
    ) async throws -> User {
        let code = authorization.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = authorization.codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonce = authorization.nonce.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (8...8_192).contains(code.count) else {
            throw APIError.invalidRequest("A Google authorization code is required.")
        }
        guard (43...128).contains(verifier.count),
              verifier.unicodeScalars.allSatisfy(Self.isPKCEVerifierScalar)
        else {
            throw APIError.invalidRequest("The PKCE code verifier is invalid.")
        }
        guard (16...256).contains(nonce.count),
              nonce.unicodeScalars.allSatisfy(Self.isBase64URLScalar)
        else {
            throw APIError.invalidRequest("The Google OpenID nonce is invalid.")
        }

        let envelope: UserEnvelope = try await client.request(
            .post,
            path: "/api/auth/google-native",
            body: GoogleNativeAuthRequest(
                authorization: GoogleNativeAuthorization(
                    code: code,
                    codeVerifier: verifier,
                    nonce: nonce
                )
            )
        )
        return envelope.user
    }

    func signup(name: String, email: String, password: String) async throws -> SignupResponse {
        try await client.request(
            .post,
            path: "/api/auth/signup",
            body: SignupRequest(name: name, email: email, password: password)
        )
    }

    func verifySignup(token: String) async throws -> User {
        let envelope: VerifiedUserEnvelope = try await client.request(
            .post,
            path: "/api/auth/verify-signup",
            body: VerifySignupRequest(token: token)
        )
        return envelope.user
    }

    func verificationStatus(pid: String) async throws -> VerificationStatusResponse {
        try await client.request(
            .post,
            path: "/api/auth/verify-status",
            body: VerificationStatusRequest(pid: pid)
        )
    }

    func me() async throws -> User {
        let envelope: UserEnvelope = try await client.request(.get, path: "/api/auth/me")
        return envelope.user
    }

    func changeEmail(currentPassword: String, newEmail: String) async throws -> User {
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...254).contains(email.count), email.contains("@") else {
            throw APIError.invalidRequest("A valid email address is required.")
        }
        guard currentPassword.count <= 200 else {
            throw APIError.invalidRequest("The current password is too long.")
        }

        let response: ChangeEmailResponse = try await client.request(
            .post,
            path: "/api/auth/change-email",
            body: ChangeEmailRequest(current: currentPassword, email: email)
        )
        return response.user
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        guard currentPassword.count <= 200, (8...200).contains(newPassword.count) else {
            throw APIError.invalidRequest("Password must contain between 8 and 200 characters.")
        }

        let _: OperationResponse = try await client.request(
            .post,
            path: "/api/auth/change-password",
            body: ChangePasswordRequest(current: currentPassword, password: newPassword)
        )
    }

    func deleteAccount(currentPassword: String) async throws {
        guard currentPassword.count <= 200 else {
            throw APIError.invalidRequest("The current password is too long.")
        }

        let _: OperationResponse = try await client.request(
            .post,
            path: "/api/auth/delete-account",
            body: DeleteAccountRequest(current: currentPassword)
        )
    }

    func logout() async throws {
        let _: OperationResponse = try await client.request(.post, path: "/api/auth/logout")
    }

    func startGuestSession() async throws -> GuestSessionResponse {
        try await client.request(.post, path: "/api/guest")
    }

    func endGuestSession() async throws {
        let _: OperationResponse = try await client.request(.delete, path: "/api/guest")
    }

    func listChats() async throws -> [ChatSummary] {
        try await client.request(
            .get,
            path: "/api/chats",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func chat(id: String) async throws -> ChatConversation {
        try requireIdentifier(id)
        return try await client.request(
            .get,
            path: "/api/chats/\(id)",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func createChat(_ request: CreateChatRequest) async throws -> CreateChatResponse {
        try await client.request(.post, path: "/api/chats", body: request)
    }

    func updateChat(id: String, request: UpdateChatRequest) async throws {
        try requireIdentifier(id)
        let _: OperationResponse = try await client.request(
            .put,
            path: "/api/chats/\(id)",
            body: request
        )
    }

    func deleteChat(id: String) async throws {
        try requireIdentifier(id)
        let _: OperationResponse = try await client.request(.delete, path: "/api/chats/\(id)")
    }

    func makeChatBackup() async throws -> FirasChatBackup {
        let summaries = try await listChats()
        var entries: [FirasChatBackupEntry] = []
        entries.reserveCapacity(summaries.count)

        // Match the website's resilient export: a single unavailable chat does
        // not make every other conversation impossible to save.
        for summary in summaries {
            let conversation = try? await chat(id: summary.id)
            let messages = conversation?.messages ?? []
            entries.append(FirasChatBackupEntry(summary: summary, messages: messages))
        }

        return FirasChatBackup(
            chats: entries,
            exportedAt: Date.now.formatted(.iso8601)
        )
    }

    func importChatBackup(_ backup: FirasChatBackup) async throws -> Int {
        let validated = try backup.validatedForImport()
        var importedCount = 0

        for entry in validated.chats {
            let request = CreateChatRequest(
                clientId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                title: entry.title,
                messages: entry.messages,
                pinned: entry.pinned == true,
                agent: entry.agent == true,
                codeProj: entry.codeProj == true,
                brainNb: entry.brainNb == true
            )
            _ = try await createChat(request)
            importedCount += 1
        }

        return importedCount
    }

    func startChatJob(_ request: ChatJobRequest) async throws -> ChatJobStartResponse {
        try await client.request(
            .post,
            path: "/api/chat/job",
            body: request,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func chatJobStatus(id: String) async throws -> ChatJobStatus {
        try requireIdentifier(id)
        return try await client.request(
            .get,
            path: "/api/chat/job",
            query: [URLQueryItem(name: "id", value: id)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func cancelChatJob(id: String) async throws -> CancelChatJobResponse {
        try requireIdentifier(id)
        return try await client.request(
            .post,
            path: "/api/chat/cancel",
            body: CancelChatJobRequest(id: id),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func agentJobStatus(id: String) async throws -> AgentJob? {
        try requireIdentifier(id)
        let envelope: AgentJobEnvelope = try await client.request(
            .get,
            path: "/api/agent/job",
            query: [URLQueryItem(name: "id", value: id)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return envelope.job
    }

    func agentArtifact(jobID: String, index: Int, download: Bool = false) async throws -> AgentArtifactDownload {
        try requireIdentifier(jobID)
        guard index >= 0 else {
            throw APIError.invalidRequest("The artifact index must be non-negative.")
        }
        var query = [
            URLQueryItem(name: "id", value: jobID),
            URLQueryItem(name: "index", value: String(index)),
        ]
        if download {
            query.append(URLQueryItem(name: "download", value: "1"))
        }
        return try await client.download(path: "/api/agent/artifact", query: query)
    }

    func chargeUsage(product: ProductKind, cid: String) async throws -> UsageChargeResponse {
        guard product == .code || product == .agent else {
            throw APIError.invalidRequest("Usage charge accepts only code or agent products.")
        }
        return try await client.request(
            .post,
            path: "/api/usage/charge",
            body: UsageChargeRequest(product: product, cid: cid)
        )
    }

    func brainDocuments() async throws -> BrainLibraryResponse {
        try await client.request(
            .get,
            path: "/api/brain/docs",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func uploadBrainDocument(_ request: BrainUploadRequest) async throws -> BrainUploadResponse {
        try await client.request(.post, path: "/api/brain/doc", body: request)
    }

    func deleteBrainDocument(id: String) async throws {
        try requireIdentifier(id)
        let _: OperationResponse = try await client.request(
            .delete,
            path: "/api/brain/doc",
            query: [URLQueryItem(name: "id", value: id)]
        )
    }

    func searchBrain(_ request: BrainSearchRequest) async throws -> BrainSearchResponse {
        try await client.request(.post, path: "/api/brain/search", body: request)
    }

    func brainPassage(documentID: String, chunkIndex: Int, window: Int = 2) async throws -> BrainPassage {
        try requireIdentifier(documentID)
        guard chunkIndex >= 0 else {
            throw APIError.invalidRequest("The passage index must be non-negative.")
        }
        return try await client.request(
            .get,
            path: "/api/brain/passage",
            query: [
                URLQueryItem(name: "doc", value: documentID),
                URLQueryItem(name: "i", value: String(chunkIndex)),
                URLQueryItem(name: "w", value: String(min(max(window, 0), 5))),
            ],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func webSearch(query: String) async throws -> WebSearchResponse {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        guard !trimmed.isEmpty else {
            throw APIError.invalidRequest("The search query is empty.")
        }
        return try await client.request(
            .get,
            path: "/api/search",
            query: [URLQueryItem(name: "q", value: trimmed)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func startImageJob(
        prompt: String,
        preset: ImageAspectPreset
    ) async throws -> MediaJobStartResponse {
        let cleanPrompt = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
        guard !cleanPrompt.isEmpty else {
            throw APIError.invalidRequest("The image prompt is empty.")
        }
        return try await client.request(
            .post,
            path: "/api/image/job",
            body: MediaImageJobRequest(prompt: cleanPrompt, w: preset.width, h: preset.height),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func startVideoJob(
        prompt: String,
        seconds: Int
    ) async throws -> MediaJobStartResponse {
        let cleanPrompt = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        guard !cleanPrompt.isEmpty else {
            throw APIError.invalidRequest("The video prompt is empty.")
        }
        return try await client.request(
            .post,
            path: "/api/video/job",
            body: MediaVideoJobRequest(
                prompt: cleanPrompt,
                seconds: min(max(seconds, 2), 30)
            ),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func startMusicJob(
        prompt: String,
        lyrics: String,
        seconds: Int
    ) async throws -> MediaJobStartResponse {
        let cleanPrompt = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        let cleanLyrics = String(lyrics.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6_000))
        guard !cleanPrompt.isEmpty || !cleanLyrics.isEmpty else {
            throw APIError.invalidRequest("The music brief is empty.")
        }
        return try await client.request(
            .post,
            path: "/api/music/job",
            body: MediaMusicJobRequest(
                prompt: cleanPrompt,
                lyrics: cleanLyrics,
                seconds: min(max(seconds, 10), 600)
            ),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func mediaJobStatus(
        kind: MediaStudioKind,
        id: String
    ) async throws -> MediaJobStatusResponse {
        try requireIdentifier(id)
        return try await client.request(
            .get,
            path: mediaJobPath(kind),
            query: [URLQueryItem(name: "id", value: id)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func mediaAsset(
        kind: MediaStudioKind,
        key: String
    ) async throws -> AgentArtifactDownload {
        try requireIdentifier(key)
        let path: String
        let queryName: String
        switch kind {
        case .image:
            path = "/api/image"
            queryName = "key"
        case .video:
            path = "/api/video/file"
            queryName = "id"
        case .music:
            path = "/api/music/file"
            queryName = "id"
        }
        return try await client.download(
            path: path,
            query: [URLQueryItem(name: queryName, value: key)]
        )
    }

    private func mediaJobPath(_ kind: MediaStudioKind) -> String {
        switch kind {
        case .image: "/api/image/job"
        case .video: "/api/video/job"
        case .music: "/api/music/job"
        }
    }

    private func requireIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              value.count <= 160,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
              })
        else {
            throw APIError.invalidRequest("The resource identifier is invalid.")
        }
    }

    private static func isPKCEVerifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 46, 48...57, 65...90, 95, 97...122, 126:
            return true
        default:
            return false
        }
    }

    private static func isBase64URLScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }
}
