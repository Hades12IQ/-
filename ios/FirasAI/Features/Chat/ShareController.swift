import SwiftUI
import UIKit
import Observation

/// Creating a public link to a conversation, or to one answer inside it
/// (`POST /api/share`, `server-chat-jobs-chats.md §6`, `web-auth-account-settings.md §9`).
///
/// Members only. A guest never sees a failure here — the request is not made at all; the sign-up
/// prompt for `.share` opens instead, which is what the web does.
///
/// The link is copied to the pasteboard the moment it arrives, exactly as the web does, so the sheet
/// that follows is a confirmation and an apps hand-off, not a second step the user must complete.
@MainActor
@Observable
final class ShareController {

    enum Phase: Equatable {
        case idle
        case creating
        case ready(URL)
        case failed(LText)
    }

    private let env: AppEnvironment

    private(set) var phase: Phase = .idle
    private(set) var didCopy = false

    init(env: AppEnvironment) {
        self.env = env
    }

    var link: URL? {
        if case .ready(let url) = phase { return url }
        return nil
    }

    var isCreating: Bool {
        phase == .creating
    }

    var errorText: LText? {
        if case .failed(let copy) = phase { return copy }
        return nil
    }

    // MARK: - Creating

    /// `conversationID` is the app's id for the conversation; the server id is resolved from the
    /// store, because a member's `ChatConversation.id` is already the server id while a guest's is
    /// a local `ios_…` one (and a guest never gets this far).
    func createLink(conversationID: String, messageCID: String?, title: String?) async {
        guard !isCreating else { return }

        guard env.session.isMember else {
            phase = .idle
            env.router.showSignUp(feature: .share)
            return
        }

        let serverID = env.chat.conversations[conversationID]?.serverID ?? conversationID
        guard !serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed(ShareCopy.noMessages)
            return
        }

        phase = .creating
        didCopy = false

        let single = messageCID != nil
        do {
            let request = ShareCreateRequest(chatId: serverID, cid: messageCID, title: title)
            let info = try await env.api.createShare(request)
            guard !info.id.isEmpty else {
                phase = .failed(single ? ShareCopy.oneFail : ShareCopy.fail)
                return
            }
            let url = info.url
            phase = .ready(url)
            UIPasteboard.general.string = url.absoluteString
            didCopy = true
            Haptics.select()
            env.toasts.show(single ? ShareCopy.oneCopied(env.prefs.lang) : ShareCopy.copied(env.prefs.lang))
        } catch {
            let copy = ShareController.copy(for: error, single: single)
            phase = .failed(copy)
            Haptics.error()
        }
    }

    /// Re-copies an already created link (the sheet's Copy button).
    func copyLink() {
        guard let url = link else { return }
        UIPasteboard.general.string = url.absoluteString
        didCopy = true
        Haptics.select()
    }

    func reset() {
        phase = .idle
        didCopy = false
    }

    // MARK: - Error copy

    /// Status-driven, never the server's own sentence (`ARCHITECTURE §2.15`). The 20-link ceiling
    /// is a **409** and rate limiting is a **429** (`server-chat-jobs-chats.md §6`).
    private static func copy(for error: Error, single: Bool) -> LText {
        if let apiError = error as? APIError {
            switch apiError {
            case .offline:
                return Strings.Errors.offline
            case .transport:
                return Strings.Errors.offline
            case .deadline:
                return Strings.Errors.timeout
            case .cancelled:
                return single ? ShareCopy.oneFail : ShareCopy.fail
            default:
                break
            }
            switch apiError.status ?? 0 {
            case 401:
                return Strings.Errors.sessionExpired
            case 404:
                return ShareCopy.notFound
            case 409:
                return ShareCopy.cap
            case 429:
                return ShareCopy.busy
            default:
                break
            }
        }
        return single ? ShareCopy.oneFail : ShareCopy.fail
    }
}

// MARK: - The sheet

/// `AppSheet.share(conversationID:messageCID:)`.
///
/// The router folds `AppRoute.sharedChat(id:)` into the same sheet case, so an id that has the shape
/// of a public share id (`s` + base36 + 10 hex, no separators) opens the read-only viewer instead of
/// trying to create a link for a conversation that does not exist on this device.
struct ShareSheetView: View {

    private let env: AppEnvironment
    private let conversationID: String
    private let messageCID: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var controller: ShareController?
    @State private var showActivity = false

    init(env: AppEnvironment, conversationID: String, messageCID: String?) {
        self.env = env
        self.conversationID = conversationID
        self.messageCID = messageCID
    }

    var body: some View {
        if isPublicShareLink {
            SharedChatView(env: env, shareID: conversationID)
        } else {
            linkSheet
        }
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var motionOn: Bool { FirasMotion.isOn(prefs: env.prefs, reduceMotion: reduceMotion) }

    /// A server share id is `"s" + base36 + 10 hex` — lowercase alphanumerics only. Conversation ids
    /// always carry a separator (`c_…`, `ios_…`) or the dashes of a UUID.
    private var isPublicShareLink: Bool {
        guard messageCID == nil else { return false }
        let id = conversationID
        guard id.count >= 8, id.count <= 40, id.hasPrefix("s") else { return false }
        for character in id where !(character.isLowercase && character.isLetter) && !character.isNumber {
            return false
        }
        return true
    }

    // MARK: - Link sheet

    private var linkSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                sheetContent
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(Text(ShareCopy.sheetTitle(lang)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text(Strings.Common.close(lang))
                    }
                    .foregroundStyle(palette.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .firasSheetBackground(palette)
        .task { await start() }
        .sheet(isPresented: $showActivity) {
            if let url = controller?.link {
                FirasActivitySheet(url: url)
            }
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch controller?.phase ?? .idle {
        case .idle, .creating:
            creatingState
        case .ready(let url):
            readyState(url)
        case .failed(let copy):
            failedState(copy)
        }
    }

    private var creatingState: some View {
        HStack(spacing: 10) {
            FirasActivityLabel(
                text: messageCID == nil ? ShareCopy.creating(lang) : ShareCopy.oneCreating(lang),
                palette: palette,
                motionOn: motionOn
            )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 24)
    }

    private func readyState(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(url.absoluteString)
                .font(FirasType.mono)
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .surfaceCard(palette)
                .forceLTR()

            HStack(spacing: 10) {
                Button {
                    controller?.copyLink()
                } label: {
                    Label {
                        Text(copyLabel)
                    } icon: {
                        Image(systemName: (controller?.didCopy ?? false) ? "checkmark" : "doc.on.doc")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Capsule(style: .continuous).fill(palette.surfaceSunken))
                    .overlay(Capsule(style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    showActivity = true
                } label: {
                    Label {
                        Text(ShareCopy.viaApps(lang))
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Capsule(style: .continuous).fill(palette.accent))
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text(messageCID == nil ? ShareCopy.noteAll(lang) : ShareCopy.noteOne(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var copyLabel: String {
        (controller?.didCopy ?? false) ? Strings.Common.copied(lang) : ShareCopy.copyLink(lang)
    }

    private func failedState(_ copy: LText) -> some View {
        EmptyStateView(
            title: ShareCopy.failedTitle(lang),
            subtitle: copy(lang),
            buttonTitle: Strings.Common.retry(lang),
            palette: palette,
            action: { retry() }
        )
    }

    // MARK: - Actions

    private func start() async {
        let live = controller ?? ShareController(env: env)
        controller = live
        guard live.phase == .idle else { return }
        await live.createLink(
            conversationID: conversationID,
            messageCID: messageCID,
            title: env.chat.conversations[conversationID]?.title
        )
    }

    private func retry() {
        guard let controller else { return }
        controller.reset()
        Task { await start() }
    }
}

// MARK: - Copy

/// Verbatim from the web's share strings (`web-auth-account-settings.md §9.2–9.3`,
/// `web-chat-ux.md` Appendix A).
private enum ShareCopy {
    static let sheetTitle = LText(ar: "رابط المشاركة", en: "Share link")
    static let creating = LText(ar: "ينشئ رابط المشاركة…", en: "Creating share link…")
    static let oneCreating = LText(ar: "ينشئ رابط الإجابة…", en: "Creating the answer link…")
    static let copied = LText(ar: "تم نسخ رابط المشاركة ✓", en: "Share link copied ✓")
    static let oneCopied = LText(ar: "تم نسخ رابط الإجابة ✓", en: "Answer link copied ✓")
    static let copyLink = LText(ar: "نسخ الرابط", en: "Copy link")
    static let viaApps = LText(ar: "مشاركة عبر التطبيقات", en: "Share via apps…")

    static let noteAll = LText(
        ar: "أي شخص يملك الرابط يستطيع قراءة هذه المحادثة.",
        en: "Anyone with the link can read this conversation."
    )
    static let noteOne = LText(
        ar: "من يفتح الرابط يقرأ هذه الإجابة وحدها، ولا يرى بقيّة المحادثة.",
        en: "Whoever opens the link reads this answer only — the rest of the conversation isn't there."
    )

    static let failedTitle = LText(ar: "تعذّر إنشاء الرابط", en: "Couldn't create the link")
    static let fail = LText(
        ar: "تعذّر إنشاء الرابط — تأكد من تسجيل الدخول واتصالك ثم أعد المحاولة",
        en: "Couldn't create the link — check you're signed in and online, then retry"
    )
    static let oneFail = LText(
        ar: "تعذّر إنشاء الرابط — تأكد من تسجيل الدخول واتصالك ثم أعد المحاولة",
        en: "Couldn't create the link — check you're signed in and online, then retry"
    )
    static let busy = LText(
        ar: "طلبات كثيرة بسرعة — انتظر دقيقة ثم أعد المحاولة",
        en: "Too many requests — wait a minute, then try again"
    )
    static let cap = LText(
        ar: "وصلت إلى الحد الأقصى لروابط المشاركة في حسابك",
        en: "You've reached the share-link limit on your account"
    )
    static let notFound = LText(
        ar: "هذه المحادثة غير محفوظة على الخادم بعد — أرسل رسالة فيها ثم أعد المحاولة",
        en: "This conversation isn't saved on the server yet — send a message in it, then retry"
    )
    static let noMessages = LText(
        ar: "افتح محادثة فيها رسائل أولًا",
        en: "Open a chat with messages first"
    )
}
