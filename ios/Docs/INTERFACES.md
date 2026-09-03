# Frozen Swift interfaces

Engineers may add `private` helpers and non-conflicting members; they may not change a signature,
rename a case, or move a type to another file without the architect updating this document first.
Bodies are omitted; `{ get }` marks read-only. Everything is Swift 5 mode, default nonisolated.
Conformances shown are the minimum. The existing `nonisolated` prefix on Codex model types may stay.

---

## App/ — `AppConfiguration.swift`, `AppRoute.swift`, `AppEnvironment.swift`, `AppLifecycle.swift`, `FirasAIApp.swift`

```swift
struct AppConfiguration: Sendable {
    let apiBaseURL: URL                       // https only (http for localhost); from Info.plist FIRAS_API_BASE_URL
    static let live: AppConfiguration
    static var bundleID: String { get }       // Bundle.main.bundleIdentifier ?? "org.firasai.FirasAI"
    static var isDebug: Bool { get }
}

enum AppRoute: Equatable, Sendable {
    case chat(conversationID: String)
    case agent(conversationID: String?)
    case code(projectID: String?)
    case brain
    case studio(creationID: String?)
    case settings(SettingsSection)
    case auth(mode: AuthMode)
    case sharedChat(id: String)
    case verify(token: String)
    case reset(uid: String, token: String)
}
enum SettingsSection: String, CaseIterable, Sendable { case account, appearance, chat, voice, data }
enum AuthMode: String, Sendable { case login, signup }

enum AppSheet: Identifiable, Equatable {
    case settings(SettingsSection), tierPicker, addContext, announcements, share(conversationID: String, messageCID: String?),
         signUpPrompt(FeatureKey), dialectPicker, memory, longFile(jobID: String), codeViewer(messageID: String), notificationExplainer
    var id: String { get }
}
enum AppCover: Identifiable, Equatable { case auth(AuthMode), call, mediaViewer(creationID: String), artifact(url: String); var id: String { get } }

@MainActor @Observable final class Router {
    var product: ProductKind                  // .ai default
    var selectedConversationID: String?       // per product; nil = welcome
    var sheet: AppSheet?
    var cover: AppCover?
    var pendingRoute: AppRoute?               // written by notifications / onOpenURL, consumed once by AppShell
    var drawerOpen: Bool
    func open(_ route: AppRoute)              // sets product/selection/sheet/cover as needed
    func newConversation(in product: ProductKind)
    func select(conversationID: String, product: ProductKind)
    func showSignUp(feature: FeatureKey)
    func handle(url: URL) -> Bool
}

@MainActor final class AppEnvironment {      // the only place stores are constructed, in this order
    let config: AppConfiguration
    let api: APIClient
    let prefs: PreferencesStore
    let network: NetworkMonitor
    let toasts: ToastCenter
    let router: Router
    let notifications: NotificationManager
    let session: SessionStore
    let jobs: JobManager
    let drafts: DraftStore
    let guestChats: GuestChatStore
    let chat: ChatStore
    let agent: AgentStore
    let code: CodeStore
    let brain: BrainStore
    let media: MediaStore
    let announcements: AnnouncementStore
    let memory: MemoryStore
    let call: CallEngine
    let tts: TTSPlayer
    let dictation: DictationController
    init(config: AppConfiguration)
    func inject<V: View>(into view: V) -> AnyView     // applies every .environment(...) once
}

@MainActor final class AppLifecycle {
    init(env: AppEnvironment)
    func didBecomeActive() async               // session revalidate, jobs.resumeAll, network kick, drafts restore
    func didEnterBackground()                  // drafts flush, jobs.applicationDidEnterBackground, BackgroundRefresh.schedule
    func handle(url: URL)
    func handleNotificationTap(userInfo: [AnyHashable: Any])
}
```

---

## Core/

```swift
actor DiskStore {                                      // Application Support/FirasAI/, atomic, completeFileProtection, excluded from backup
    static let shared: DiskStore
    func read<T: Decodable & Sendable>(_ type: T.Type, at relativePath: String) async -> T?      // nil on missing or undecodable (logged)
    func write<T: Encodable & Sendable>(_ value: T, at relativePath: String) async throws
    func delete(at relativePath: String) async
    func fileURL(_ relativePath: String) -> URL         // creates parent directories
    func list(directory relativePath: String) async -> [String]
}
@MainActor @Observable final class NetworkMonitor {
    private(set) var isOnline: Bool
    var updates: AsyncStream<Bool> { get }
    func start()
}
struct BackgroundHold: Sendable { func end() }         // ends the UIApplication background task; idempotent; auto-ends at expiry
enum BackgroundExecutor { @MainActor static func hold(name: String) -> BackgroundHold }
struct DeadlineError: Error, Sendable {}
func withDeadline<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T
struct Backoff: Sendable { init(initial: Double, max: Double, factor: Double = 1.7); mutating func next() -> Double; mutating func reset(); var attempt: Int { get } }
enum IDs {
    static func cid() -> String                        // 16 chars [A-Za-z0-9_-]
    static func localConversationID() -> String        // "ios_" + uuid
    static func sanitizedCid(_ raw: String) -> String  // server regex, ≤ 64
    static func sanitizedMediaKey(_ raw: String) -> String   // [a-f0-9] ≤ 64
}
enum BidiText {
    static func direction(of text: String) -> LayoutDirection?       // first strong character; nil when none
    static func isArabicDominant(_ text: String) -> Bool
}
enum ArabicText {
    static func normalize(_ text: String) -> String                   // strip tashkeel/tatweel, fold hamza/ya/ta-marbuta
    static func count(_ n: Int, _ lang: AppLanguage) -> String        // Arabic-Indic digits for .arabic
    static func timer(_ seconds: Int) -> String                       // LTR "m:ss", Latin digits
}
enum ArabicPlurals { static func count(_ n: Int, _ lang: AppLanguage, zero: LText, one: LText, two: LText, few: LText, many: LText, other: LText) -> String }
enum Log { static let net: Logger; static let jobs: Logger; static let call: Logger; static let ui: Logger; static func redacted(_ s: String) -> String }
```

---

## Networking/

```swift
enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }
enum RequestBudget: Sendable { case interactive, poll, upload, download, stream }
struct SSEFrame: Sendable, Equatable { let event: String?; let id: String?; let data: String }
enum SSEParser { static func frames(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<SSEFrame, Error> }

struct ServerError: Decodable, Sendable, Equatable {   // every field optional; hand-written lenient init(from:)
    var code: String?                                  // the "error" field, or the plain-text body
    var ok: Bool?; var feature: String?; var guest: Bool?; var scope: String?
    var quota: QuotaInfo?
    var limit: Int?; var used: Int?; var remaining: Int?; var windowMin: Int?; var freesInMin: Int?
    var activeJob: AgentActiveJob?; var credits: AgentCredits?; var retryRequiresNewCid: Bool?
    var maxPages: Int?; var chars: Int?; var cap: Int?
    var isSignInRequired: Bool { get }                 // signin_required || account_required
    static func parse(_ data: Data) -> ServerError     // JSON or plain text, never throws
    static func parse(jsonString: String) -> ServerError?
}
struct QuotaInfo: Decodable, Sendable, Equatable { var product: String?; var used: Int?; var limit: Int?; var plan: String? }
struct AgentActiveJob: Decodable, Sendable, Equatable { var jobId: String?; var chatId: String?; var cid: String?; var title: String? }

enum APIError: Error, Sendable {
    case invalidURL
    case transport(URLError)
    case http(status: Int, server: ServerError, raw: String)
    case decoding(String)
    case offline
    case cancelled
    case deadline
    var status: Int? { get }
    var server: ServerError? { get }
}

actor APIClient {
    init(configuration: AppConfiguration)
    nonisolated let unauthorized: AsyncStream<Void>              // one element per 401 response
    func json<T: Decodable & Sendable>(_ method: HTTPMethod, _ path: String, query: [String: String] = [:], body: (any Encodable & Sendable)? = nil, budget: RequestBudget = .interactive, as type: T.Type) async throws -> T
    func raw(_ method: HTTPMethod, _ path: String, query: [String: String] = [:], body: (any Encodable & Sendable)? = nil, budget: RequestBudget = .interactive) async throws -> (Data, HTTPURLResponse)
    func stream(_ method: HTTPMethod, _ path: String, query: [String: String] = [:], body: (any Encodable & Sendable)? = nil) -> AsyncThrowingStream<SSEFrame, Error>
    func download(_ path: String, query: [String: String] = [:]) async throws -> (url: URL, filename: String, mime: String?)   // temp file; caller moves it
}
enum LenientJSON {                                             // used inside hand-written init(from:)
    static func int(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> Int?
    static func double(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> Double?
    static func bool(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> Bool?
    static func string(_ c: KeyedDecodingContainer<AnyCodingKey>, _ key: String) -> String?
}
struct AnyCodingKey: CodingKey, Sendable { var stringValue: String; var intValue: Int?; init?(stringValue: String); init?(intValue: Int); init(_ s: String) }
```

Endpoint helpers (`Networking/Endpoints/*.swift`, `extension APIClient`). Names are frozen; every
parameter maps 1:1 to a documented body field.

```swift
// AuthEndpoints
extension APIClient {
    func me() async throws -> User                                                 // GET /api/auth/me → {user}
    func login(email: String, password: String) async throws -> User
    func signup(name: String, email: String, password: String) async throws -> PendingSignup   // {pid, email, ...} or {user}
    func verifyStatus(pid: String) async throws -> VerificationStatus                          // POST /api/auth/verify-status
    func verifySignup(token: String) async throws -> User
    func resendCode(email: String) async throws                                    // POST /api/auth/resend-code reads {email}; DB.pending is keyed by email and there is no pid to email route. Call it with the address carried in SessionStore.Phase.awaitingVerification.
    func forgotPassword(email: String) async throws
    func resetPassword(uid: String, token: String, password: String) async throws -> User
    func logout() async throws
    func googleNative(code: String, codeVerifier: String, nonce: String) async throws -> User   // POST /api/auth/google-native body {code, code_verifier, nonce}; the server runs the Google token exchange itself, so no ID/access token ever enters the app. GoogleOAuthProvider.authorize(anchor:) returns exactly this triple as GoogleAuthorization.
    func guestStart() async throws -> User                                          // POST /api/guest
    func guestEnd() async throws                                                    // DELETE /api/guest
    func changeEmail(currentPassword: String, newEmail: String) async throws -> User
    func changePassword(currentPassword: String, newPassword: String) async throws
    func deleteAccount(currentPassword: String) async throws
    func redeem(code: String) async throws -> User
}
// ChatEndpoints
extension APIClient {
    func listChats() async throws -> [ChatSummary]
    func getChat(id: String) async throws -> ChatConversation
    func createChat(_ req: CreateChatRequest) async throws -> ChatConversation
    func updateChat(id: String, _ req: UpdateChatRequest) async throws
    func deleteChat(id: String) async throws
    func chatStream(_ req: ChatStreamRequest) -> AsyncThrowingStream<SSEFrame, Error>          // POST /api/chat
    func webSearch(query: String, count: Int) async throws -> [WebSearchResult]                // GET /api/search
    func fetchURL(_ url: String) async throws -> String                                        // GET /api/fetch
    func translate(text: String, to lang: String) async throws -> String
    func createShare(_ req: ShareCreateRequest) async throws -> ShareInfo
    func getShare(id: String) async throws -> SharedChat
    func deleteShare(id: String) async throws
}
// JobEndpoints
extension APIClient {
    func startChatJob(_ req: ChatJobRequest) async throws -> ChatJobStartResponse             // POST /api/chat/job (all chat-queue kinds)
    func chatJobStatus(id: String) async throws -> ChatJobStatus                              // GET /api/chat/job?id=
    func cancelChatJob(id: String) async throws -> Bool                                       // POST /api/chat/cancel
    func longFileManifest(jobID: String) async throws -> LongFileManifest                     // GET /api/chat/job/file?id=
    func longFilePart(jobID: String, index: Int) async throws -> LongFilePart                 // &part=N
    func usageCharge(product: ProductKind, units: Int, cid: String = "") async throws -> UsageChargeResponse   // POST /api/usage/charge; the wire body is {product, cid} - there is no `units` field, and `cid` is the charge's idempotency key, so Agent/Code callers must pass the turn's cid.
}
// AgentEndpoints
extension APIClient {
    func agentJob(id: String) async throws -> AgentJob?                                       // GET /api/agent/job → {job|null}
    func agentJobStream(id: String) -> AsyncThrowingStream<SSEFrame, Error>                   // GET /api/agent/job-stream
    func agentCredits() async throws -> AgentCredits
    func agentArtifact(jobID: String, index: Int, download: Bool) async throws -> (url: URL, filename: String, mime: String?)
}
// BrainEndpoints
extension APIClient {
    func brainDocs() async throws -> BrainLibraryResponse
    func brainAddDoc(_ req: BrainUploadRequest) async throws -> BrainUploadResponse
    func brainDeleteDoc(id: String) async throws
    func brainSearch(_ req: BrainSearchRequest) async throws -> BrainSearchResponse
    func brainPassage(docID: String, index: Int, window: Int) async throws -> BrainPassage
    func brainWhole(_ req: BrainWholeRequest) async throws -> BrainWholeResponse
}
// MediaEndpoints
extension APIClient {
    func startImageJob(_ req: ImageJobRequest) async throws -> MediaJobStartResponse
    func startVideoJob(_ req: VideoJobRequest) async throws -> MediaJobStartResponse
    func startMusicJob(_ req: MusicJobRequest) async throws -> MediaJobStartResponse
    func mediaJobStatus(kind: MediaKind, id: String) async throws -> MediaJobStatusResponse
    func downloadMedia(kind: MediaKind, key: String) async throws -> (url: URL, filename: String, mime: String?)   // /api/image?key= | /api/video/file?id= | /api/music/file?id=
    func imageQuota() async throws -> ImageQuota                                              // POST /api/image/quota
    func videoQuota() async throws -> VideoQuota                                              // GET /api/video/quota
    func editImage(_ req: ImageEditRequest) async throws -> ImageEditResponse                 // POST /api/image/edit
}
// VoiceEndpoints
extension APIClient {
    func liveToken(voice: String, prefer: String?) async throws -> LiveToken
    func transcribe(wavBase64: String, lang: String) async throws -> TranscribeResponse
    func tts(text: String, lang: String) async throws -> (data: Data, mime: String?)
}
// AccountEndpoints
extension APIClient {
    func announcements() async throws -> [Announcement]
    func memory() async throws -> [MemoryEntry]
    func deleteMemory(id: String?) async throws                                               // nil = clear all
    func memoryLearn(text: String) async throws                                               // fire-and-forget by callers
    func version() async throws -> String
}
```

---

## Models/

```swift
// CommonModels.swift
enum AppLanguage: String, CaseIterable, Codable, Sendable { case arabic = "ar", english = "en"; var locale: Locale { get }; static var deviceDefault: AppLanguage { get } }
enum ModelTier: String, CaseIterable, Codable, Sendable, Identifiable {
    case mini, pro, ultra, max
    var id: String { get }
    var showThinking: Bool { get }                 // false for mini
    var tokenCap: Int { get }                      // 2048 / 16384 / 16384 / 16384
    var label: LText { get }; var short: LText { get }; var tagline: LText { get }; var badge: LText? { get }   // max الأقوى, ultra للأكواد
    var symbol: String { get }                     // SF Symbol: bolt.fill / bolt.horizontal.fill / star.fill / crown.fill
}
enum ProductKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case ai, agent, code, brain, studio            // studio never leaves the device (media sends "ai")
    var id: String { get }
    var wireValue: String { get }
    var title: LText { get }
    var symbol: String { get }
}
enum ResponseMode: String, Codable, Sendable { case auto, plan }
enum FeatureKey: String, Sendable { case generic, image, video, music, live, agent, brain, brainWhole = "brain_whole", share, memory }
enum AppAPIValue: Codable, Equatable, Sendable { case string(String), number(Double), bool(Bool), null, array([AppAPIValue]), object([String: AppAPIValue])
    subscript(key: String) -> AppAPIValue? { get }; var stringValue: String? { get }; var intValue: Int? { get }; var boolValue: Bool? { get } }

// AuthModels.swift
enum PlanKind: String, Codable, Sendable { case free, gold, diamond, unlimited, guest; init(from decoder: Decoder) throws /* unknown → free */ ; var title: LText { get } }
struct QuotaCounts: Codable, Sendable, Equatable { var ai: Int; var code: Int; var agent: Int; var brain: Int; init(from decoder: Decoder) throws /* missing → -1 for limits, 0 for used */ }
struct SubInfo: Codable, Sendable, Equatable { var plan: PlanKind; var expiresAt: Double?; var daysLeft: Int?; var limits: QuotaCounts; var used: QuotaCounts; var remaining: QuotaCounts }
struct User: Codable, Sendable, Equatable, Identifiable {
    let id: String; var name: String; var email: String; var admin: Bool; var guest: Bool; var sub: SubInfo
    var isGuest: Bool { get }; var firstName: String { get }; var initial: String { get }
}
struct PendingSignup: Sendable, Equatable { let pid: String; let email: String; let user: User? }     // user when the server signed in directly
enum VerificationStatus: String, Sendable { case pending, verified, expired, gone; init(raw: String) }
struct VerificationStatusResponse: Decodable, Sendable { var status: String?; var verified: Bool?; var expired: Bool?; var gone: Bool?; var user: User?; var resolved: VerificationStatus { get } }   // the server sends expired/gone, never `status`

// ChatModels.swift
enum ChatRole: String, Codable, Sendable { case system, user, assistant, unknown }
enum DeliveryStatus: Codable, Sendable, Equatable { case delivered, sending, streaming, failed(String), stopped, queuedOffline }
struct FileChip: Codable, Sendable, Equatable { let name: String; var kind: String? }
struct RetryReference: Codable, Sendable, Equatable { let cid: String; let tier: String }
struct AnswerVersion: Codable, Sendable, Equatable { var content: String; var reasoning: String?; var tier: String?; var lang: String? }
struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    let id: String                                  // client id: "<role>-<cid>" when a cid exists, else a UUID. A turn's user and assistant halves share one cid, so a bare `id = cid` would put two rows of a reloaded chat under one identifier. Mint it with ChatMessage.identity(role:cid:).
    static func identity(role: ChatRole, cid: String?) -> String
    var role: ChatRole; var content: String
    var tier: String?; var lang: String?; var reasoning: String?; var cid: String?
    var files: [FileChip]?; var imageThumbs: [String]?
    var mode: String?; var askAnswered: Bool?
    var retryOf: RetryReference?; var retried: Bool?; var mergedFrom: String?
    var alts: [AnswerVersion]?; var altAt: Int?
    // client-only (never persisted):
    var images: [String]?; var fileText: String?; var intent: String?; var status: DeliveryStatus
    init(from decoder: Decoder) throws              // lenient; server rows get status .delivered
    static func user(_ content: String, cid: String, lang: AppLanguage) -> ChatMessage
    static func assistant(cid: String, tier: ModelTier, lang: AppLanguage, mode: ResponseMode) -> ChatMessage
}
struct ChatSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String; var title: String; var updatedAt: String; var createdAt: String?
    var pinned: Bool; var agent: Bool; var codeProj: Bool; var brainNb: Bool; var messageCount: Int?
    var product: ProductKind { get }
}
struct ChatConversation: Codable, Sendable, Equatable, Identifiable {
    let id: String                                  // server id for members; "ios_…" local id for guests
    var serverID: String?                           // nil for guest/local
    var title: String; var messages: [ChatMessage]
    var pinned: Bool; var agent: Bool; var codeProj: Bool; var brainNb: Bool
    var createdAt: String?; var updatedAt: String?
    var planSnapshotMode: ResponseMode?             // client-only cycle snapshot
    var product: ProductKind { get }
}
struct CreateChatRequest: Encodable, Sendable { var title: String; var messages: [PersistedMessage]; var agent: Bool?; var codeProj: Bool?; var brainNb: Bool?; var id: String? }
struct UpdateChatRequest: Encodable, Sendable { var title: String?; var messages: [PersistedMessage]?; var pinned: Bool? }

// ChatWireModels.swift
struct OutgoingMessage: Encodable, Sendable, Equatable { let role: String; let content: String; let images: [String]? }
struct PersistedMessage: Codable, Sendable, Equatable {    // exactly the sanitizeMessages whitelist
    var role: String; var content: String; var tier: String?; var lang: String?; var reasoning: String?; var cid: String?
    var files: [FileChip]?; var imageThumbs: [String]?; var mode: String?; var askAnswered: Bool?
    var retryOf: RetryReference?; var retried: Bool?; var mergedFrom: String?; var alts: [AnswerVersion]?; var altAt: Int?
}
struct ChatStreamRequest: Encodable, Sendable { var messages: [OutgoingMessage]; var tier: String; var think: Bool; var cid: String; var chatId: String?; var product: String; var nomem: Bool?; var nokb: Bool?; var agent: Bool? }
struct ChatJobRequest: Encodable, Sendable {
    var messages: [OutgoingMessage]; var tier: String; var think: Bool; var cid: String; var chatId: String; var product: String
    var kind: String                                 // JobKind.rawValue for chat-queue kinds
    var lang: String; var title: String?; var task: String?
    var sections: Int?                               // longdoc
    var format: String?; var pages: Int?; var targetPages: Int?; var prompt: String?   // longfile
    var nokb: Bool?; var agent: Bool?
}
struct ChatJobStartResponse: Decodable, Sendable {
    var ok: Bool?; var jobId: String?; var phase: String?; var text: String?; var reasoning: String?
    var surface: AppAPIValue?; var progress: LongFileProgress?; var error: String?; var retryRequiresNewCid: Bool?
}
struct ChatJobStatus: Decodable, Sendable, Equatable {
    var phase: String; var text: String; var reasoning: String; var error: String; var status: Int
    var surface: AppAPIValue?; var progress: LongFileProgress?
    init(from decoder: Decoder) throws              // {"phase":"unknown"} decodes with empty strings and 0
}
struct LongFileProgress: Decodable, Sendable, Equatable {
    var stage: String; var pagesDone: Int; var pagesTotal: Int; var targetPages: Int; var currentPage: Int?; var currentTitle: String?
    var partsDone: Int; var partsTotal: Int; var percent: Int; var complete: Bool; var cancelled: Bool; var resumeAvailable: Bool?
}
struct LongFileManifest: Decodable, Sendable { var version: Int?; var format: String?; var filename: String?; var title: String?; var requestedPages: Int?; var completedPages: Int?; var partsDone: Int; var partsTotal: Int; var complete: Bool; var progress: LongFileProgress? }
struct LongFilePart: Decodable, Sendable { struct Record: Decodable, Sendable { var pageNumber: Int; var title: String; var markdown: String }; var partIndex: Int; var startPage: Int; var endPage: Int; var records: [Record]; var sha256: String? }
struct WebSearchResult: Decodable, Sendable, Equatable { var title: String?; var url: String?; var snippet: String?; var source: String? }
struct UsageChargeResponse: Decodable, Sendable { var ok: Bool?; var used: Int?; var limit: Int?; var remaining: Int? }   // the server answers {ok, sub}; the decoder fills used/limit/remaining out of `sub` when the flat keys are absent
struct ShareCreateRequest: Encodable, Sendable { var chatId: String; var cid: String?; var title: String? }
struct ShareInfo: Codable, Sendable, Equatable { let id: String; var url: URL { get } }          // https://firasai.org/?share=<id>
struct SharedChat: Decodable, Sendable { var title: String?; var messages: [ChatMessage]; var createdAt: Double?; var one: Bool }   // createdAt decodes the wire key `ts`; `one` is the single-answer marker

// JobModels.swift
enum JobKind: String, Codable, Sendable, CaseIterable {
    case chat, longdoc, longfile, agentrun, codebuild, brainask, image, video, music
    var product: ProductKind { get }; var isChatQueue: Bool { get }; var mediaKind: MediaKind? { get }
}
enum JobPhase: String, Codable, Sendable { case queued, processing, completed, failed, unknown, expired, reconnecting; init(raw: String) /* done→completed, fail→failed, run→processing */ }
struct JobPointer: Codable, Sendable, Equatable, Identifiable {
    let id: String                                   // server job id (media: the hex key)
    let kind: JobKind; let ownerID: String; let cid: String
    var conversationID: String; var serverChatID: String?; var assistantMessageID: String?
    var projectID: String?; var creationID: String?
    var title: String; var lang: String
    let startedAt: Date; var deadline: Date
    var lastPhase: JobPhase; var cancelRequested: Bool; var notified: Bool
    var lastTextCount: Int
}
struct JobSnapshot: Sendable, Equatable {
    let pointerID: String; let phase: JobPhase; let text: String; let reasoning: String
    let progress: LongFileProgress?; let surface: AppAPIValue?; let agent: AgentJob?; let mediaKey: String?
}
enum JobTerminal: Sendable, Equatable {
    case completed(JobSnapshot)
    case refused(status: Int, error: ServerError)   // quota/rate/auth captured inside the worker
    case failed(code: String, partial: JobSnapshot?)
    case cancelled
    case expired                                     // deadline, unknown×N, {job:null}×2
    case unauthorized
    case forbidden
    var isSuccess: Bool { get }
}
enum DriverRead: Sendable { case running(JobSnapshot), terminal(JobTerminal), unknown }
struct JobKindSpec: Sendable {
    let kind: JobKind
    let cadence: [(after: TimeInterval, interval: TimeInterval)]   // foreground ladder
    let backgroundInterval: TimeInterval
    let deadline: TimeInterval
    let cancelable: Bool
    let unknownReadsBeforeTerminal: Int                             // chat 3, codebuild/brainask 1, agent 2 (job:null)
    let usesSSE: Bool
}

// AgentModels.swift (existing types kept: AgentJobPhase, AgentPresentation, AgentStepStatus, AgentStep, AgentEvent, AgentTool, AgentFile, AgentActivity, AgentCredits, AgentJob, AgentJobEnvelope)
extension AgentFile { var artifactIndex: Int? { get } }                              // parsed from url "index="
struct AgentBusyResponse: Sendable, Equatable { let activeJob: AgentActiveJob?; let credits: AgentCredits? }
extension AgentJob { static func parseFence(_ markdown: String) -> AgentJob? }        // ```firas-agent body, brace-match fallback

// CodeModels.swift (existing CodeFile, CodeProject, CodeProjectDecodingError kept)
extension CodeProject {
    static let blankFiles: [CodeFile]                                   // CW_BLANK_FILES scaffold
    func validatedForSave() -> Result<CodeProject, CodeSaveError>       // 30 files / 120-char paths / 60 000 per file / 180 000 total
    func encodedFence() -> String                                       // ```firas-project …```
}
enum CodeSaveError: Error, Sendable, Equatable { case tooManyFiles, pathTooLong(String), fileTooLarge(String), projectTooLarge }
struct CodeChatMessage: Codable, Sendable, Equatable { var role: String; var content: String; var at: Double?; var n: Int?; var applied: Bool? }   // CodingKeys: content to "text", at to "ts"
struct CodeChatThread: Codable, Sendable, Equatable { var messages: [CodeChatMessage]; static func decode(fromFence: String) -> CodeChatThread?; func encodedFence() -> String }   // base64 JSON in messages[1]
struct CodeFileBlock: Sendable, Equatable { let path: String; let content: String }
struct CodeEditPlan: Sendable, Equatable { var writes: [CodeFileBlock]; var deletes: [String]; var renames: [(from: String, to: String)]; var prose: String
    static func parse(_ answer: String) -> CodeEditPlan }                // ```file:path blocks + DELETE:/RENAME: lines

// BrainModels.swift (existing types kept; add:)
// BrainHit carries `let near: Bool?` as a STORED property (a computed one cannot hold decoded data); `hit.near` is unchanged at every call site.
struct BrainWholeRequest: Encodable, Sendable { var docId: String; var question: String; var cid: String; var lang: String; var outline: Bool? }
struct BrainWholeResponse: Decodable, Sendable { var answer: String?; var ok: Bool?; var error: String? }
struct BrainSource: Codable, Sendable, Equatable, Identifiable { var n: Int; var docId: String; var title: String; var page: Int; var label: String?; var ci: Int; var s: String?; var unit: String?; var id: String { get } }   // `unit` is the fence's `u` key, last and defaulted so BrainSource(n:docId:title:page:label:ci:s:) still compiles
struct BrainAskJobRequest: Encodable, Sendable { var kind: String; var task: String; var cid: String; var chatId: String; var product: String; var lang: String; var tier: String; var docIds: [String]?; var messages: [OutgoingMessage] }

// MediaModels.swift
enum MediaKind: String, Codable, Sendable, CaseIterable, Identifiable { case image, video, music; var id: String { get }; var jobKind: JobKind { get }; var fenceName: String { get } }
enum ImageShape: String, Codable, Sendable, CaseIterable, Identifiable { case square, tall, wide; var id: String { get }; var width: Int { get }; var height: Int { get } }   // 1024², 1024×1536, 1536×1024
struct ImageJobRequest: Encodable, Sendable { var prompt: String; var w: Int; var h: Int; var chatId: String? }
struct VideoJobRequest: Encodable, Sendable { var prompt: String; var seconds: Int; var image: String?; var chatId: String? }
struct MusicJobRequest: Encodable, Sendable { var prompt: String; var lyrics: String; var seconds: Int; var chatId: String? }
struct MediaJobStartResponse: Decodable, Sendable { var ok: Bool?; var jobId: String; var phase: String?; var key: String? }
struct MediaJobStatusResponse: Decodable, Sendable, Equatable { var phase: String; var key: String?; var error: String?; var reason: String?; var url: String? }
struct ImageQuota: Decodable, Sendable { var used: Int?; var limit: Int?; var remaining: Int? }
struct VideoQuota: Decodable, Sendable { var seconds: Int?; var maxSeconds: Int?; var limit: Int?; var used: Int?; var windowMin: Int? }
struct ImageEditRequest: Encodable, Sendable { var image: String; var prompt: String; var chatId: String? }
struct ImageEditResponse: Decodable, Sendable { var ok: Bool?; var key: String?; var jobId: String?; var error: String? }
struct MediaMeta: Codable, Sendable, Equatable {        // the firas-image / firas-video / firas-music fence body
    var kind: MediaKind; var key: String; var prompt: String; var note: String?; var w: Int?; var h: Int?; var seconds: Int?; var lyrics: String?; var title: String?; var style: String?; var src: String?
    static func parse(fenceName: String, body: String) -> MediaMeta?; func encodedFence() -> String
}
struct MediaCreation: Codable, Sendable, Equatable, Identifiable {
    let id: String; let ownerID: String; let kind: MediaKind; var meta: MediaMeta
    var conversationID: String; var messageID: String?
    var createdAt: Date; var phase: JobPhase; var jobID: String?; var localFilename: String?; var errorCode: String?
}

// VoiceModels.swift
struct LiveToken: Decodable, Sendable, Equatable { var provider: String; var token: String; var model: String; var voice: String?; var maxMs: Int; var guest: Bool; var startWithinMs: Int }
enum CallVoice: String, CaseIterable, Codable, Sendable, Identifiable { case cedar, ash, verse, echo, ballad; var id: String { get }; var label: LText { get } }
enum DictationDialect: String, CaseIterable, Codable, Sendable, Identifiable {      // the 14 server keys, "auto" first
    case auto, ar, arIQ = "ar-IQ", arSA = "ar-SA", arEG = "ar-EG", arLB = "ar-LB", arMA = "ar-MA", arAE = "ar-AE", en, enUS = "en-US", enGB = "en-GB", fr, de, tr
    var id: String { get }; var serverKey: String { get }; var bcp47: String { get }; var label: LText { get }; var flag: String { get }
}
struct TranscribeResponse: Decodable, Sendable { var text: String?; var lang: String?; var error: String? }

// FenceModels.swift
struct CodeMeta: Codable, Sendable, Equatable { var lang: String?; var name: String?; var title: String?; var preview: Bool?; var ext: String?; var intro: String?; var outro: String? }   // wire keys: name is "filename", title is "label"
struct FileMeta: Codable, Sendable, Equatable { var format: String; var name: String?; var title: String?; var pages: Int?; var jobId: String?; var artifactId: String?; var subtitle: String?; var theme: String?; var template: String?; var artifactParts: Int?; var artifactEndpoint: String?; var isDurableLongFile: Bool { get } }   // wire keys: name is "filename", pages is "pageCount"
enum FirasFence: Sendable, Equatable {
    case code(CodeMeta, body: String), file(FileMeta), image(MediaMeta), video(MediaMeta), music(MediaMeta)
    case agent(AgentJob), project(CodeProject), ask(AskSpec), sources([BrainSource]), plot(String)
    static func parse(name: String, body: String) -> FirasFence?          // nil → render as a plain code block
    static func firstFence(in markdown: String) -> (name: String, body: String, range: Range<String.Index>)?
}

// AccountModels.swift
struct Announcement: Codable, Sendable, Equatable, Identifiable { let id: String; var title: String; var body: String; var pinned: Bool; var at: Double; var video: String?; var image: String?; var lang: String?; var titleEn: String?; var bodyEn: String?; var by: String?; var editedAt: Double?; func localizedTitle(_ lang: AppLanguage) -> String; func localizedBody(_ lang: AppLanguage) -> String; static let builtinLaunch: Announcement }   // `at` decodes the wire key `ts`; the record is bilingual by storage
struct MemoryEntry: Codable, Sendable, Equatable, Identifiable { let id: String; var text: String; var at: Double? }
// SettingsModels.swift keeps FirasChatBackup / FirasChatBackupEntry / ChatBackupValidationError (existing), plus the
// ChangeEmailRequest / ChangePasswordRequest / DeleteAccountRequest / RedeemRequest DTOs.
// FirasChatBackupEntry.messages is [PersistedMessage].
// MediaMeta additionally carries `var jobId: String?` - the firas-video fence's returning-card key
// (jobId without key means: poll that job, never start a second render).
```

---

## Localization/

```swift
struct LText: Sendable, Hashable {
    let ar: String; let en: String
    init(ar: String, en: String)
    func callAsFunction(_ lang: AppLanguage) -> String
    func fmt(_ lang: AppLanguage, _ args: CVarArg...) -> String       // String(format:) ; use %@ and %ld
}
enum Strings {                                                        // root namespace; each feature file adds `extension Strings { enum X { static let key = LText(ar:en:) } }`
    enum Common {}   // ok, cancel, retry, done, copy, copied, share, delete, undo, later, close, save, back
    enum Errors {}   // offline, timeout, tooFast, serverBusy, generic, sessionExpired, guestLimitReached, guestNetworkLimit, quotaMember (fmt: name, lim), productNames
    enum Notify {}   // the verbatim server table: mediaReady/mediaFailed per kind, productDone/productFailed per product, callEnded
}
enum ErrorAction: Equatable {
    case toast(LText), toastText(String), signUpPrompt(FeatureKey), sessionExpired
    case blockedAgent(AgentActiveJob?, AgentCredits?), creditsBlocked(AgentCredits?), hideFeature(FeatureKey), silent
}
enum ErrorPresenter {
    static func present(_ error: Error, feature: FeatureKey?, isGuest: Bool, lang: AppLanguage) -> ErrorAction
    static func presentJobTerminal(_ terminal: JobTerminal, kind: JobKind, isGuest: Bool, lang: AppLanguage) -> ErrorAction
    static func quotaText(product: String?, limit: Int?, lang: AppLanguage) -> String                       // the member quota sentence
    static func quotaText(product: String?, limit: Int?, isGuest: Bool, scope: String?, lang: AppLanguage) -> String   // guests get guestLimitReached / guestNetworkLimit
    static func featureKey(for kind: JobKind) -> FeatureKey
    static func featureKey(named raw: String?) -> FeatureKey?
}
```

---

## DesignSystem/

```swift
enum FirasTheme: String, CaseIterable, Codable, Sendable, Identifiable { case light, dark, black, midnight, graphite, amber; var id: String { get }; var isLight: Bool { get }; var title: LText { get }; var palette: FirasPalette { get } }
struct FirasPalette: Sendable {
    // base
    let background, backgroundSubtle, surface, surfaceSunken, sidebar, textPrimary, textSecondary, textMuted, border, borderStrong, accent, accentHover, accentDeep, onAccent, success, error: Color
    // derived
    let accentSoft, accentRing, glassTint, glassWash, glassStroke, glassShadow, userFill, userInk, userEdge, userSheen, maxTierText, maxTierDot, maxTierBg, planGold, planDiamond, callGround, codeWarn, codeOk: Color
    let grainOpacity: Double; let washBlendsLighter: Bool; let glassShadowOpacity: Double
    static let tagColors: [String: Color]      // red, amber, green, teal, blue, purple
}
enum FontScale: String, CaseIterable, Codable, Sendable { case small = "sm", medium = "md", large = "lg"; var factor: CGFloat { get } }
enum ContentWidth: String, CaseIterable, Codable, Sendable { case normal, wide; var maxWidth: CGFloat { get } }   // 760 / 980
enum MotionPreference: String, CaseIterable, Codable, Sendable { case full, reduced }

@MainActor @Observable final class PreferencesStore {                 // = the ThemeStore; UserDefaults keys unchanged from Codex
    var theme: FirasTheme; var language: AppLanguage; var tier: ModelTier; var responseMode: ResponseMode
    var fontScale: FontScale; var contentWidth: ContentWidth; var motionPreference: MotionPreference
    var webSearchEnabled: Bool; var thinkingEnabled: Bool; var sendOnReturn: Bool; var sharpenImages: Bool
    var callVoice: CallVoice; var bargeInEnabled: Bool; var dictationDialect: DictationDialect; var uiSoundsEnabled: Bool
    var guestActive: Bool; var consentAccepted: Bool; var notificationsExplained: Bool; var lastSeenAnnouncementAt: Double
    init(defaults: UserDefaults = .standard)
    var palette: FirasPalette { get }; var lang: AppLanguage { get }; var motionEnabled: Bool { get set }
    func resetToDefaults()
}

enum FirasGlass { enum Level: Sendable { case chrome, floating, sheet } }
extension View {
    func firasGlass(_ level: FirasGlass.Level, palette: FirasPalette, in shape: AnyShape = AnyShape(Capsule())) -> some View
    func surfaceCard(_ palette: FirasPalette, radius: CGFloat = 9) -> some View
    func bidiIsland(for text: String, fallback lang: AppLanguage) -> some View        // sets layoutDirection + multilineTextAlignment
    func forceLTR() -> some View
    func readingColumn(_ width: ContentWidth) -> some View
    func firasSheetBackground(_ palette: FirasPalette) -> some View                   // .sheet level; no solid presentationBackground on 26
}
struct FirasBackground: View { init(palette: FirasPalette, showHalo: Bool) }
struct SurfaceCard<Content: View>: View { init(palette: FirasPalette, radius: CGFloat = 9, @ViewBuilder content: () -> Content) }

enum FirasType {
    static func prose(_ lang: AppLanguage, scale: FontScale) -> (font: Font, lineSpacing: CGFloat)   // .body, 9 ar / 6 en
    static let mono: Font; static let caption: Font; static let label: Font
}
extension Text { func firasTracking(for text: String) -> Text }        // -0.3 only when no Arabic scalar
enum FirasMotion {
    static let standard, sheet, composer, tierPop, reveal: Animation; static let drawerFlick: Animation
    @MainActor static func isOn(prefs: PreferencesStore, reduceMotion: Bool) -> Bool     // reads PreferencesStore.motionEnabled; every caller is a view body
    static let fade: Animation                                                       // 120 ms easeOut, used when motion is off
}
@MainActor enum Haptics { static func send(); static func stop(); static func select(); static func attach(); static func toolStep(); static func error(); static func undo(); static func callConnected(); static func callEnded(); static func recordStart(); static func recordStop(); static func prepareCompletion() }
@MainActor final class FirasSound { static let shared: FirasSound; enum Sound { case send, done }; func play(_ s: Sound, prefs: PreferencesStore, callActive: Bool) }

@MainActor @Observable final class ToastCenter {
    struct Toast: Identifiable, Equatable { let id: UUID; let text: String; let actionTitle: String?; let isError: Bool }
    private(set) var current: Toast?
    func show(_ text: String, isError: Bool = false, duration: TimeInterval = 3.2)
    func show(_ text: String, actionTitle: String, duration: TimeInterval = 7, action: @escaping @MainActor () -> Void)
    func performAction(); func dismiss()
}
struct FirasPill: View { init(text: String, symbol: String?, selected: Bool, palette: FirasPalette, action: @escaping () -> Void) }
struct FirasIconButton: View { init(symbol: String, label: String, palette: FirasPalette, prominent: Bool = false, action: @escaping () -> Void) }   // 44 pt hit target
struct LiveDot: View { init(palette: FirasPalette, motionOn: Bool) }
struct SkeletonView: View { enum Kind { case transcript, sidebar, tiles }; init(kind: Kind, palette: FirasPalette, motionOn: Bool) }
struct EmptyStateView: View { init(title: String, subtitle: String?, buttonTitle: String?, palette: FirasPalette, action: (() -> Void)?) }
struct FirasActivityLabel: View { init(text: String, palette: FirasPalette, motionOn: Bool) }     // existing, fixed
```

---

## Jobs/ and Notifications/

```swift
protocol JobObserver: AnyObject {
    @MainActor func job(_ pointer: JobPointer, didProgress snapshot: JobSnapshot)
    @MainActor func job(_ pointer: JobPointer, didFinish terminal: JobTerminal) async -> Bool   // true = landed, manager may forget
}
protocol JobKindDriver: Sendable {
    var kind: JobKind { get }
    var spec: JobKindSpec { get }
    func read(_ pointer: JobPointer, api: APIClient) async throws -> DriverRead
    func cancel(_ pointer: JobPointer, api: APIClient) async throws -> Bool
    func stream(_ pointer: JobPointer, api: APIClient) -> AsyncThrowingStream<DriverRead, Error>?   // nil when !spec.usesSSE
}
enum JobKindSpecs { static func spec(_ kind: JobKind) -> JobKindSpec }
struct ChatJobDriver: JobKindDriver { init(kind: JobKind) }      // chat, longdoc, longfile, codebuild, brainask
struct AgentJobDriver: JobKindDriver { init() }
struct MediaJobDriver: JobKindDriver { init(kind: JobKind) }     // image, video, music

@MainActor @Observable final class JobManager {
    init(api: APIClient, session: SessionStore, prefs: PreferencesStore, notifications: NotificationManager, network: NetworkMonitor)
    private(set) var pointers: [JobPointer]
    func isLive(conversationID: String) -> Bool
    func liveCount(product: ProductKind) -> Int
    func pointer(id: String) -> JobPointer?
    func pointer(forConversation id: String) -> JobPointer?
    func register(_ observer: any JobObserver, for kind: JobKind)
    func startChatQueueJob(_ request: ChatJobRequest, pointer draft: JobPointer) async throws -> JobPointer      // persists pointer before returning; replayed completed → observer.didFinish directly
    func startMediaJob(kind: MediaKind, request: any Encodable & Sendable, pointer draft: JobPointer) async throws -> JobPointer
    func attach(_ pointer: JobPointer)
    func cancel(jobID: String) async -> Bool
    func forget(jobID: String)
    func resumeAll(owner: String) async
    func suspend(owner: String)
    func refreshOnce(budgetSeconds: Double) async -> Bool          // BG task entry; true when anything is still live
    func applicationDidBecomeActive(); func applicationDidEnterBackground()
    var callActive: Bool                                           // set by CallEngine; gates CompletionCue
}
enum BackgroundRefresh {
    static var identifier: String { get }                          // AppConfiguration.bundleID + ".jobs"
    @MainActor static func register(handler: @escaping @Sendable () async -> Bool)
    static func schedule(after seconds: TimeInterval)
    static func cancelPending()
}

@MainActor @Observable final class NotificationManager {
    init(prefs: PreferencesStore)
    private(set) var authorization: UNAuthorizationStatus
    func refreshAuthorization() async
    func requestIfNeeded() async -> Bool
    func postJobTerminal(_ pointer: JobPointer, terminal: JobTerminal, lang: AppLanguage) async
    func postCallEnded(reason: String, lang: AppLanguage) async
    func clearDelivered(jobID: String)
}
enum NotificationRouter {
    static func userInfo(for pointer: JobPointer, phase: String) -> [String: Any]
    static func route(userInfo: [AnyHashable: Any]) -> AppRoute?
}
@MainActor enum CompletionCue {
    static func prepare()
    static func fire(key: String, success: Bool, prefs: PreferencesStore, callActive: Bool) async   // ≤ 320 ms; no-op if consumed / background / call
}
final class FirasAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var lifecycle: (any FirasLifecycleHost)?           // set by FirasAIApp after AppEnvironment exists
}
@MainActor protocol FirasLifecycleHost: AnyObject {                // declared in FirasAppDelegate.swift; AppLifecycle adopts it in Batch 2
    func handleNotificationTap(userInfo: [AnyHashable: Any])
    func shouldPresentNotificationInForeground(userInfo: [AnyHashable: Any]) -> Bool    // defaulted: true
    func refreshJobsInBackground(budgetSeconds: Double) async -> Bool                   // defaulted: false - Batch 2 must call env.jobs.refreshOnce(budgetSeconds:)
}
```

---

## Stores/

```swift
@MainActor @Observable final class SessionStore {
    enum Phase: Equatable { case booting, member(User), guest(User), signedOut, awaitingVerification(pid: String, email: String), unreachable(lastKnown: User?) }
    init(api: APIClient, prefs: PreferencesStore, network: NetworkMonitor)
    private(set) var phase: Phase
    var user: User? { get }; var identityID: String? { get }; var isMember: Bool { get }; var isGuest: Bool { get }; var isAuthenticated: Bool { get }
    var sessionExpiredNotice: Bool
    var errorText: String?                                         // already localized via ErrorPresenter
    var isRestoring: Bool { get }; var isLoggingIn: Bool { get }; var isSigningUp: Bool { get }; var isGoogle: Bool { get }; var isForgot: Bool { get }; var isAccountOp: Bool { get }
    var onGuestBecameMember: ((_ previousGuestID: String) async -> Void)?
    var onUnauthorized: (() -> Void)?                              // JobManager hooks suspend(owner:)
    func restore() async
    func applicationDidBecomeActive() async
    func handleUnauthorized() async
    func continueAsGuest() async -> Bool
    func login(email: String, password: String) async -> Bool                       // maps its own 401/500 to Strings.Errors.credentials / .credentialsOrGoogle (ARCHITECTURE 2.15); ErrorPresenter cannot, it never sees the route
    func signup(name: String, email: String, password: String) async -> Bool
    func pollVerification() async -> Bool                          // one poll; caller loops every 3 s while visible
    func resendVerification() async -> Bool
    func verifySignup(token: String) async -> Bool
    func forgotPassword(email: String) async -> Bool
    func resetPassword(uid: String, token: String, password: String) async -> Bool
    func signInWithGoogle(provider: GoogleOAuthProvider) async -> Bool
    func logout() async
    func refreshAccount() async
    func changeEmail(currentPassword: String, newEmail: String) async -> Bool
    func changePassword(currentPassword: String, newPassword: String) async -> Bool
    func deleteAccount(currentPassword: String) async -> Bool
    func redeem(code: String) async -> Bool
}

@MainActor @Observable final class ConversationState {
    enum Phase: Equatable { case idle, searching, thinking, streaming, completing, failed(String) }
    let conversationID: String
    var phase: Phase; var jobPointerID: String?; var plan: PlanCycle
    var liveText: String; var liveReasoning: String; var errorStrip: String?; var isAtBottom: Bool; var pendingQuote: String?
    var isBusy: Bool { get }
}
@MainActor @Observable final class ChatStore: JobObserver {
    init(api: APIClient, session: SessionStore, jobs: JobManager, prefs: PreferencesStore, drafts: DraftStore, guestChats: GuestChatStore, toasts: ToastCenter, router: Router, network: NetworkMonitor)
    private(set) var summaries: [ChatSummary]
    private(set) var conversations: [String: ChatConversation]
    private(set) var states: [String: ConversationState]
    private(set) var isLoadingList: Bool
    func loadConversations() async
    func open(_ id: String) async
    func newConversation(product: ProductKind, flags: (agent: Bool, codeProj: Bool, brainNb: Bool)) -> String    // local id; server create is lazy on first send
    func ensureServerChat(_ id: String) async -> String?           // creates on the server for members; nil for guests
    func state(for id: String) -> ConversationState
    func send(text: String, attachments: [PreparedAttachment], in id: String, product: ProductKind) async
    func stop(in id: String) async
    func regenerate(messageID: String, in id: String, tier: ModelTier?) async
    func continueAnswer(messageID: String, in id: String) async
    func submitAsk(answers: [String: [String]], extra: String, askMessageID: String, in id: String) async
    func approvePlan(in id: String) async
    func selectVersion(messageID: String, index: Int, in id: String)
    func rename(_ id: String, title: String) async
    func pin(_ id: String, _ pinned: Bool) async
    func delete(_ id: String) async                                // 7 s undo toast; DELETE deferred
    func appendAssistantTurn(_ message: ChatMessage, in id: String) async     // used by Media/Brain/Agent stores to file fences
    func appendUserTurn(_ message: ChatMessage, in id: String) async
    func persist(_ id: String) async
    func refreshFromServer(_ id: String) async
    func applicationDidBecomeActive() async
    func search(_ query: String) -> [ChatSummary]
    func summaries(for product: ProductKind) -> [ChatSummary]
}
struct PreparedAttachment: Sendable, Equatable { let name: String; let kind: String; let text: String?; let imageBase64: String?; let thumbnailDataURL: String?; let byteCount: Int; let truncated: Bool }

@MainActor @Observable final class DraftStore { init(); func draft(for key: String) -> String; func set(_ text: String, for key: String); func clear(_ key: String); func flush() }   // key = conversationID or "new:<product>"
actor GuestChatStore { init(disk: DiskStore); func load(owner: String) async -> [ChatConversation]; func save(_ c: ChatConversation, owner: String) async; func delete(_ id: String, owner: String) async; func purgeExpired() async }
@MainActor final class GuestMigration { init(api: APIClient, guestChats: GuestChatStore, chat: ChatStore, toasts: ToastCenter); func run(previousGuestID: String) async }

@MainActor @Observable final class AgentStore: JobObserver {
    init(api: APIClient, session: SessionStore, jobs: JobManager, chat: ChatStore, prefs: PreferencesStore, toasts: ToastCenter, router: Router)
    private(set) var missions: [String: AgentJob]                  // keyed by conversationID (latest mission)
    private(set) var credits: AgentCredits?
    private(set) var blocked: [String: ErrorAction]                // per conversation
    var liveConversationID: String? { get }
    func start(task: String, attachments: [PreparedAttachment], in conversationID: String) async
    func resume(in conversationID: String) async
    func refreshCredits() async
    func artifactURL(jobID: String, index: Int, download: Bool) async -> URL?
    func exportMarkdown(conversationID: String) -> String
}
@MainActor @Observable final class CodeStore: JobObserver {
    init(api: APIClient, session: SessionStore, jobs: JobManager, chat: ChatStore, prefs: PreferencesStore, toasts: ToastCenter, router: Router, cache: CodeProjectCache)
    private(set) var projects: [ChatSummary]
    private(set) var openProjectID: String?
    private(set) var project: CodeProject?
    private(set) var thread: CodeChatThread
    private(set) var buildPhase: JobPhase?; private(set) var buildElapsed: TimeInterval
    var selectedPath: String?; var consoleLines: [ConsoleLine]
    func loadProjects() async
    func create(name: String, brief: String, attachments: [PreparedAttachment]) async -> String?
    func open(_ id: String) async
    func updateFile(path: String, content: String)                 // debounced commit + snapshot
    func addFile(path: String); func deleteFile(path: String); func renameFile(from: String, to: String)
    func askAI(instruction: String, attachments: [PreparedAttachment]) async -> CodeEditPlan?
    func apply(_ plan: CodeEditPlan, selected: Set<String>)
    func undoLastApply()
    func save() async
    func share() async -> URL?
    func exportZip() async -> URL?
    func delete(_ id: String) async
}
struct ConsoleLine: Identifiable, Sendable, Equatable { let id: UUID; let level: String; let text: String; let at: Date }
actor CodeProjectCache { init(disk: DiskStore); func load(id: String) async -> CodeProject?; func save(_ p: CodeProject, id: String) async; func delete(id: String) async }

@MainActor @Observable final class BrainStore: JobObserver {
    init(api: APIClient, session: SessionStore, jobs: JobManager, chat: ChatStore, prefs: PreferencesStore, toasts: ToastCenter, router: Router)
    private(set) var docs: [BrainDocument]; private(set) var limits: BrainLibraryLimits?; private(set) var usage: BrainLibraryUsage?
    var excluded: Set<String>; var pins: Set<String>; var range: ClosedRange<Int>?; var compareArmed: Bool; var forceOCR: Bool
    private(set) var imports: [BrainImportProgress]
    private(set) var threadID: String?
    var activeDocIDs: [String] { get }
    func loadLibrary() async
    func importFile(url: URL) async
    func cancelImport(id: String)
    func deleteDoc(id: String) async
    func ask(_ question: String, outline: Bool, in conversationID: String) async
    func stopAsk()
    func passage(docID: String, index: Int) async -> BrainPassage?
}
struct BrainImportProgress: Identifiable, Sendable, Equatable { enum Stage: Equatable { case reading(Int, Int), ocr(Int, Int), uploading(Int, Int), done, failed(String) }; let id: String; let name: String; var stage: Stage }
final class BrainAsker: Sendable {
    init(api: APIClient)
    struct Turn: Sendable { let question: String; let outline: Bool; let docIDs: [String]; let range: ClosedRange<Int>?; let compare: Bool; let isMember: Bool; let lang: AppLanguage; let cid: String; let history: [ChatMessage] }
    enum Event: Sendable { case pending(LText), delta(String), sources([BrainSource]), done(String), failed(Error) }
    func run(_ turn: Turn) -> AsyncStream<Event>
}

@MainActor @Observable final class MediaStore: JobObserver {
    init(api: APIClient, session: SessionStore, jobs: JobManager, chat: ChatStore, prefs: PreferencesStore, toasts: ToastCenter, router: Router, assets: MediaAssetRepository)
    private(set) var creations: [MediaCreation]                    // newest first; scanned from conversations + local index
    private(set) var imageQuota: ImageQuota?
    func reload() async
    func createImage(prompt: String, shape: ImageShape?, in conversationID: String?) async
    func editImage(sourceKey: String, prompt: String, in conversationID: String?) async
    func createVideo(prompt: String, seconds: Int, firstFrameJPEGBase64: String?, in conversationID: String?) async
    func createMusic(prompt: String, lyrics: String?, seconds: Int, in conversationID: String?) async
    func regenerate(_ creationID: String) async
    func localURL(for creation: MediaCreation) async -> URL?      // downloads on demand; cached
    func saveToPhotos(_ creationID: String) async -> Bool
    func refreshQuota() async
}
actor MediaAssetRepository { init(disk: DiskStore); func url(forFilename: String) -> URL; func store(temp: URL, key: String, ext: String) async throws -> String; func delete(filename: String) async; func trim(keepingNewest: Int) async }
@MainActor @Observable final class AnnouncementStore { init(api: APIClient, prefs: PreferencesStore); private(set) var items: [Announcement]; var unseenCount: Int { get }; func load() async; func markSeen() }
@MainActor @Observable final class MemoryStore { init(api: APIClient); private(set) var entries: [MemoryEntry]; func load() async; func delete(id: String?) async; func learn(_ text: String) }
actor ImageCache { static let shared: ImageCache; func image(forDataURL: String) async -> UIImage?; func image(forFile: URL) async -> UIImage?; func store(_ image: UIImage, key: String) }
```

---

## Prompting/ and Rendering/

```swift
enum PromptCatalog { /* landed verbatim; ALL-STRING parameters */ static func systemPrompt(tier: String, product: String, mode: String, lang: String, think: Bool, requestKind: String) -> String }
// PromptBuilder owns `static let executeNote` / `static let forcedPlanNote` (verbatim web-plan-mode.md 7.3b/7.3c),
// and PromptInput gains one additive defaulted field `var explicitSearch: Bool = false` (only an explicit search downgrades the tier).
enum RequestKind: Sendable, Equatable { case chat, code, file(format: String, explicitPages: Int?), image, imageEdit, video, music, longdoc(sections: Int), longfile(format: String, pages: Int), irab }
enum RequestClassifier { static func classify(_ text: String, hasImages: Bool, lang: AppLanguage) -> RequestKind; static func detectCodeRequest(_ text: String) -> Bool; static func parseExplicitPageCount(_ text: String) -> Int?; static func refersToPreviousImage(_ text: String) -> Bool }
struct PromptInput: Sendable {
    let tier: ModelTier; let product: ProductKind; let mode: ResponseMode; let lang: AppLanguage; let thinkToggle: Bool
    let kind: RequestKind; let planTurn: PlanTurnKind; let askRounds: Int
    let searchContext: String?; let searchWasEmpty: Bool
    let history: [ChatMessage]; let lastUser: ChatMessage; let reattachImages: [String]?
}
struct PromptOutput: Sendable { let messages: [OutgoingMessage]; let tier: ModelTier; let think: Bool; let trimmed: Bool }
enum PromptBuilder { static func build(_ input: PromptInput) -> PromptOutput; static func fileGuidance(format: String, lang: AppLanguage) -> String }
enum SearchContext {
    enum Trigger: Equatable { case none, silent, explicit }
    static func trigger(for text: String, toggleOn: Bool, hasImages: Bool) -> Trigger
    static func query(from text: String) -> String                 // ≤ 280
    static func format(_ results: [WebSearchResult], lang: AppLanguage) -> String   // nonce-fenced block
    static func run(api: APIClient, text: String, trigger: Trigger, lang: AppLanguage) async -> (context: String?, wasEmpty: Bool)   // 8 s explicit / 1.5 s silent
}
enum MessageSerializer {
    static func outgoing(_ m: ChatMessage, reattachImages: [String]?) -> OutgoingMessage
    static func persisted(_ m: ChatMessage) -> PersistedMessage
    static func persisted(_ c: ChatConversation) -> [PersistedMessage]
    static func merge(local: [ChatMessage], server: [ChatMessage]) -> [ChatMessage]   // by cid; server wins when longer
}
enum HistoryWindow { static func window(_ history: [ChatMessage], budgetChars: Int = 400_000) -> (kept: [ChatMessage], trimmed: Bool) }
enum EngineFailureDetector { static func isFailure(_ answer: String) -> Bool }
enum AutoTitle { static func provisional(from text: String) -> String /* 42 chars */; static func generate(api: APIClient, firstUser: String, firstAnswer: String, lang: AppLanguage) async -> String? }

enum PlanTurnKind: Sendable, Equatable { case auto, clarifyOrPlan, execute(originID: String), revision, forcedPlan }
enum PlanPhase: Equatable, Sendable, Codable { case none, awaitingAnswers(askMessageID: String), awaitingApproval(planMessageID: String), executing(originID: String), delivered(originID: String) }
struct PlanCycle: Sendable, Equatable, Codable {
    var phase: PlanPhase; var snapshotMode: ResponseMode; var askRounds: Int; var originID: String?
    static let idle: PlanCycle
    mutating func userSent(_ m: ChatMessage, liveMode: ResponseMode, product: ProductKind) -> PlanTurnKind
    mutating func assistantFinished(_ m: ChatMessage, ask: AskSpec?)
    mutating func pauseForCall(); mutating func resumeAfterCall()
    static func derive(from messages: [ChatMessage], snapshot: ResponseMode?) -> PlanCycle
    var showsStartPill: Bool { get }
}
struct AskSpec: Codable, Sendable, Equatable {
    struct Option: Codable, Sendable, Equatable { let id: String; let label: String }
    struct Question: Codable, Sendable, Equatable { let id: String; let text: String; let options: [Option]; let multi: Bool; let recommended: [String]; let allowExtra: Bool }
    let questions: [Question]; let intro: String?
    static func parse(_ markdown: String) -> AskSpec?              // firas-ask fence, or json fence / bare JSON with "questions"
    static func hasOpenAskFence(_ markdown: String) -> Bool
    func summary(answers: [String: [String]], extra: String, lang: AppLanguage) -> String
}
enum ApprovalMatcher { static func isApproval(_ text: String) -> Bool }

indirect enum MDBlock: Sendable, Equatable, Identifiable {
    case paragraph(AttributedString), heading(level: Int, AttributedString), list(ordered: Bool, start: Int, items: [[MDBlock]]), quote([MDBlock])
    case table(header: [AttributedString], rows: [[AttributedString]]), code(lang: String?, String), rule, mathDisplay(String), fence(FirasFence), raw(String)
    var id: String { get }
}
enum MarkdownBlocks { static func split(_ markdown: String, streaming: Bool) -> [String]; static func parse(_ chunk: String, lang: AppLanguage) -> MDBlock }
enum MarkdownInline {
    static func attributed(_ text: String, lang: AppLanguage, palette: FirasPalette) -> AttributedString   // = styled(structured(_:lang:), palette:)
    static func structured(_ text: String, lang: AppLanguage) -> AttributedString                          // parse + math, NO colours - this is what MDBlock caches
    static func styled(_ s: AttributedString, palette: FirasPalette) -> AttributedString                   // idempotent colouring at render time
}
enum MathScanner { static func protect(_ text: String) -> (text: String, spans: [String]); static func restore(_ text: String, spans: [String]) -> String }
enum MathText { static func unicode(_ tex: String) -> String }
enum MarkdownRenderer {                                              // the entry point; caches parsed blocks per messageID
    static func blocks(for markdown: String, messageID: String, streaming: Bool, lang: AppLanguage) -> (settled: [MDBlock], tail: MDBlock?)
    static func invalidate(messageID: String)
}
struct MarkdownView: View { init(markdown: String, messageID: String, streaming: Bool, lang: AppLanguage, palette: FirasPalette, prefs: PreferencesStore, onFence: @escaping (FirasFence) -> AnyView?) }
struct CodeBlockView: View { init(code: String, language: String?, palette: FirasPalette, collapsible: Bool, lang: AppLanguage = .arabic, onPreview: ((String, String?) -> Void)? = nil) }   // both extra arguments are defaulted; Batch 1 owners should pass them
enum CodeHighlighter { static func highlight(_ code: String, language: String?, palette: FirasPalette) -> AttributedString }
struct TableBlockView: View { init(header: [AttributedString], rows: [[AttributedString]], palette: FirasPalette) }
struct QuickReplies: View { init(from markdown: String, lang: AppLanguage, palette: FirasPalette, onPick: @escaping (String) -> Void) }
```

---

## Features/Voice/

```swift
enum CallEvent: Sendable { case ready, speechStarted, speechStopped, responseCreated, audio(Data), transcript(String, own: Bool), responseDone, interrupted, closed(code: Int?, reason: String), error(String) }
protocol CallTransport: AnyObject, Sendable {
    var events: AsyncStream<CallEvent> { get }
    func connect(token: LiveToken, language: AppLanguage, allowTools: Bool, reducedSetup: Bool) async throws   // returns after .ready or throws
    func send(pcm16: Data) async
    func requestGreeting() async
    func truncate(playedMs: Int) async
    func ping() async
    func close() async
}
final class OpenAIRealtimeTransport: CallTransport { init() }
final class GeminiLiveTransport: CallTransport { init() }
struct CallDiagnostics: Sendable, Equatable { let engine: String; let model: String; let reason: String }
@MainActor @Observable final class CallEngine {
    enum Phase: Equatable { case idle, preparing, minting, connecting, listening, thinking, speaking, ending, ended(String), failed(String) }
    init(api: APIClient, session: SessionStore, prefs: PreferencesStore, jobs: JobManager, notifications: NotificationManager, tts: TTSPlayer)
    private(set) var phase: Phase; private(set) var level: Float; private(set) var caption: String; private(set) var elapsed: Int
    private(set) var isMuted: Bool; private(set) var speakerOn: Bool; private(set) var speakerToggleAvailable: Bool
    private(set) var diagnostics: CallDiagnostics?; private(set) var guestCapSeconds: Int?
    var isActive: Bool { get }
    var onPause: (() -> Void)?; var onResume: (() -> Void)?          // ChatStore pauses PlanCycle
    func start() async
    func toggleMute(); func toggleSpeaker() async
    func retry() async
    func end(reason: String) async
}
final class CallAudioGraph: @unchecked Sendable {                     // serial queue inside
    init()
    func prepare(targetRate: Double, speaker: Bool) async throws -> AsyncStream<Data>   // mic frames, Int16 mono, 100 ms
    func schedule(pcm16: Data, sampleRate: Double)
    func flushPlayback() -> Int                                        // played ms
    func setGated(_ gated: Bool); func setMuted(_ muted: Bool); func setSpeaker(_ on: Bool) async
    var onConfigurationChange: (@Sendable () -> Void)?; var onRouteChange: (@Sendable (Bool) -> Void)?; var onInterruption: (@Sendable (Bool) -> Void)?
    func teardown() async
}
enum EchoGuard { static func shouldMute(rms: Float, playbackRms: Float, hangoverActive: Bool) -> Bool }
final class ThreeHopCall: Sendable { init(api: APIClient); func answer(wavBase64: String, dialect: DictationDialect, history: [OutgoingMessage], lang: AppLanguage, tier: ModelTier) async throws -> (transcript: String, reply: String, audio: Data, mime: String?) }
enum AudioSessionArbiter {
    enum Owner: Int, Sendable { case uiSound = 0, playback, record, call }
    static func acquire(_ owner: Owner, speaker: Bool = false) async throws
    static func release(_ owner: Owner) async
    static var current: Owner? { get async }
}
final class DictationRecorder: Sendable { init(); func start() async throws -> AsyncStream<Float>; func stop() async throws -> Data /* PCM16 16 kHz mono */; func cancel() async; var duration: TimeInterval { get async } }
enum WAVEncoder { static func wav(pcm16: Data, sampleRate: Int, channels: Int) -> Data; static func base64(_ wav: Data) -> String }
@MainActor @Observable final class DictationController {
    enum State: Equatable { case idle, recording, transcribing, failed(String) }
    init(api: APIClient, prefs: PreferencesStore, toasts: ToastCenter, network: NetworkMonitor)
    private(set) var state: State; private(set) var level: Float; private(set) var seconds: Int
    func start() async
    func finish() async -> String?                                    // transcript to append (with one leading space when draft non-empty), nil on cancel/failure
    func cancel() async
    func applicationDidEnterBackground()
}
@MainActor @Observable final class TTSPlayer {
    init(api: APIClient, prefs: PreferencesStore, toasts: ToastCenter)
    private(set) var speakingMessageID: String?
    private(set) var isSpeaking: Bool
    var callActive: Bool
    func toggle(messageID: String, text: String, lang: AppLanguage) async
    func stop()
    static func speakable(_ markdown: String) -> String
}
```

---

## Feature view entry points (frozen initialisers only)

```swift
struct RootView: View { init(env: AppEnvironment) }   // LANDED in Batch 2; the Batch 0 stub's init(prefs:session:network:) no longer exists.
struct AppShell: View { init(env: AppEnvironment) }
struct ChatScreen: View { init(env: AppEnvironment, conversationID: String?, product: ProductKind) }     // ai / agent / brain conversations share it
struct AgentScreen: View { init(env: AppEnvironment, conversationID: String?) }
struct CodeLauncherView: View { init(env: AppEnvironment) }
struct CodeWorkspaceView: View { init(env: AppEnvironment, projectID: String) }
struct BrainScreen: View { init(env: AppEnvironment, conversationID: String?) }
struct MediaStudioScreen: View { init(env: AppEnvironment) }
struct CallScreen: View { init(env: AppEnvironment) }
struct SettingsView: View { init(env: AppEnvironment, section: SettingsSection) }
struct AuthView: View { init(env: AppEnvironment, mode: AuthMode) }
struct LandingView: View { init(env: AppEnvironment) }
struct ConsentView: View { init(prefs: PreferencesStore, onContinue: @escaping () -> Void) }
struct SignUpPromptSheet: View { init(env: AppEnvironment, feature: FeatureKey) }
struct ComposerView: View { init(env: AppEnvironment, conversationID: String, product: ProductKind, placeholder: String) }
struct SidebarView: View { init(env: AppEnvironment) }
```

---

## Batch 1 reconciliation (integrator pass)

Everything below is **frozen too**: it is what actually shipped in Batch 1, verified against the
files under `ios/FirasAI`. No frozen signature above was changed by this batch — every entry here is
either an addition to a frozen type, or the chosen shape of a type this document did not pin.
Batch 2 must call these spellings exactly.

### App/ — `AppEnvironment`

`AppEnvironment` matches its frozen declaration. Four wiring facts the shell depends on:

* `session.onUnauthorized` is **not** set here. `JobManager.init` already installs it
  (`JobManager.swift:62`) and it is the only object that knows which owner is active, so
  `AppEnvironment` deliberately leaves the hook alone.
* `registerJobObservers()` is the **single** registration site for all nine job kinds. No store
  registers itself.
* `wireMediaHandoff()` sets `chat.onMediaRequest` to `MediaStore.createImage/createVideo/createMusic`,
  and `wireMemoryHandoff()` sets `chat.onAnswerLanded` to `MemoryStore.learn`.
* `wireCallHandoff()` sets `call.onPause` / `call.onResume`; `setCallActive(_:)` drives
  `jobs.callActive`, `tts.callActive`, `SongPlayer.shared.callActive` and every
  `ConversationState.plan.pauseForCall()` / `resumeAfterCall()`.

### Stores/ — additions to frozen types

```swift
extension ChatStore {                                   // every frozen member unchanged
    var lang: AppLanguage { get }
    var onMediaRequest: ((MediaKind, String, String) async -> Bool)?   // (kind, prompt, conversationID) -> handled
    var onAnswerLanded: ((String, ProductKind) -> Void)?               // the question that earned an answer -> MemoryStore.learn
    private(set) var listError: String?
    private(set) var loadingConversations: Set<String>
    func replaceSummaries(_ rows: [ChatSummary])                       // the only doors into the two
    func setConversation(_ conversation: ChatConversation?, forKey key: String)   // private(set) collections
    func resolve(_ id: String) -> String                               // server id -> local key
    func conversation(_ id: String) -> ChatConversation?
    func mutate(_ id: String, _ body: (inout ChatConversation) -> Void)
    func buffer(for id: String) -> StreamBuffer
    func touch(_ id: String)
    func persistLocalOnly(_ id: String) async
    func autoTitleIfNeeded(_ id: String) async
    func applyErrorAction(_ action: ErrorAction, in id: String?, silently: Bool = false) -> String?
    func localKey(forServer id: String) -> String?
    func ensureState(for key: String, conversation: ChatConversation)
    func rebuildSummaries(); func undoDelete(_ key: String); func commitDelete(_ key: String) async
    static func timestamp() -> String; static func clientID(for conversationID: String) -> String?
}
```

`ChatStore` is split across `ChatStore.swift`, `ChatStore+Persistence.swift` and
`ChatStore+Copy.swift`; `SendPipeline` across `SendPipeline.swift`, `+Turn.swift`, `+Landing.swift`.
Because `private` is file-scoped, the stored dependencies (`api`, `session`, `jobs`, `prefs`,
`drafts`, `guestChats`, `toasts`, `router`, `network`, `pipeline` and the internal caches) are
`internal`, not `private`. The frozen `private(set)` on `summaries` / `conversations` / `states` /
`isLoadingList` is unchanged.

`ChatStore.newConversation(product:flags:)` ignores `product` — the trio of flags already decides it,
exactly as the server models it. The parameter stays because the signature is frozen.

Conversation keying: a member's conversation keeps its local `ios_…` key for the app's life and
carries the server id in `ChatConversation.serverID`. `resolve(_:)` maps a server id onto the local
key; `rebuildSummaries()` folds the server list onto local keys so a chat never appears twice.

```swift
extension ConversationState {                            // every frozen member unchanged
    var streamingMessageID: String?                      // observed; TranscriptView reads it
    @ObservationIgnored var activeCID: String?
    @ObservationIgnored var isStopping: Bool
    @ObservationIgnored var autoRetryUsedForMessageID: String?
    @ObservationIgnored var lastTurnImages: [String]
    func settle(); func fail(_ message: String)
}

@MainActor final class SendPipeline {                    // not previously in this document
    static let jobPayloadCeiling: Int                    // 550_000
    static let streamCeiling: TimeInterval               // 15 min
    weak var store: ChatStore?
    var contexts: [String: ChatTurnContext]; var streamTasks: [String: Task<Void, Never>]
    var onMediaRequest: ((MediaKind, String, String) async -> Bool)?
    var onAnswerLanded: ((String, ProductKind) -> Void)?
    init(api: APIClient, session: SessionStore, jobs: JobManager, prefs: PreferencesStore,
         drafts: DraftStore, toasts: ToastCenter, router: Router)
    // Entry points mirror ChatStore's verbs (send / stop / regenerate / continueAnswer /
    // submitAsk / approvePlan) and are called only by ChatStore.
}
struct ChatTurnContext: Sendable { }                     // file-scope in SendPipeline.swift
struct FoldedAttachments: Sendable { }                   // file-scope in SendPipeline.swift

@MainActor final class StreamBuffer {                    // not previously in this document
    var text: String { get }; var reasoning: String { get }; var isEmpty: Bool { get }; var receivedCount: Int { get }
    func reset(); func append(content: String, reasoning: String); func adopt(text: String, reasoning: String)
    func finish() -> (text: String, reasoning: String)
    nonisolated static func delta(fromData data: String) -> (content: String, reasoning: String)?
    nonisolated static func splitThink(_ raw: String) -> (text: String, reasoning: String)
}

extension DraftStore {
    static func key(conversationID: String) -> String     // identity
    static func key(newIn product: ProductKind) -> String // "new:<raw>"
    func restore() async                                  // AppLifecycle.didBecomeActive
}
extension ImageCache { func purgeMemory() }
```

`PreparedAttachment` (frozen shape unchanged) is declared in `Stores/ChatStore+Copy.swift`.
`Strings.ChatStoreCopy` holds the three store-only sentences (`deleted`, `continueInstruction`,
`guestMigrated`).

```swift
extension AgentStore {                                   // every frozen member unchanged
    private(set) var missionCID: [String: String]        // which turn cid the drawn mission belongs to
    private(set) var stoppedConversations: Set<String>   // client-derived "stopped" (3 h expiry / {job:null} / 403)
    private(set) var starting: Set<String>
    // `liveConversationID` is a stored `var` rather than a computed `{ get }`; reads are unchanged.
}
extension CodeProjectCache {                             // frozen load/save/delete unchanged
    func records() async -> [CodeProjectRecord]          // the on-disk project index a guest launcher needs
    func loadThread(id: String) async -> CodeChatThread?
    func saveThread(_ thread: CodeChatThread, id: String) async
    func rename(id: String, to name: String) async
}
struct CodeProjectRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String; var name: String; var fileCount: Int; var updatedAt: Double; var isLocal: Bool { get }
}
extension CodeStore {                                    // every frozen member unchanged
    enum SaveState { case saved, editing, saving }
    private(set) var saveState: SaveState
    private(set) var isLoadingProjects, isOpening, isCreating, isAsking: Bool
    private(set) var askStartedAt: Date?; private(set) var listError, openError: String?
    private(set) var usingCachedCopy, canUndoApply, deletedLastProject: Bool
    private(set) var buildFileCount: Int?
    func closeProject(); func rebuild(brief: String) async
    func startBuild(projectID: String, name: String, brief: String, attach: String) async
    func appendConsole(_ line: ConsoleLine); func clearConsole()
    var recentErrorText: String { get }; func fileCount(for id: String) -> Int?
    func isBuilding(projectID: String) -> Bool; var openProjectName: String { get }; var selectedFile: CodeFile? { get }
}
extension BrainStore {                                   // every frozen member unchanged
    private(set) var isLoadingLibrary: Bool; private(set) var libraryError: String?
    private(set) var isAsking: Bool; private(set) var isGuestLibrary: Bool
    var isDurableAsk: Bool; var liveAnswer: String; var liveSources: [BrainSource]; var pendingNotice: String?
    var hasDocuments: Bool { get }; var selectionKey: String { get }; var storageOwner: String { get }
    func toggleExcluded(_ id: String); func togglePin(_ id: String); func clearPins(); func applyPins()
    func toggleCompare(); func setRange(from: Int?, to: Int?); func clearRange()
    func loadSelectionIfNeeded(); func persistSelection()
}
extension MediaStore {                                   // every frozen member unchanged
    private(set) var imageQuotaBlocked: Bool; private(set) var imageQuotaLimit: Int?
    private(set) var videoDefaultSeconds: Int; private(set) var isReloading, isSubmitting: Bool
    private(set) var lastFailureText: String?; private(set) var unavailableKinds: Set<MediaKind>
    private(set) var freesInMinutes: [String: Int]
    var pendingEditSourceID: String?
    var liveCreations: [MediaCreation] { get }; var editableImages: [MediaCreation] { get }
    func creation(id: String) -> MediaCreation?; func creations(kind: MediaKind?) -> [MediaCreation]
    func editImage(sourceData: Data, prompt: String, in conversationID: String?) async     // a photo, not a library key
    func createMusic(prompt: String, lyrics: String?, seconds: Int, styleOverride: String, in conversationID: String?) async
    func conversationTitle(_ id: String) -> String
    func resolveConversation(_ id: String?) async -> (local: String, server: String?)
    func openInChat(_ creationID: String); func remove(_ creationID: String) async
    func shareFile(for creation: MediaCreation) async -> URL?
    func clearFailure(); func setSubmitting(_ value: Bool)
    func isDownloading(_ id: String) -> Bool; func beginDownload(_ id: String); func endDownload(_ id: String)
    nonisolated static func dedupeKey(_ item: MediaCreation) -> String
    nonisolated static func scan(conversation: ChatConversation, owner: String) -> [MediaCreation]
}
extension MediaAssetRepository { func exists(filename: String) -> Bool; func removeAll() async }
extension AnnouncementStore {                            // frozen items / unseenCount / load / markSeen unchanged
    private(set) var isLoading, hasLoaded: Bool
    private(set) var failure: LText?                     // LText, resolved at render time
    var hasUnseen: Bool { get }; func item(id: String) -> Announcement?
    func translation(for item: Announcement, to lang: AppLanguage) async -> (title: String, body: String)?
    nonisolated static func mediaURL(_ path: String?, base: URL) -> URL?
    nonisolated static func merged(_ remote: [Announcement]) -> [Announcement]
}
extension MemoryStore {                                  // frozen entries / load / delete / learn unchanged
    private(set) var isLoading, isMutating, hasLoaded: Bool; private(set) var failure: LText?
    func reset()
}
```

`AnnouncementStore.failure` and `MemoryStore.failure` are `LText?`, not a resolved `String`: neither
store sees the language preference, so a string resolved inside the store would be wrong for an
English reader and would go stale on a language switch.

`MediaStore.imageQuota` cannot represent a 429 (`ImageQuota` is Decodable-only with no memberwise
initialiser). On 429 it stays nil and `imageQuotaBlocked` / `imageQuotaLimit` carry the state.

`ImageCache` is not used by the Media Studio: `MediaImageLoader`
(`Features/Media/MediaAssetRepository.swift`) downsamples with ImageIO off the main actor.
`Rendering/Cards/ImageCard` is the one caller of `ImageCache.shared.image(forFile:)`.

### Features/ — initialisers this document did not freeze

```swift
// Chat
struct TranscriptView: View { init(env: AppEnvironment, conversationID: String, product: ProductKind) }
struct WelcomeView: View { init(product: ProductKind, firstName: String?, palette: FirasPalette, lang: AppLanguage, motionOn: Bool) }
struct TierPill: View { init(tier: ModelTier, palette: FirasPalette, lang: AppLanguage, motionOn: Bool, action: @escaping () -> Void) }
struct TierPickerSheet: View { init(env: AppEnvironment); init(prefs: PreferencesStore) }
struct ModePill: View {
    init(env: AppEnvironment, conversationID: String)
    init(prefs: PreferencesStore, palette: FirasPalette, lang: AppLanguage)
    init(prefs: PreferencesStore, toasts: ToastCenter?, palette: FirasPalette, lang: AppLanguage, planActive: Bool)
}
struct AddContextSheet: View { init(env: AppEnvironment, product: ProductKind = .ai, onPick: @escaping (ComposerAttachmentPick) -> Void = { _ in }) }
struct CodeViewerSheet: View {
    init(env: AppEnvironment, messageID: String)                       // AppSheet.codeViewer(messageID:)
    init(env: AppEnvironment, code: String, language: String?, filename: String?)
}
struct LongFileViewer: View { init(env: AppEnvironment, jobID: String, title: String? = nil) }     // AppSheet.longFile(jobID:)
struct ShareSheetView: View { init(env: AppEnvironment, conversationID: String, messageCID: String?) }   // AppSheet.share
struct SharedChatView: View { init(env: AppEnvironment, shareID: String); init(env: AppEnvironment, id: String) }
@MainActor @Observable final class ShareController { init(env: AppEnvironment); enum Phase: Equatable { } }
@MainActor @Observable final class ExportController {
    init(env: AppEnvironment)
    enum Format: String, CaseIterable, Identifiable, Sendable { case markdown, text, pdf, image }
    struct Export: Identifiable, Equatable, Sendable { }
}
struct FirasActivitySheet: UIViewControllerRepresentable { init(url: URL); init(text: String) }
enum ChatTurnActions { }   // copy / regenerate / listen / export / continue / share-one / translate

// Rendering/Cards — every parameter after `lang` is defaulted, so the minimal call compiles
struct CodeCard: View  { init(meta: CodeMeta, code: String, palette: FirasPalette, lang: AppLanguage, isStreaming: Bool = false, motionOn: Bool = true, onPreview: ((String, String?) -> Void)? = nil, onContinue: (() -> Void)? = nil) }
struct FileCard: View  { init(meta: FileMeta, palette: FirasPalette, lang: AppLanguage, stage: Stage? = nil, motionOn: Bool = true, onOpen: (() -> Void)? = nil, onExport: (() -> Void)? = nil) }
struct LongFileCard: View { init(progress: LongFileProgress?, meta: FileMeta? = nil, palette: FirasPalette, lang: AppLanguage, motionOn: Bool = true, isCancelling: Bool = false, errorText: String? = nil, onStop: (() -> Void)? = nil, onOpen: (() -> Void)? = nil) }
struct ImageCard: View { init(meta: MediaMeta, palette: FirasPalette, lang: AppLanguage, phase: Phase = .ready, motionOn: Bool = true, resolveImage: ((MediaMeta) async -> URL?)? = nil, onOpen: (() -> Void)? = nil, onSave: (() -> Void)? = nil, onShare: (() -> Void)? = nil, onEdit: (() -> Void)? = nil, onRetry: (() -> Void)? = nil, onRegenerate: (() -> Void)? = nil) }
struct VideoCard: View { init(meta: MediaMeta, palette: FirasPalette, lang: AppLanguage, phase: Phase = .ready, motionOn: Bool = true, resolveFile: ((MediaMeta) async -> URL?)? = nil, onSave: (() -> Void)? = nil, onShare: (() -> Void)? = nil) }
struct SongCard: View  { init(meta: MediaMeta, palette: FirasPalette, lang: AppLanguage, phase: Phase = .ready, motionOn: Bool = true, playback: Playback = Playback(), onPlayPause: (() -> Void)? = nil, onSeek: ((Double) -> Void)? = nil, onDownload: (() -> Void)? = nil, onRegenerate: (() -> Void)? = nil) }
struct AgentCard: View { init(job: AgentJob, palette: FirasPalette, lang: AppLanguage, motionOn: Bool = true, onOpen: (() -> Void)? = nil, onResume: (() -> Void)? = nil) }
struct SourcesCard: View { init(sources: [BrainSource], palette: FirasPalette, lang: AppLanguage, onOpen: ((BrainSource) -> Void)? = nil) }

// Agent
struct AgentComposer: View { init(env: AppEnvironment, conversationID: String) }
struct MissionCard: View { init(env: AppEnvironment, conversationID: String, job: AgentJob?, blocked: ErrorAction?, stopped: Bool) }
struct MissionTimeline: View { init(job: AgentJob, palette: FirasPalette, lang: AppLanguage, motionOn: Bool) }
struct MissionFiles: View { init(env: AppEnvironment, job: AgentJob, onOpen: @escaping (MissionArtifactRequest) -> Void) }
struct ArtifactViewer: View { init(env: AppEnvironment, jobID: String, index: Int, name: String, type: String) }
struct CreditsSheet: View { init(env: AppEnvironment) }

// Code
struct FileNavigator: View { init(env: AppEnvironment) }
struct CodeEditorView: View { init(env: AppEnvironment, path: String? = nil, onSaveState: ((SaveState) -> Void)? = nil) }
struct PreviewWebView: View { init(env: AppEnvironment, reloadToken: Int = 0, onCreateIndex: (() -> Void)? = nil, onAskAI: (() -> Void)? = nil, onOpenConsole: (() -> Void)? = nil) }
struct ConsoleView: View { init(env: AppEnvironment, onFix: ((String) -> Void)? = nil, onRun: (() -> Void)? = nil) }
struct CodeAIBar: View { init(env: AppEnvironment, prefill: Binding<String> = .constant(""), attachments: Binding<[PreparedAttachment]> = .constant([]), onPlan: ((CodeEditPlan) -> Void)? = nil) }
struct DiffReviewSheet: View { init(env: AppEnvironment, plan: CodeEditPlan, onClose: (() -> Void)? = nil) }
// `CodeWorkspaceView` composes the four panes by these names (Features/Code/CodeWorkspacePanes.swift):
struct CodeWorkspacePreview: View { init(env: AppEnvironment, reloadToken: Int) }
struct CodeWorkspaceConsole: View { init(env: AppEnvironment, onFix: @escaping (String) -> Void) }
struct CodeWorkspaceAssistant: View { init(env: AppEnvironment, prefill: Binding<String>, onPlan: @escaping (CodeEditPlan) -> Void) }
struct CodeWorkspaceDiffReview: View { init(env: AppEnvironment, plan: CodeEditPlan, onClose: @escaping () -> Void) }

// Brain
struct BrainThreadView: View { init(env: AppEnvironment, conversationID: String?, onCitation: @escaping (BrainSource) -> Void) }
struct BrainAnswerView: View { init(markdown: String, messageID: String, streaming: Bool, lang: AppLanguage, palette: FirasPalette, prefs: PreferencesStore, onCitation: @escaping (BrainSource) -> Void) }
struct SourceChipsRow: View { init(store: BrainStore, prefs: PreferencesStore, onOpenLibrary: @escaping () -> Void) }
struct CitationChip: View { init(number: Int, subtitle: String? = nil, palette: FirasPalette, action: @escaping () -> Void) }
struct BrainLibrarySheet: View { init(env: AppEnvironment, embedded: Bool = false) }
struct PassageReaderSheet: View { init(env: AppEnvironment, source: BrainSource, question: String? = nil, embedded: Bool = false) }
@MainActor final class BrainImportPipeline {
    init(api: APIClient)
    func run(url: URL, forceVision: Bool, visionLeft: Int, lang: AppLanguage,
             onStage: @escaping (BrainImportProgress.Stage) -> Void) async throws -> BrainImportOutcome
    func cancel()
    nonisolated static func splitParts(_ pages: [BrainPage]) -> [[BrainPage]]
}
enum BrainDocumentExtractor { }   // PDF / image / plain text; Office archives delegate to OfficeDocumentExtractor
enum OfficeDocumentExtractor { static func extract(data: Data, filename: String, kind: BrainDocumentKind) throws -> ExtractedBrainDocument }
struct ExtractedBrainDocument: Sendable, Equatable { }
// deviceOCRPages / serverOCRPages / visionWanted / visionAttempted replace the old single `ocrPages`:
// web-brain-ux.md §15.1 forbids reporting on-device OCR to the server, which one field cannot express.
// `BrainStore.importFile(url:)` runs entirely through `BrainImportPipeline`; `ChatAttachmentProcessor`
// is the other caller of `OfficeDocumentExtractor.extract(data:filename:kind:)`.

// Media
struct MediaViewer: View { init(env: AppEnvironment, creationID: String) }        // AppCover.mediaViewer(creationID:)
struct MediaLibraryGrid: View { init(env: AppEnvironment, columns: Int, onCreate: @escaping () -> Void) }
struct MediaCreateForm: View { init(env: AppEnvironment) }
struct MediaQuotaPanel: View { init(env: AppEnvironment, kind: MediaKind) }                          // memberwise
struct MediaTile: View { init(env: AppEnvironment, creation: MediaCreation) }                        // memberwise
struct MediaActionBar: View { init(env: AppEnvironment, creation: MediaCreation, isSaving: Bool) }   // memberwise
struct SongPlayerBar: View { init(creationID: String, url: URL?, palette: FirasPalette, lang: AppLanguage, tts: TTSPlayer?) }
@MainActor @Observable final class SongPlayer { static let shared: SongPlayer; var callActive: Bool }

// Voice
struct OrbView: View {
    enum Mode { case idle, connecting, listening, thinking, speaking }
    init(level: Float, mode: Mode, palette: FirasPalette, motionOn: Bool, size: CGFloat)
}
struct DialectPickerSheet: View { init(prefs: PreferencesStore); init(env: AppEnvironment) }

// Auth
struct VerificationCard: View { init(env: AppEnvironment, email: String, onBack: @escaping () -> Void) }
struct ForgotPasswordSheet: View {
    enum Mode: Identifiable, Equatable { case forgot(email: String), reset(uid: String, token: String) }
    init(env: AppEnvironment, mode: Mode)
}

// Settings
struct NotificationSettingsView: View { init(env: AppEnvironment) }   // self-contained; AppSheet.notificationExplainer
struct MemorySettingsView: View { init(env: AppEnvironment) }         // AppSheet.memory
struct AnnouncementsSheet: View { init(env: AppEnvironment) }         // AppSheet.announcements
struct AnnouncementReader: View { init(env: AppEnvironment, announcement: Announcement) }
```

`SettingsSection` stays frozen at five cases, so `NotificationSettingsView` and
`MemorySettingsView` are pushed pages reached from the Data section rather than sections of their own.

### Voice additions to frozen types

```swift
extension CallEngine {                                   // every frozen member unchanged
    func prepareGraph(targetRate: Double) async -> AsyncStream<Data>?
    func finish(reason: String, failed: Bool) async
    func startThreeHop() async
    func setPhase(_ value: Phase); func setCaption(_ value: String)                 // the private(set) doors
    func record(engine: String, model: String, reason: String)                      // for the split files
    nonisolated static func requestMicrophonePermission() async -> Bool
    nonisolated static func rms(of frame: Data) -> Float
    nonisolated static func reason(for error: Error) -> String
    nonisolated static func speechLanguage(for text: String) -> String
    nonisolated static func fileExtension(for mime: String?, data: Data) -> String
    nonisolated static func decode(audio: Data, mime: String?, rate: Double) -> Data?
    nonisolated static func isGeminiCoolingDown() -> Bool; nonisolated static func startGeminiCooldown()
    nonisolated static func noSearchModels() -> [String]; nonisolated static func rememberNoSearch(model: String)
}
extension CallAudioGraph {                               // every frozen member unchanged
    var onLevel: (@Sendable (Float) -> Void)?            // the only source of CallEngine.level
    var playbackLevel: Float { get }
    var isPlaybackArmed: Bool { get }
    nonisolated static func pcm16(fromAudioFileAt url: URL, sampleRate: Double) throws -> Data
}
extension EchoGuard {                                    // shouldMute(rms:playbackRms:hangoverActive:) unchanged
    static let rmsFloor, overEcho, voiceFloor, floorDecay: Float
    static let requiredFrames, hangover: Int
    static func rms(pcm16: Data) -> Float
    static func silence(matching frame: Data) -> Data
}
extension DictationController {                          // every frozen member unchanged
    var onTranscript: ((String) -> Void)?                // the 300 s cap and the background auto-finish have no awaiting caller
    static func appending(_ transcript: String, to draft: String) -> String
}
extension TTSPlayer {                                    // every frozen member unchanged
    nonisolated static let chunkLimit: Int               // 1_300
    nonisolated static func chunks(of text: String) -> [String]
}
enum CallTransportError: Error, Sendable { var reason: String { get } }   // CallTransport.swift
enum CallJSON { }; final class CallWebSocket { }                          // CallTransport.swift
struct AudioSessionBusyError: Error, Sendable { }
enum CallAudioGraphError: Error, Sendable { }
enum CallRung: String, Sendable { }
enum ThreeHopError: Error, Sendable { }
```

`TTSPlayer.speakable(_:)` is `nonisolated static` so the call engine can call it off the main actor.
`TTSPlayer.callActive` and `SongPlayer.callActive` are computed over an `@ObservationIgnored` stored
flag — a `didSet` cannot survive the `@Observable` rewrite, which is the same reason
`PreferencesStore` avoids property observers.

`OpenAIRealtimeTransport` and `GeminiLiveTransport` are declared
`final class X: CallTransport, @unchecked Sendable` — both hold lock-guarded mutable state and
`CallTransport` refines `Sendable`. `GeminiLiveTransport.requestGreeting()` and `truncate(playedMs:)`
are deliberate no-ops (that rung has no greeting event, and `serverContent.interrupted` already tells
the model what the caller heard). `AudioSessionArbiter.configure` spells `.allowBluetoothHFP`, the
iOS 26 SDK name for `.allowBluetooth`. `CallAudioGraph.teardown()` does **not** release the session;
`CallEngine` calls `AudioSessionArbiter.release(.call)` after `transport.close()`, per
ARCHITECTURE §2.13. The echo guard runs in exactly one place — `CallEngine.startMicrophonePump` —
never also inside a transport.

### Localization namespaces added

`Strings.Composer` (`Features/Chat/ComposerView+Strings.swift`), `Strings.CodeUI`
(`Features/Code/CodeUIStrings.swift`) and `Strings.ChatStoreCopy` (`Stores/ChatStore+Copy.swift`) sit
beside the `Localization/Strings+*.swift` files. `Strings.Settings.Storage` is the Data tab's
namespace (an enum named `Data` would shadow `Foundation.Data` inside its own scope). No namespace or
key collides, and every `Strings.<NS>.<key>` reference in the target resolves.

### Deliberate contract choices worth knowing

* Agent enqueues with `tier: ModelTier.max.rawValue` — web parity (`web-agent-ux.md §1`,
  `audit-ios-agent-code.md A13`). The Manus worker ignores `tier`; the filed chat turn does not.
* `ChatJobRequest` has no `name` / `attach` field, so `CodeStore.startBuild` sends the project name in
  `title` and folds the attachment into `task`. Adding `var name: String?` / `var attach: String?` to
  `ChatJobRequest` would make those two lines exact.
* A durable Brain ask posts the frozen `BrainAskJobRequest` through
  `api.json(.post, "/api/chat/job", …)` and then `jobs.attach(pointer)` — `startChatQueueJob` takes a
  `ChatJobRequest`, which has no `docIds` and could only ever search the whole corpus.
* The share-link ceiling is **409** (`server-chat-jobs-chats.md §6`), not 429; 429 is plain rate
  limiting. Both sentences are distinct.
* `ExportController.Format` ships markdown / text / pdf / image only.
* `LengthMeter` measures against the web's `LENM_TIER_TOKENS` window (`design-brief.md §7.3`), not
  `ModelTier.tokenCap` — `tokenCap` is the answer's `max_tokens` and would mis-warn on every tier.
* `ChatStore.continueAnswer` sends a real instruction turn and stamps `mergedFrom` on the new row
  rather than appending into the previous answer; the seam is on the persist whitelist.
* Media routing from chat goes through `chat.onMediaRequest`; a guest is shown the sign-up prompt
  before anything is appended, and `MediaStore` writes both halves of the turn itself.

### Open items for the Batch 2 shell

1. `Router.open(.sharedChat(id:))` currently maps to `AppSheet.share(conversationID:messageCID:)`,
   which is the *create-a-link* sheet. `ShareSheetView` contains the damage by detecting a public
   share id (`s` + lowercase alphanumerics, 8–40 chars, no `_`, no UUID dashes) and rendering
   `SharedChatView` instead. A dedicated `AppSheet.sharedChat(id:)` case would let the shell present
   `SharedChatView` directly; `ShareSheetView.isPublicShareLink` is then deletable.
2. `Router.open(.reset(uid:token:))` sets `cover = .auth(.login)` and drops the payload. `AuthView`
   recovers it by consuming `router.pendingRoute` itself, so `AppShell` must leave `pendingRoute` set
   for `.reset` / `.verify` — otherwise password reset from an emailed link is unreachable.
3. Route `ProductKind.brain` to exactly one of `BrainScreen(env:conversationID:)` or
   `ChatScreen(env:conversationID:product:)`; both handle the product and neither is presented yet.
4. `ChatScreen` declares only `.toolbar { … }` and `.navigationBarTitleDisplayMode(.inline)`: the
   shell must supply the `NavigationStack` (iPhone) or split-view detail column (iPad), or the
   toolbar and the tier pill do not appear. It hosts `ComposerView` itself in
   `safeAreaBar` / `safeAreaInset(edge: .bottom)`.
5. Present `AppCover.mediaViewer(creationID:)` as `MediaViewer(env:creationID:)`, and
   `ProductKind.studio` as `MediaStudioScreen(env:)`.
6. `AppSheet` has no per-conversation gallery case, so `ChatScreen` omits the `صور المحادثة` toolbar
   item; in-chat images stay reachable through `AppCover.mediaViewer`.
7. `Resources/Info.plist` needs `NSPhotoLibraryAddUsageDescription` (save to Photos),
   `UIBackgroundModes: audio` and `NSSpeechRecognitionUsageDescription` (call continuation and
   dictation). `NSCameraUsageDescription` is already present.
8. `AgentScreen` and `ChatScreen` each place a `sidebar.leading` drawer button in `.topBarLeading`
   when `horizontalSizeClass == .compact`. If `AppShell` supplies its own compact drawer affordance,
   one of the two should go.

### Known gaps (implemented nowhere in Batch 1)

Drop and paste to attach on the transcript (the tray is `ComposerView` `@State`); the message-action
items that need a device-local store (save to shelf, simplify, ask-again, ask-elsewhere, compare,
focus read, pin, private note); `firas-project` and `plot` fences (no `ProjectCard` / `PlotCard`, so
`fenceView` returns nil and they render as plain code); the Agent saved-templates strip; the Brain
harvest corpus sweep and the coverage / terms / exam / study-plan panels; Pyodide, plan-then-build,
snapshots and find-across-files in Firas Code; Word / Excel / PowerPoint / HTML export.
`Rendering/Cards/LongFileCard` is built and correct but not yet placed by any host — the long-file
progress surface is `Features/Chat/LongFileViewer`, which reads the job pointer itself.

---

## Batch 2 reconciliation (integrator pass)

Everything below is **frozen too**: it is what actually shipped in the Batch 2 shell and wiring,
verified against the files under `ios/FirasAI`. No frozen signature above was changed by this batch.
Later batches must call these spellings exactly.

### App/ — the three wiring files

`FirasAIApp`, `AppEnvironment` and `AppLifecycle` match their frozen declarations. `RootView` is now
the frozen `init(env:)`; `FirasAIApp` builds the window as `env.inject(into: RootView(env: env))`.

```swift
extension AppEnvironment {                            // every frozen member unchanged
    func adoptCurrentIdentity() async                 // resumeAll(owner:) / suspend(owner:) + the first list load
}
```

`adoptCurrentIdentity()` is the **only** caller of `JobManager.resumeAll(owner:)` and
`JobManager.suspend(owner:)` — the frozen `JobManager` API has no self-starting entry point, so
`AppEnvironment` owns "which identity is being watched". It is re-entrancy guarded, idempotent, and
reached from two places: `AppLifecycle.didBecomeActive()` on every foreground, and a private
`observeIdentity()` — a `withObservationTracking` loop re-armed from its own callback — so a login
that happens while the app stays in the foreground re-attaches without waiting for a scene phase
change. If CI ever rejects `withObservationTracking` here, deleting the `observeIdentity()` call in
`init` is the whole fallback: job re-attachment still works on every foreground.

When the owner changes, `adoptCurrentIdentity()` also calls `chat.loadConversations()` — guarded on
`!chat.isLoadingList`, because `SidebarView.task(id: session.identityID)` loads the same list.
`ChatStore.loadConversations` raises `isLoadingList` synchronously before its first `await`, so
whichever of the two arrives first wins and the launch fires exactly one `GET /api/chats`.

`AppLifecycle.handle(url:)` presents Auth for `.verify` / `.reset` through `router.open(route)` and
**leaves `pendingRoute` set** — resolving open item 2 in favour of `AuthView.consumePendingRoute()`,
which is the only screen that can ask for a password (reset) or report a verdict (verify).
`AppShell.consumePendingRoute()` does the same: it opens every route and clears `pendingRoute` for
all of them except `.verify` / `.reset`.

`AnnouncementStore.load()` runs on every foreground (per `plan/App.md`). The store's `isLoading`
guard prevents overlap but there is no time-based throttle, so rapid app switching re-fetches the
list each time.

### Features/Shell/ — the types this batch declares

```swift
struct AppShell: View { init(env: AppEnvironment) }
struct RootView: View { init(env: AppEnvironment) }
struct CompactDrawer: View { init(env: AppEnvironment, isOpen: Binding<Bool>)
    static func panelWidth(for containerWidth: CGFloat) -> CGFloat }        // min(316, max(268, w − 92)) — round 3
struct SidebarView: View { init(env: AppEnvironment) }
struct SidebarProductSwitcher: View { init(env: AppEnvironment) }
struct SidebarHistoryList: View { init(env: AppEnvironment, query: String) }
struct SidebarSearch: View { init(env: AppEnvironment, query: Binding<String>) }
struct SidebarAccountPill: View { init(env: AppEnvironment) }
struct KeyboardCommands: View { init(env: AppEnvironment) }
struct ToastHostView: View { init(env: AppEnvironment) }
@MainActor @Observable final class ShellSignals {                          // KeyboardCommands.swift
    static let shared: ShellSignals
    var wantsSearchFocus: Bool
    func requestSearchFocus()
}
extension Strings { enum Shell }                                           // Localization/Strings+Shell.swift
```

`ShellSignals` exists because `SidebarView.init(env:)` is frozen and cannot take a focus binding:
`⌘K` raises `wantsSearchFocus`, and `SidebarSearch` lowers it on appear and on change. It is an
addition, not a signature change.

### Navigation containers — who owns the `NavigationStack`

Open item 4 is resolved as a split rule, and it is load-bearing for anyone adding a screen:

* The **shell** supplies the container for `ChatScreen` (`.ai`), `BrainScreen` (`.brain`) and the
  Code pair (`CodeLauncherView` / `CodeWorkspaceView`).
* **`AgentScreen` and `MediaStudioScreen` carry their own** — `AgentScreen` wraps its body in a
  `NavigationStack` and presents `CreditsSheet` from inside it; `MediaStudioScreen` owns a `TabView`
  with a `NavigationStack` per tab on iPhone and one `NavigationStack` on iPad. The shell places
  both **bare**; wrapping either draws a second navigation bar.

Open item 3 is resolved in favour of `BrainScreen(env:conversationID:)` for `ProductKind.brain`;
`ChatScreen` is used only for `.ai`, and `AgentScreen` for `.agent`.

Open item 8 is resolved by leaving the two screens' own buttons in place: `ChatScreen` and
`AgentScreen` each place their `sidebar.leading` item in `.topBarLeading` when the size class is
compact, so the shell adds a drawer affordance only for `BrainScreen`, the Code launcher (the
workspace owns the leading slot with its own chevron) and — as a floating glass button overlaid in
the empty leading slot — the Studio.

Open item 1 stays as it is: `Router.open(.sharedChat(id:))` still maps to `AppSheet.share(...)` and
`ShareSheetView` renders `SharedChatView` when it recognises a public share id. Adding an
`AppSheet.sharedChat(id:)` case would touch `App/AppRoute.swift`, which no Batch 2 owner owns.

`layoutDirection` is forced to `.leftToRight` in exactly two places — `RootView` (so the consent,
landing and auth doors get the LTR shell too) and `AppShell` (`ARCHITECTURE §2.8`). It is
idempotent and set nowhere else. The `< 320 pt window` rule is implemented purely through
`horizontalSizeClass`; no geometry API is relied on.

`backgroundExtensionEffect()` is called on the split-view detail inside `if #available(iOS 26.0, *)`
(`ARCHITECTURE §3.3`). If the SDK rejects it, deleting the two-line availability branch is the whole
fix. The keyboard layer uses real `Button`s in a `frame(width: 0, height: 0).clipped()` stack rather
than `.hidden()`, which would disarm the shortcuts.

### Sidebar features deliberately not built

Colour tags and the tag filter bar, folders, bulk selection, duplicate/merge, the two saved shelves
(`محفوظاتي` / `قصاصاتي`), the resume strip, and `ابحث في كل المحادثات`. Search is title-only until
three characters, after which `ChatStore.search` also reads already-loaded message bodies —
conversations never opened are not scanned, and the empty state says so. For `ProductKind.studio`
the history list falls back to the `.ai` conversations, because `ChatStore.summaries(for:)` maps
studio onto ai.

### Resources/

`Info.plist` carries 27 top-level keys, including `NSPhotoLibraryAddUsageDescription`,
`NSSpeechRecognitionUsageDescription`, `BGTaskSchedulerPermittedIdentifiers =
[$(PRODUCT_BUNDLE_IDENTIFIER).jobs]` (which is what `BackgroundRefresh.identifier` computes at
runtime) and `UIBackgroundModes = [audio, fetch, processing]`. `processing` is declared because the
plan asks for it, but no code submits a `BGProcessingTaskRequest` — `BackgroundRefresh` submits a
`BGAppRefreshTaskRequest`, which is what `fetch` covers; the declaration is inert rather than wrong.

`UIApplicationSupportsMultipleScenes = true` lets an iPad open a second window. Every store is a
single instance built once in `AppEnvironment`, so two scenes share one store graph and therefore
one `Router` — same selected conversation, same sheets. That is the intended design; independent
windows would be a `Router` change, not a plist change.

---

## Round-2 reconciliation (integrator pass, "Owner report round 2")

Everything below is **frozen too**: it is what actually shipped after the round-2 wave, verified
against the files under `ios/FirasAI`. Where a signature here disagrees with an earlier section,
**this section wins** — the earlier line records what was planned, this one records what compiles.
No entry renames a frozen type or removes a frozen member; every one is either an addition or the
chosen shape of something the earlier text pinned loosely.

### App/ — cases and members added since the freeze

```swift
extension AppSheet { case allChats }                    // Features/Shell/AllChatsView.swift
struct AllChatsView: View { init(env: AppEnvironment) }
extension Router {                                      // every frozen member unchanged
    private(set) var newChatNonce: Int                  // raised by newConversation; ChatScreen.task keys on it
    func switchTo(product newProduct: ProductKind)
}
```

`AppShell.sheetView` presents `.allChats` as `AllChatsView(env:)`. `newChatNonce` exists because
pressing New chat while already on a blank conversation leaves `selectedConversationID` at `nil`,
so a `task(id:)` keyed on the id alone never re-runs.

### Stores/ — `SendPipeline`, `ConversationState`, `StreamBuffer`

```swift
extension SendPipeline {                                // frozen entry points unchanged
    static let paintGrace: TimeInterval                 // 1/60 s
    var turnTasks: [String: Task<Void, Never>]
    func send(text:attachments:in:product:) async       // forwards to deliver(…, mergedFrom: nil)
    func deliver(text: String, attachments: [PreparedAttachment], in id: String,
                 product: ProductKind, mergedFrom: String?) async
    func beginTurn(_ context: ChatTurnContext)          // synchronous; both rows land before it returns
    func runTurn(_ context: ChatTurnContext, assistantID: String) async
    func runStream(_ request: ChatStreamRequest, key: String, assistantID: String, context: ChatTurnContext) async
    func refreshPreservingQuestions(_ key: String) async
    func progress(pointer: JobPointer, snapshot: JobSnapshot)
    func land(pointer: JobPointer, terminal: JobTerminal) async -> Bool
    func complete(key:assistantID:cid:text:reasoning:context:) async
    func failTurn(key:assistantID:action:context:) async
    func settleStopped(key:text:reasoning:assistantID:cid:) async
    func placeAssistantRow(context: ChatTurnContext, tier: ModelTier, lang: AppLanguage) -> String
    func existingAssistantID(context: ChatTurnContext) -> String?
    func upsertAssistant(key:assistantID:cid:tier:lang:_:)
    static func jobRequest(output:context:kind:jobKind:chatID:title:task:lang:) -> ChatJobRequest
    static func jobKind(for:) -> JobKind; static func isPlanning(_:) -> Bool
    static func mediaKind(for:) -> MediaKind?; static func intent(for:) -> String
    static func reattachment(for:state:hasOwnImages:) -> [String]
    static func fold(_:) -> FoldedAttachments
}
extension ConversationState { var longFileProgress: LongFileProgress? }   // observed; cleared by settle/fail
extension StreamBuffer { var hasText: Bool { get } }                      // O(1) form of !text.isEmpty
```

There is no `startTurn(_:)` — `beginTurn` (rows, synchronous) plus `runTurn` (network, its own
task) replace it, and `turnTasks` is how `stop(in:)` reaches a turn that has neither a job pointer
nor a stream task yet. `MessageSerializer.merge` keys rows by **role and cid** through a private
`turnKey(_:)`; a merge keyed on the cid alone writes the answer into the question's bubble, so that
helper is load-bearing and must survive any future rewrite of `Prompting/MessageSerializer.swift`.

`ChatScreen.retryLastTurn()` retries the turn that failed: it looks for an assistant row **after**
the last question and regenerates that; when there is none (an empty placeholder is removed by
`failTurn`) it removes the question row and re-sends its text. It must never regenerate
`messages.last(where: { $0.role == .assistant })`, which is the previous turn's answer.

### Prompting/ — classifier, plan cycle, ask spec

```swift
extension RequestClassifier {                           // the frozen four are unchanged
    static func namesDocumentExplicitly(_ text: String) -> Bool
    static func documentFormat(for message: ChatMessage) -> String?
    static func documentFormat(forAssistantAt index: Int, in messages: [ChatMessage]) -> String?
    static func outputFormatTarget(_ s: String) -> String?
    static func longDocSections(_ text: String) -> Int
}
```

`RequestKind.file(format:)` may carry **`txt`** as well as `pdf|docx|pptx|xlsx|csv`; the case, its
labels and its associated types are unchanged. `RequestClassifier.documentFormats` is the set of
six. `SendPipeline.intent(for:)` still stores the coarse `"file"` label on the user row, so
`documentFormat(for:)` re-runs the patterns rather than trusting it.

```swift
extension PlanCycle {                                   // every frozen member unchanged
    var pausedPhase: PlanPhase?                         // Codable; set by pauseForCall
    var isArmed: Bool { get }                           // cycle started, first reply not landed
}
extension AskSpec { static func hasAskFence(_ markdown: String) -> Bool }   // opening fence, closed or not
```

`AskSpec.Option` keeps exactly `id` and `label`; the web's per-option `desc` is parsed and dropped.

### Rendering/ — math

```swift
enum MathScanner {                                      // protect/restore unchanged
    struct Span: Hashable, Sendable { let raw, tex: String; let isDisplay: Bool; var id: String { get } }
    static func token(_ index: Int) -> String
    static func spans(in text: String) -> [Span]
    static func span(for raw: String) -> Span?
    static func span(tex: String, isDisplay: Bool) -> Span?
    static func isTypesettable(_ tex: String) -> Bool
    static func identifier(tex: String, isDisplay: Bool) -> String
}
enum MathText { static func unicode(_ tex: String) -> String; static func stripDelimiters(_ raw: String) -> String }

@MainActor @Observable final class MathIsland {         // Rendering/MathIsland.swift (+Assets, +Glyphs)
    static let shared: MathIsland
    func glyph(for id: String, style: MathIslandStyle) -> MathGlyph?
    func request(_ items: [MathIslandItem], style: MathIslandStyle)
    func prime(markdown: String, messageID: String, style: MathIslandStyle)
    func allowRetry(); func reset()
}
struct MathIslandItem: Hashable, Sendable { init(tex: String, isDisplay: Bool); init(span: MathScanner.Span) }
struct MathIslandStyle: Hashable, Sendable {
    init(textHex:backgroundHex:errorHex:fontSize:); init(palette: FirasPalette, background: Color, fontScale: FontScale)
    var key: String { get }
}
struct MathGlyph { let image: UIImage; let size: CGSize; let baseline: CGFloat }

struct MathBlockView: View {
    init(tex: String, display: Bool, messageID: String, palette: FirasPalette, lang: AppLanguage,
         fontScale: FontScale = .medium, background: Color? = nil, motionOn: Bool = true)
    @MainActor static func prime(markdown: String, messageID: String, palette: FirasPalette,
                                 background: Color? = nil, fontScale: FontScale = .medium)
    @MainActor static func invalidate(messageID: String)      // clears the failure state ONLY; keeps bitmaps
    @MainActor static func invalidateAll()
}
extension Strings { enum Math }                          // MathBlockView.swift
```

The old per-message island (`MathIsland.island(for:)`, `invalidate(messageID:)`, `invalidateAll()`,
`island.glyph(for:)`, `island.prime(markdown:style:)`) no longer exists. Glyphs are keyed by the
expression and the style, never by the message, which is why `invalidate(messageID:)` deliberately
throws nothing away.

### Rendering/Cards — the landed initialisers

```swift
struct FileCard: View {
    enum Stage: String, Sendable, Equatable, CaseIterable { case creating, extract, plan, content, validate, assemble }
    init(meta: FileMeta, palette: FirasPalette, lang: AppLanguage, stage: Stage? = nil,
         progress: LongFileProgress? = nil, sizeBytes: Int? = nil, errorText: String? = nil,
         isCancelling: Bool = false, isPreparing: Bool = false, motionOn: Bool = true,
         onOpen: (() -> Void)? = nil, onShare: (() -> Void)? = nil,
         onSaveToFiles: (() -> Void)? = nil, onStop: (() -> Void)? = nil)
}
struct ImageCard: View {
    enum Phase: Sendable, Equatable { case auto, rendering, ready, failed(code: String) }
    init(meta: MediaMeta, palette: FirasPalette, lang: AppLanguage, phase: Phase = .auto,
         motionOn: Bool = true, startedAt: Date? = nil, showsPrompt: Bool = true,
         resolveImage: ((MediaMeta) async -> URL?)? = nil, resolveShareFile: ((MediaMeta) async -> URL?)? = nil,
         onOpen: (() -> Void)? = nil, onSave: (() -> Void)? = nil, onShare: (() -> Void)? = nil,
         onEdit: (() -> Void)? = nil, onRetry: (() -> Void)? = nil, onRegenerate: (() -> Void)? = nil)
}
struct VideoCard: View {
    enum Phase: Sendable, Equatable { case auto, rendering, ready, failed(code: String) }
    init(meta: MediaMeta, palette: FirasPalette, lang: AppLanguage, phase: Phase = .auto,
         motionOn: Bool = true, startedAt: Date? = nil,
         resolveFile: ((MediaMeta) async -> URL?)? = nil, resolveShareFile: ((MediaMeta) async -> URL?)? = nil,
         onSave: (() -> Void)? = nil, onShare: (() -> Void)? = nil, onRegenerate: (() -> Void)? = nil)
}
struct SongCard: View {
    enum Phase: Sendable, Equatable { case auto, pending, rendering, ready, failed(code: String) }
    struct Playback: Sendable, Equatable { init(isPlaying: Bool = false, isLoading: Bool = false, elapsed: Double = 0, duration: Double = 0) }
    init(meta: MediaMeta, palette: FirasPalette, lang: AppLanguage, phase: Phase = .auto,
         motionOn: Bool = true, startedAt: Date? = nil, playback: Playback = Playback(),
         resolveShareFile: ((MediaMeta) async -> URL?)? = nil, onPlayPause: (() -> Void)? = nil,
         onSeek: ((Double) -> Void)? = nil, onDownload: (() -> Void)? = nil,
         onGenerate: (() -> Void)? = nil, onRegenerate: (() -> Void)? = nil)
    var renderCeiling: TimeInterval { get }                  // instance property, not a static let
    static func seconds(from: Date, to: Date) -> Int         // non-optional `to`
}
struct MediaCoverPlate: View { }                             // Rendering/Cards/ImageCard+Cover.swift
```

`FileCard` has **no** `onExport:`; the split is `onShare:` / `onSaveToFiles:`, and the default phase
of the three media cards is `.auto` (decide from the fence), not `.ready`.
`Features/Chat/AssistantTurnView+Fences.swift` is the one host of all four and calls exactly these
spellings.

### Media, sharing and export

```swift
enum MediaAssetError: Error, Sendable, Equatable { }             // Features/Media/MediaAssetRepository.swift
// MediaAssetRepository.store(temp:key:ext:) async throws -> String now throws these; signature unchanged.
struct FirasActivitySheet: UIViewControllerRepresentable { init(url: URL, title: String? = nil); init(text: String) }
final class FirasShareItem: NSObject, UIActivityItemSource { }   // ExportController+Sharing.swift
```

### Features/Shell/

```swift
@MainActor @Observable final class DrawerMotion {        // declared in CompactDrawer.swift
    static let shared: DrawerMotion
    var openness: CGFloat                                // 0 closed … 1 open; written by the drag
    var panelWidth: CGFloat
    var progress: CGFloat { get }; var panelOffset: CGFloat { get }
    var contentPush: CGFloat { get }; var isEngaged: Bool { get }
}
```

`CompactDrawer.init(env:isOpen:)` and `panelWidth(for:)` are byte-identical to their frozen forms
(round 3 changed only the *number* `panelWidth(for:)` returns — see the round-3 section);
`DrawerPushLayer<Content>` is file-scope `private` inside `AppShell.swift` and is not a target-wide
symbol. **The rule for every caller: raise `router.drawerOpen`, never wrap it in `withAnimation`** —
the drawer animates itself from `.onChange(of: isOpen)`, and a second transaction fights it.

`SidebarAccountPill` is circle + name + a New chat circle. It offers **no sign out**: members reach
it through `AccountSettingsView.signOutButton`, guests through a long-press context menu
(`Strings.Shell.guestExit` / `guestExitConfirm`). `Strings.Shell.logout` is now unreferenced and is
kept only so nothing that reads it later has to re-add it. The sidebar has exactly **one**
new-conversation control — this pill's circle; `SidebarView.newConversationPill` and its
`.overlay(alignment: .bottom)` were deleted in this pass because the two sat 60 pt apart.

### Features/Code/

```swift
enum CodeSessionFilter: String, CaseIterable, Identifiable, Sendable { case all, working, fresh }
enum CodeWorkspaceSurface: String, Sendable { case session, workspace }
enum CodeWorkspaceTab: String, CaseIterable, Identifiable, Sendable { case files, code, preview, console }
enum CodeWorkspaceRightPane: String, CaseIterable, Identifiable, Sendable { case preview, console, assistant }
struct CodeWorkspaceShareItem: Identifiable, Equatable { init(url: URL) }
struct CodeWorkspaceShareSheet: UIViewControllerRepresentable { let url: URL }
struct CodeSessionThread: View { init(env: AppEnvironment) }                       // CodeWorkspacePanes.swift
struct CodeSessionComposer: View {                                                 // CodeSessionComposer.swift
    init(env: AppEnvironment, prefill: Binding<String>, onPlan: @escaping (CodeEditPlan) -> Void,
         onOpenRepository: @escaping () -> Void)
}
@MainActor @Observable final class CodeGitHubModel {                               // CodeGitHubModel.swift
    static let shared: CodeGitHubModel
    init(defaults: UserDefaults = .standard)
    private(set) var status: CodeGitHubStatus?; private(set) var repos: [CodeGitHubRepo]
    private(set) var branches: [String]; private(set) var branchesRepo: String
    private(set) var isLoadingStatus, isLoadingRepos, isLoadingBranches, isStarting, hasLoadedStatus: Bool
    private(set) var failure: LText?; private(set) var links: [String: CodeGitHubLink]
    var isConfigured: Bool { get }; var isConnected: Bool { get }; var login: String { get }
    var shouldOfferConnect: Bool { get }
    func link(for projectID: String) -> CodeGitHubLink?
    func setLink(_ link: CodeGitHubLink?, for projectID: String); func clearFailure()
    func refreshStatus(api: APIClient, force: Bool = false) async
    func loadRepos(api: APIClient, force: Bool = false) async
    func loadBranches(api: APIClient, repo: String) async
    func connect(api: APIClient) async -> Bool; func disconnect(api: APIClient) async
}
struct CodeGitHubStatus: Decodable, Sendable, Equatable { let configured, connected: Bool; let login, avatar, scope: String }
struct CodeGitHubRepo: Decodable, Sendable, Equatable, Hashable, Identifiable { let fullName, name, owner: String; let isPrivate: Bool; let defaultBranch, summary: String; let pushedAt: Double }
struct CodeGitHubLink: Codable, Sendable, Equatable, Hashable { var repo, branch: String; var label: String { get } }
struct CodeGitHubPickerSheet: View { init(env: AppEnvironment, projectID: String) }
```

`CodeWorkspaceTab` has **no** `.assistant` case (the session surface is the assistant);
`CodeWorkspaceRightPane.assistant` still uses `Strings.Code.tabAssistant`. The four frozen pane
names (`CodeWorkspacePreview` / `Console` / `Assistant` / `DiffReview`) are unchanged.
`CodeLauncherView` no longer renders the create card — a new session opens empty and asks inside
itself. `CodeStore.buildFileCount` is a non-optional `Int` (the earlier section's `Int?` was never
built). GitHub OAuth opens Safari via `UIApplication.open`, with `refreshStatus(api:force:)` on the
next foreground as the completion signal; nothing commits yet.

### Notifications and Voice

```swift
extension NotificationManager {                          // every frozen member unchanged
    var isAuthorized: Bool { get }
    @discardableResult func requestIfNeeded() async -> Bool     // notDetermined now shows the explainer
    @discardableResult func askSystem() async -> Bool           // the raw system prompt
    func clearAllDelivered()
}
struct SpokenLanguage: Identifiable, Hashable, Sendable {        // Features/Voice/DialectPickerSheet.swift
    let id, arabicName, englishName: String; let nativeName, flag: String?
    let dialect: DictationDialect?; let searchIndex: String
    func name(_ lang: AppLanguage) -> String; func matches(_ needle: String) -> Bool
}
enum SpokenLanguageCatalog {                                    // same file
    static var suggested: [SpokenLanguage] { get }
    static func world(for lang: AppLanguage) -> [SpokenLanguage]
    @MainActor static func selected(prefs: PreferencesStore) -> String
    @MainActor static func select(_ language: SpokenLanguage, prefs: PreferencesStore)
}
```

A world language with no `DictationDialect` case is remembered under the UserDefaults key
`dictationLanguageWorld` while `prefs.dictationDialect == .auto`; the online transcriber
auto-detects, and only the offline `SFSpeechRecognizer` fallback is wrong for it.

### Localization namespaces extended

`Strings.Code` (launcher/session/GitHub), `Strings.CodeUI` (session composer and thread),
`Strings.Settings.Voice` (language picker) and `Strings.Settings.Notifications` (quiet hours,
previews, "not now") all gained keys this wave. Every `Strings.<NS>.<key>` reference in the target
resolves, and no key is declared twice inside one namespace.

### Known cross-owner items this pass did NOT change

1. `SendPipeline.deliver` still hands an `.image` / `.video` / `.music` classification to
   `onMediaRequest`, and `jobKind(for:)` still maps `.longdoc` / `.longfile` to their own workers,
   **on a plan-mode clarify turn as well**. `web-plan-mode.md §7.4` puts deliverable routing on the
   `.execute` turn only, so a plan-mode request for a picture or a long document is answered
   directly and still stamped `mode:"plan"` — which is the Start pill appearing under a finished
   answer. The fix is to force `JobKind.chat` and skip the media hand-off while `planTurn` is
   `.clarifyOrPlan` / `.revision` / `.forcedPlan`, and to resolve the real kind from `originID` on
   `.execute`; it needs a prompt-side change as well (`PromptBuilder.planAddendum` already reads
   `input.askRounds`) and is too large for an integration pass.
2. `ChatStore.ensureState` re-derives `state.plan` whenever `phase == .none`, which discards a live
   `originID` for an armed cycle. The one-line guard is
   `if case .none = state.plan.phase, !state.plan.isArmed { … }` in `ChatStore+Persistence.swift`.
3. `MediaStore.localURL(for:)` returns `nil` for a second concurrent request for the same creation
   (`guard !isDownloading(creation.id)`); the card now shows a retryable download plate instead of a
   generation error, but coalescing in-flight downloads is still owed.
4. `VoiceSettingsView` still renders its own 14-row `DictationDialect` menu instead of presenting
   `AppSheet.dialectPicker`, so two different language lists exist in Settings.
5. `MarkdownBlocks.split` / `MarkdownBlocks+Lines.displayMathOpens` is a second display-math scanner
   beside `MathScanner`; a line like a closed `$$` with prose after it on the same line is swallowed
   whole and falls back to `.raw`.
6. `AssistantTurnView.askSpec` gates on the literal `"firas-ask"`; `AskSpec.hasAskFence(_:)` would
   make a `firas_ask` / `~~~firas-ask` emission reach the panel on the first render.

---

## Round-3 reconciliation (integrator pass, "Owner report round 3")

Everything below is **frozen too**, and it is the newest layer: where it disagrees with the
round-2 section or with any earlier one, **this section wins**. It records what actually shipped
after the round-3 wave, verified file by file against `ios/FirasAI`. No frozen signature was
renamed or removed; every entry is either an addition, a new type, or the chosen value behind a
signature that itself did not move.

### Features/Shell/ — the drawer, the sidebar and the all-chats page

```swift
extension CompactDrawer {                                // signature unchanged
    static func panelWidth(for containerWidth: CGFloat) -> CGFloat   // min(316, max(268, w − 92))
}
extension SidebarHistoryList {                           // init gained a third, defaulted parameter
    init(env: AppEnvironment, query: String, limit: Int? = 10)
    enum RowStyle: Hashable, Sendable { case compact, card }
    struct Bucket: Identifiable { let id: String; let title: LText; let rows: [ChatSummary] }
    @MainActor struct Row: View { init(env: AppEnvironment, summary: ChatSummary, style: RowStyle) }
    @MainActor struct Placeholder: View { init(env: AppEnvironment, query: String, pinnedOnly: Bool) }
    static func summaries(env: AppEnvironment, query: String) -> [ChatSummary]
    static func buckets(of all: [ChatSummary]) -> [Bucket]
    static func timestamp(from raw: String?) -> Date?
    @ViewBuilder static func pinButton(env: AppEnvironment, summary: ChatSummary) -> some View
    @ViewBuilder static func deleteButton(env: AppEnvironment, summary: ChatSummary) -> some View
    static func relativeTime(from raw: String?, lang: AppLanguage) -> String
    static func absoluteDate(_ date: Date, lang: AppLanguage) -> String
}
extension AllChatsView {                                 // init(env:) unchanged
    enum Filter: String, CaseIterable, Identifiable, Hashable { case all, pinned; var title: LText { get } }
}
```

`SidebarHistoryList`'s `limit`, the nested types and the seven statics are **internal, not
`private`**: `Row`, `Placeholder` and the relative-time helpers live in
`Features/Shell/SidebarHistoryList+Row.swift`, and a cross-file extension cannot see `private`.
The frozen `SidebarHistoryList(env:query:)` call in `SidebarView.swift` still resolves unchanged,
and `AppShell.sheetView` still presents `.allChats` as `AllChatsView(env:)`.

`panelWidth(for:)` keeps its frozen signature and returns a smaller number at the owner's
direction («عرض السايد بار صغره شوي نفس كلود»): 298 pt on a 390 pt phone where it used to be 346.
Nothing else reads the function — `AppShell` derives its push from `DrawerMotion.panelWidth` — so
the narrower panel is consistent on every surface.

**The compact drawer's opening gesture is no longer a SwiftUI `DragGesture`.**
`plan/Features-Shell.md` describes a 20 pt edge strip with a `@GestureState` offset; that strip was
a top-most transparent view over the leading edge, so it ate every ordinary tap in that band (the
toolbar's own drawer button among them). It is now a window-level
`UIScreenEdgePanGestureRecognizer` installed by two file-scope `private` types inside
`CompactDrawer.swift` — `DrawerEdgeSwipe: UIViewRepresentable` and `EdgeSwipeHostView: UIView`,
neither of which is a target-wide symbol, the same rule already recorded for `DrawerPushLayer`.
`cancelsTouchesInView = false` keeps taps flowing; the recognizer requires failure of any other
`UIScreenEdgePanGestureRecognizer`, so a `NavigationStack` that can pop keeps the back-swipe. It is
disabled while `router.sheet` or `router.cover` is non-nil. The momentum projection rule,
`FirasMotion.drawerFlick` on release, `FirasMotion.sheet` for programmatic travel, the 30 % scrim,
`.isModal` and `Haptics.select()` on the snap are all unchanged.

`SidebarView`'s header no longer renders `FirasBrandMark` — the wordmark alone, larger, drawn
inline. `FirasBrandMark` itself is untouched and still used by `WelcomeView`, the intro and the
consent door. The sidebar still has exactly one new-conversation control (the circle in
`SidebarAccountPill`); the floating pill deleted in round 2 was **not** re-added.

`WelcomeView` (signature unchanged) centres its block with `containerRelativeFrame(_:alignment:_:)`
— an iOS 17 API, but the only use of it in this target. If CI rejects it, deleting that one
modifier is the whole fallback. Its `− 120` assumes `ChatScreen` keeps `.padding(.top, 60)` around
`WelcomeView`.

`Strings.Shell` gained the all-chats page's copy — `filterMenu`, `pinnedEmptyTitle`,
`pinnedEmptySubtitle`, `justNow`, `relativeYesterday` and the six-form `minutesAgo*` / `hoursAgo*` /
`daysAgo*` families read by `ArabicPlurals.count`. Round 3 declared them as an
`extension Strings.Shell` at the bottom of `SidebarHistoryList+Row.swift`; **this pass folded them
into `Localization/Strings+Shell.swift`**, so the namespace lives in one file again and a later
batch cannot collide with it.

### The temporary ("incognito") conversation

```swift
extension ChatConversation {                             // Models/ChatModels.swift
    var ephemeral: Bool                                  // client-only; defaults false
    init(…, planSnapshotMode: ResponseMode? = nil, ephemeral: Bool = false)   // trailing, defaulted
}
extension ChatStore { func discardTemporary(_ id: String) async }             // Stores/ChatStore.swift
struct ChatTopBarMenu: View {                                                 // Features/Chat/ChatTopBarMenu.swift
    init(env: AppEnvironment, conversationID: String, product: ProductKind,
         isExporting: Bool, onExport: @escaping (ExportController.Format) -> Void,
         onEndTemporary: @escaping () -> Void)
}
extension Strings.Chat {                                                      // Localization/Strings+Chat.swift
    static let temporaryTitle, temporaryStart, temporaryEnd, temporaryNote, temporaryStarted,
               temporaryAsk, temporaryEnded, conversationActions, exportAs, exportWorking: LText
}
```

`ephemeral` is deliberately absent from `ChatConversation.encode(to:)` and `init(from:)`: a mode
whose whole claim is that nothing survives the session cannot be the one thing that survives it.
All three existing `ChatConversation(…)` call sites use argument labels, so the added trailing
parameter is source-compatible.

`discardTemporary(_:)` is the door `delete(_:)` could not be: no seven-second undo, no deferred
`DELETE`, no toast — because a mode that promises nothing is recoverable cannot end with a button
that recovers it. Six independent refusals make "never written" true rather than remembered:
`persist`, `persistLocalOnly`, `ensureServerChat`, `autoTitleIfNeeded`, `rebuildSummaries`
(`ChatStore+Persistence.swift`, `ChatStore.swift:233`) and the durable-job guard in
`SendPipeline+Turn.swift` (`let isTemporary = store.conversation(key)?.ephemeral ?? false`, folded
into `canQueue`), plus the long-term-memory guard in `SendPipeline+Landing.swift`. **That one line
in `+Turn.swift` is the only thing keeping a guest's temporary chat out of server storage, and its
absence is invisible** — everything still works, it just quietly saves. Verified present in this
pass after the file was rewritten concurrently during round 3.

`ChatScreen` no longer declares a second `.topBarTrailing` `ToolbarItem` for export: open item 6/8
pinned that corner at two controls, so export is a submenu inside `ChatTopBarMenu`. Before the
first message the corner shows one control (the temporary switch, on `.ai` only); after it, New
chat plus the menu. Leaving a temporary chat by tapping another conversation in the drawer discards
it **without** the confirmation — a view cannot veto a navigation the router has already performed
— but the «انتهت المحادثة المؤقتة» toast still fires, so it is never silent.

`ChatScreen.swift` is 570 lines, over the ~450 guide. It arrived at ~470; splitting it would mean
de-privatising six members (`env`, `product`, `activeID`, `conversation` and two `@State` flags)
across a file boundary. Every view body in it is well under 80 lines, which is the type-checker
risk the rule guards.

### Privacy and consent

```swift
struct PrivacySettingsView: View { init(env: AppEnvironment) }                 // Features/Settings/PrivacySettingsView.swift
enum TrainingConsent: String, Sendable, Hashable, CaseIterable {               // same file
    case accepted, declined
    static var recorded: TrainingConsent? { get }        // nil = never asked on this device
    static var effective: TrainingConsent { get }        // recorded ?? .declined
    static var isAllowed: Bool { get }
    static func record(_ choice: TrainingConsent)
}
extension Strings.Settings {
    static let tabPrivacy, tabPrivacySub: LText
    enum Privacy { }                                     // trainingHeader … consentPending
}
```

`SettingsView.init(env:section:)` and `SettingsSection` (still five cases, per line 32 and the note
above) are both unchanged. Internally `SettingsView` now navigates by a **private, file-local**
`enum Page { case section(SettingsSection), privacy }` — a typed path, an iPad selection binding and
`navigationDestination(for: Page.self)`. Privacy is a pushed page like `NotificationSettingsView` /
`MemorySettingsView`, not a route: nothing deep-links to it.

`ConsentView.init(prefs:onContinue:)` is unchanged, but Continue is gated on
`agreed && training != nil` rather than `agreed` alone — the training question must be *asked*, not
assumed. Either answer opens the door; only silence blocks it. Its scroll bottom padding went
240 → 280 to clear the taller gate.

`TrainingConsent` sits **outside** `PreferencesStore` on purpose (UserDefaults key
`trainingConsent`), so `resetToDefaults()` cannot flip a "no" back to a "yes". If it is ever moved
inside, it must be excluded from `Keys.resettable` and from `resetToDefaults()`, exactly as
`consentAccepted` and `guestActive` already are. Existing installs that passed the consent door
before the question existed have `recorded == nil`, and `effective` reads that as `.declined` —
never asked is never agreed. Nobody is opted in without answering.

**THE SERVER HAS NO ROUTE.** All 69 `"/api/…"` literals in `server.mjs` were grepped, plus
`preferences`, `consent`, `trainingConsent`, `dataConsent`, `improveModel`: there is no preferences
or consent endpoint, and none was invented. The choice is therefore device-local and the UI copy
promises nothing more. **The server needs** something like
`PUT /api/auth/preferences {trainingConsent: "accepted"|"declined"}` with `GET /api/auth/me`
echoing it back, so the answer follows the account and the training pipeline can honour it.
`TrainingConsent.record(_:)` is the single place to add that call; `SessionStore` is the place to
seed the local record from `/api/auth/me`. Until then a member who accepts on iPhone and declines
on iPad leaves two different records. Nothing yet reads `TrainingConsent.isAllowed`; it exists so
that when a wire field appears there is one honest source to read.

### Voice — dictation quality

```swift
extension DictationController {                          // every frozen member unchanged
    private(set) var isPolishing: Bool                   // true while the repair turn is reading back
    func statusLine(_ lang: AppLanguage) -> String?      // the one line that belongs on screen
    nonisolated static let polishSeconds: Double         // 4
    nonisolated static let polishCharacterLimit: Int     // 1_200
    nonisolated static func isWorthRepairing(_ text: String) -> Bool
    nonisolated static func polished(_ raw: String, api: APIClient, dialect: DictationDialect) async -> String
    nonisolated static func polishSystem(dialect: DictationDialect) -> String
    nonisolated static func polishHint(for dialect: DictationDialect) -> String
    nonisolated static func accepted(_ candidate: String, raw: String) -> String
    nonisolated static func keepsTheWords(_ candidate: String, raw: String) -> Bool
    nonisolated static func words(_ text: String) -> [String]
    nonisolated static func arabicShare(_ text: String) -> Double
    nonisolated static func stripLabel(_ text: String) -> String
    nonisolated static func stripWrappingQuotes(_ text: String) -> String
    nonisolated static func polishDelta(_ payload: String) -> String?
}
extension DictationRecorder {                            // every frozen member unchanged
    static func conditioned(_ pcm: Data) -> Data         // 70 Hz high-pass + gentle peak normalisation
    static func gainForPeak(_ peak: Float) -> Float
    static let highPassCoefficient: Float                // 0.9725
}
extension Strings.Voice { static let micPolishing: LText }
```

`DictationController.State` gained no case; `start` / `finish` / `cancel` /
`applicationDidEnterBackground` / `onTranscript` / `appending` and the recorder's `init` / `start` /
`stop` / `cancel` / `duration` are all unchanged.

**One file beyond the three the plan named:** `Features/Voice/DictationController+Polish.swift`.
`DictationController.swift` was already 834 lines, so the pass went into the sanctioned
`<PrimaryType>+<Aspect>.swift` split inside its own folder; the new file holds only
`nonisolated static` members and reads no `private` state from the main file.
`DictationController.swift` is now 925 lines — `LiveSpeechRun` + `SpeechResultBox` at the bottom
are the natural next `+Live` split.

The repair spends one cheap `nomem` `mini` turn per dictation (the same budget `AutoTitle` already
spends), skips outright past 1 200 characters, and keeps the raw transcript on every failure. The
peak normalisation is a global gain over the whole take, so one loud cough suppresses the lift for
the quiet speech around it; a windowed/RMS gain inside `DictationRecorder.conditioned` is the next
step if takes still come back thin. `Features/Chat/DictationBar.swift` — not owned by this batch —
still hard-codes `Strings.Composer.micTranscribing` for the whole `.transcribing` state, so
`micPolishing` is published but never seen. **One line in that file closes it:**
`Text(dictation.statusLine(lang) ?? "")` in `transcribingBody`.

### Local first, server on leaving

```swift
extension JobManager {                                   // every frozen member unchanged
    func pointer(forCID cid: String, owner: String) -> JobPointer?
}
extension SendPipeline {                                 // every frozen member unchanged
    var handoffs: [String: ChatHandoff]
    var handingOff: Set<String>
    var readerIsPresent: Bool { get }                    // UIApplication.shared.applicationState != .background
    func handOffLiveTurns()
}
struct ChatHandoff: Sendable {                           // file-scope in Stores/SendPipeline.swift
    let request: ChatJobRequest
    let draft: JobPointer
    let assistantID: String
    let context: ChatTurnContext
}
```

`ChatTurnContext` and `FoldedAttachments` keep their exact shape.

**`runTurn` now ends in a stream for `kind == .chat` whenever the app is in the foreground, and in
a job otherwise.** `ARCHITECTURE.md §2.10`'s "a job for every persisted turn … unless images or
more than 550 000 chars" is **superseded for the chat kind** by the round-3 owner directive;
`longdoc`, `longfile`, `agentrun`, `codebuild` and `brainask` are untouched and still go straight to
the queue. The handoff is packed at the moment the stream starts and never rebuilt, so leaving
costs one POST of a body already in memory. `JobManager.startChatQueueJob` consults
`pointer(forCID:owner:)` first, which is how "never start a second job for a turn the server
already has under the same `cid`" is enforced before the request goes out.

Two mechanisms react to leaving: `AppLifecycle`'s scenePhase path
(`jobs.applicationDidEnterBackground`) and `SendPipeline`'s own
`UIApplication.didEnterBackgroundNotification` observer, registered once from `init`. They are
independent and idempotent; if `AppLifecycle` ever grows a chat hook, `handOffLiveTurns()` should
move there and the observer should go.

`refreshOnce` now publishes `didProgress` as well as terminals, which is what makes coming back
instant — but it also means the BG-refresh path writes into stores while the app is away. Harmless
for every current observer; worth knowing if one ever starts animating from `didProgress`.

`SendPipeline.dropDuplicateQuestion` removes `MediaStore`'s copy of the question *after* the fact
(matched by role + exact text + position after ours) because `Stores/MediaStore+Creating.swift`
appends its user turn only after `refreshQuota()` and the prompt rewrite. The clean fix is for
whoever owns `MediaStore` to accept an already-placed question id — and then this helper is deleted.

### Brain and Code — overflow

`SourceChipsRow` now owns a 10 pt horizontal inset so its scroll viewport sits inside the composer's
24 pt corner arc. The underlying hazard remains for any **future** child at the edge of a
`.firasGlass` box: `FirasGlassModifier` paints with `.background`/`.overlay` and never clips. The
permanent fix is one `.clipShape(shape)` inside `FirasGlassModifier`, or `.padding(8)` on
`BrainComposer`'s `VStack` — both in files this batch does not own.

`CitationChip` is now `.fixedSize()` end to end so a long Arabic title beside it can never squeeze
the digit out of its capsule. It cannot follow `prefs.fontScale` — its frozen init takes only
`palette` — so it stays at 12 pt while the source text beside it scales. `BrainAnswerView.decorate`
still emits inline `[Sn]` markers as markdown links (`[ 3 ](firas-cite://3)`) rather than the
capsules `design-brief.md §7.10` asks for; that is a pre-existing gap, not an overflow defect.
`BrainAnswerView`'s copy bar uses `ViewThatFits(in: .horizontal)`; its fallback stacks the two
capsules, which makes the answer 38 pt taller at the largest font sizes. The Code session composer
no longer has a horizontally scrolling context row, so a third context pill must go through
`ViewThatFits` or a scroll view rather than into the fixed control row.

### Files over the ~450-line guide after this wave

`ChatScreen.swift` 570, `DictationController.swift` 925, `JobManager.swift` 707,
`SendPipeline.swift` 498, `CompactDrawer.swift` 455. Each was left whole because the only available
split would have widened the compile surface (de-privatising members, or a file outside the owner's
assignment) for no type-checker benefit.

### Known cross-owner items round 3 did NOT change

The six items listed at the end of the round-2 section all still stand. Round 3 adds three:

7. `Features/Chat/DictationBar.swift` narrates the whole `.transcribing` state with
   `Strings.Composer.micTranscribing`, so `DictationController.isPolishing` / `statusLine(_:)` are
   published and unread.
8. No server route carries `TrainingConsent`; the switch expresses an intention the backend cannot
   yet honour. That is a backend gap, not a UI one.
9. A hard crash (not a background transition) while a chat turn is streaming loses that turn, where
   the always-queue design would have had the worker file the assistant turn regardless. Closing it
   needs a `chat-turns.json` ticket written in `runTurn` and replayed by a `resumeLiveTurns()`.
