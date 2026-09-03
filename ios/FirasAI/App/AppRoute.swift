import Foundation
import Observation

// MARK: - Destinations

/// A place in the app that something outside the app (a notification tap, an e-mail link, a shared
/// link) can point at. Routes are data only: `Router` decides what they do to the UI.
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

enum SettingsSection: String, CaseIterable, Sendable {
    case account, appearance, chat, voice, data
}

enum AuthMode: String, Sendable {
    case login, signup
}

// MARK: - Presentation

enum AppSheet: Identifiable, Equatable {
    case settings(SettingsSection)
    case tierPicker
    case addContext
    case announcements
    case share(conversationID: String, messageCID: String?)
    case signUpPrompt(FeatureKey)
    case dialectPicker
    case memory
    case longFile(jobID: String)
    case codeViewer(messageID: String)
    case notificationExplainer
    /// The full conversation list, opened from the sidebar's «كل المحادثات» row.
    case allChats

    var id: String {
        switch self {
        case .settings(let section):
            return "settings:" + section.rawValue
        case .tierPicker:
            return "tierPicker"
        case .addContext:
            return "addContext"
        case .announcements:
            return "announcements"
        case .share(let conversationID, let messageCID):
            return "share:" + conversationID + ":" + (messageCID ?? "")
        case .signUpPrompt(let feature):
            return "signUpPrompt:" + feature.rawValue
        case .dialectPicker:
            return "dialectPicker"
        case .memory:
            return "memory"
        case .longFile(let jobID):
            return "longFile:" + jobID
        case .codeViewer(let messageID):
            return "codeViewer:" + messageID
        case .notificationExplainer:
            return "notificationExplainer"
        case .allChats:
            return "allChats"
        }
    }
}

enum AppCover: Identifiable, Equatable {
    case auth(AuthMode)
    case call
    case mediaViewer(creationID: String)
    case artifact(url: String)

    var id: String {
        switch self {
        case .auth(let mode):
            return "auth:" + mode.rawValue
        case .call:
            return "call"
        case .mediaViewer(let creationID):
            return "mediaViewer:" + creationID
        case .artifact(let url):
            return "artifact:" + url
        }
    }
}

// MARK: - Router

/// The single navigation source of truth. Screens never present sheets themselves — they write here.
@MainActor
@Observable
final class Router {
    var product: ProductKind = .ai
    var selectedConversationID: String?
    var sheet: AppSheet?
    var cover: AppCover?
    /// Written by notification taps and `onOpenURL`; `AppShell` consumes it once and sets it to nil.
    var pendingRoute: AppRoute?
    var drawerOpen: Bool = false

    /* "New chat" used to be expressed only as `selectedConversationID = nil`, which says nothing at
       all when the reader is ALREADY on a fresh unsent conversation — the value does not change, so
       nothing observes it and the button was dead exactly when someone pressed it twice. This
       counter is the event that the assignment could not carry: it changes every time, so the chat
       screen can tell "still the same blank page" from "give me another one". */
    private(set) var newChatNonce: Int = 0

    /// Remembers the last selection per product so switching back does not lose the reader's place.
    private var selectionByProduct: [ProductKind: String] = [:]

    init() {}

    // MARK: Selection

    func open(_ route: AppRoute) {
        switch route {
        case .chat(let conversationID):
            select(conversationID: conversationID, product: .ai)
        case .agent(let conversationID):
            if let conversationID {
                select(conversationID: conversationID, product: .agent)
            } else {
                newConversation(in: .agent)
            }
        case .code(let projectID):
            if let projectID {
                select(conversationID: projectID, product: .code)
            } else {
                newConversation(in: .code)
            }
        case .brain:
            switchTo(product: .brain)
        case .studio(let creationID):
            switchTo(product: .studio)
            if let creationID {
                cover = .mediaViewer(creationID: creationID)
            }
        case .settings(let section):
            sheet = .settings(section)
        case .auth(let mode):
            cover = .auth(mode)
        case .sharedChat(let id):
            sheet = .share(conversationID: id, messageCID: nil)
        case .verify:
            cover = .auth(.signup)
        case .reset:
            cover = .auth(.login)
        }
    }

    func newConversation(in product: ProductKind) {
        switchTo(product: product)
        selectedConversationID = nil
        selectionByProduct[product] = nil
        sheet = nil
        drawerOpen = false
        newChatNonce &+= 1
    }

    func select(conversationID: String, product: ProductKind) {
        switchTo(product: product)
        selectedConversationID = conversationID
        selectionByProduct[product] = conversationID
        sheet = nil
        cover = nil
        drawerOpen = false
    }

    func showSignUp(feature: FeatureKey) {
        cover = nil
        sheet = .signUpPrompt(feature)
    }

    /// Switches product, restoring that product's last selection. Safe to call with the current
    /// product: it then only closes the drawer.
    func switchTo(product newProduct: ProductKind) {
        if let current = selectedConversationID {
            selectionByProduct[product] = current
        }
        guard newProduct != product else {
            drawerOpen = false
            return
        }
        product = newProduct
        selectedConversationID = selectionByProduct[newProduct]
        drawerOpen = false
    }

    // MARK: URL handling

    static let customScheme = "firasai"

    /// Parses an incoming URL and, when it is ours, parks the destination in `pendingRoute`.
    /// Returns `false` for anything it does not own — notably the Google OAuth callback scheme,
    /// which `ASWebAuthenticationSession` handles by itself.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == Router.customScheme || scheme == "https" || scheme == "http"
        else {
            return false
        }

        let items = components.queryItems ?? []
        if let token = Router.value(of: "verify", in: items) {
            pendingRoute = .verify(token: token)
            return true
        }
        if let token = Router.value(of: "reset", in: items),
           let uid = Router.value(of: "uid", in: items) {
            pendingRoute = .reset(uid: uid, token: token)
            return true
        }
        if let id = Router.value(of: "share", in: items) {
            pendingRoute = .sharedChat(id: id)
            return true
        }
        if scheme == Router.customScheme,
           let route = Router.route(host: components.host, path: components.path) {
            pendingRoute = route
            return true
        }
        return false
    }

    private static func value(of name: String, in items: [URLQueryItem]) -> String? {
        guard let raw = items.first(where: { $0.name.lowercased() == name })?.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `firasai://chat/<id>`, `firasai://agent`, `firasai://settings/appearance`, and friends.
    private static func route(host: String?, path: String) -> AppRoute? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        let tail = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0) }
        let first = tail.first
        switch host {
        case "chat", "ai":
            guard let first else { return nil }
            return .chat(conversationID: first)
        case "agent":
            return .agent(conversationID: first)
        case "code":
            return .code(projectID: first)
        case "brain":
            return .brain
        case "studio", "media":
            return .studio(creationID: first)
        case "settings":
            let section = first.flatMap(SettingsSection.init(rawValue:)) ?? .account
            return .settings(section)
        case "auth", "login":
            let mode = first.flatMap(AuthMode.init(rawValue:)) ?? .login
            return .auth(mode: mode)
        default:
            return nil
        }
    }
}
