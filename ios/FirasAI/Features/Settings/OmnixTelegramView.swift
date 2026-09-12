import SwiftUI
import UIKit

@MainActor
struct OmnixTelegramView: View {
    let env: AppEnvironment
    @State private var model: OmnixTelegramSettingsModel
    @State private var botToken = ""
    @State private var telegramID = ""
    @State private var confirmDisconnect = false
    @State private var showAccess = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var ar: Bool { lang == .arabic }
    private var accountKey: String? { env.session.isMember ? env.session.identityID : nil }
    private var ownsState: Bool { accountKey != nil && model.owner == accountKey }

    init(env: AppEnvironment) {
        self.env = env
        _model = State(initialValue: OmnixTelegramSettingsModel(api: env.api, session: env.session))
    }

    var body: some View {
        SettingsPageBody(palette: palette) {
            Text(ar ? "استخدم أومنكس من بوتك الخاص في تيليغرام، بنفس حسابك ومساحة العمل السحابية." : "Use Omnix from your private Telegram bot, with the same account and cloud workspace.")
                .font(.subheadline).foregroundStyle(palette.textSecondary)
            if accountKey == nil {
                SettingsNoticeBanner(text: ar ? "سجّل الدخول لربط بوت خاص بحسابك." : "Sign in to link your private bot.", kind: .info, palette: palette)
                SettingsSubmitButton(title: ar ? "تسجيل الدخول" : "Sign in", palette: palette) { env.router.showSignUp(feature: .generic) }
            } else if ownsState {
                statusPanel
                if let notice = model.notice {
                    SettingsNoticeBanner(text: notice, kind: .error, palette: palette)
                }
                if model.status?.mayConfigure == true { configurationPanel }
                if model.status?.state == .pairing { pairingPanel }
                if model.status?.state == .connected { connectedPanel }
                if model.status?.state.canDisconnect == true {
                    SettingsSubmitButton(title: ar ? "إزالة الربط" : "Remove connection", symbol: "link.badge.plus", palette: palette,
                                         prominent: false, destructive: true, isDisabled: model.busy) { confirmDisconnect = true }
                }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 44) }
            instructionsPanel
        }
        .foregroundStyle(palette.textPrimary)
        .tint(palette.accent)
        .task(id: accountKey) {
            botToken = ""; telegramID = ""; confirmDisconnect = false
            model.activate()
            await model.refresh(lang: lang)
            while !Task.isCancelled && accountKey != nil {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                model.expirePairing()
                if scenePhase == .active && model.status?.state.awaitingChange == true { await model.refresh(lang: lang) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh(lang: lang) } }
            else { botToken = "" }
        }
        .onDisappear { botToken = ""; telegramID = ""; model.deactivate() }
        .sheet(isPresented: $showAccess) { OmnixAccessView(env: env) }
        .confirmationDialog(ar ? "إزالة ربط تيليغرام؟" : "Remove Telegram connection?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button(ar ? "إزالة الربط" : "Remove connection", role: .destructive) {
                botToken = ""; telegramID = ""
                Task { await model.disconnect(lang: lang) }
            }
            Button(Strings.Common.cancel(lang), role: .cancel) {}
        } message: {
            Text(ar ? "تُحذف بيانات الربط والرمز والطابور وسجلات التسليم من فراس، ويُطلب إيقاف مهامه الجارية. تبقى ملفات حسابك وذاكرته ومحادثاته. لا يُحذف البوت أو الرسائل التي وصلت إلى تيليغرام. انتظر تأكيد الإزالة قبل ربط بوت آخر." : "Firas erases the connection, token, queue and delivery records, and requests that running tasks stop. Account files, memory and conversations remain. The bot and messages already delivered to Telegram are not deleted. Wait for confirmed removal before linking another bot.")
        }
    }

    private var statusPanel: some View {
        SettingsPanel(title: ar ? "حالة الربط" : "Connection status", palette: palette, lang: lang) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.status?.state == .connected ? "checkmark.circle" : "paperplane").foregroundStyle(palette.accent) }
                    Text(statusTitle).font(.headline)
                }
                Text(statusDetail).font(.subheadline).foregroundStyle(palette.textSecondary)
                if let name = model.status?.bot?.username {
                    Text("@" + name).font(.subheadline.monospaced()).environment(\.layoutDirection, .leftToRight)
                }
                if let id = model.status?.telegramUserId {
                    Text((ar ? "معرّفك: " : "Your ID: ") + String(id)).font(.footnote).foregroundStyle(palette.textMuted).privacySensitive()
                }
                SettingsSubmitButton(title: ar ? "تحديث الحالة" : "Refresh status", symbol: "arrow.clockwise", palette: palette,
                                     prominent: false, isDisabled: model.busy) { Task { await model.refresh(lang: lang) } }
                if model.status?.cloudReady == false || model.status?.state == .approvalExpired {
                    Button(ar ? "عرض الوصول إلى أومنكس" : "View Omnix access") { showAccess = true }.frame(minHeight: 44)
                }
            }.padding(14)
        }
    }

    private var configurationPanel: some View {
        SettingsPanel(title: ar ? "ربط البوت" : "Link your bot", palette: palette, lang: lang) {
            VStack(alignment: .leading, spacing: 12) {
                Text(ar ? "رمز البوت من BotFather" : "Bot token from BotFather").font(.subheadline.weight(.medium))
                SecureField(ar ? "الصق رمز البوت" : "Paste bot token", text: $botToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(nil)
                    .font(.body.monospaced()).environment(\.layoutDirection, .leftToRight)
                    .padding(12).background(palette.background, in: RoundedRectangle(cornerRadius: 12)).privacySensitive()
                    .onChange(of: botToken) { _, value in if value.count > 225 { botToken = String(value.prefix(225)) } }
                Text(ar ? "معرّف حسابك الشخصي في تيليغرام" : "Your personal Telegram user ID").font(.subheadline.weight(.medium))
                TextField(ar ? "المعرّف الرقمي" : "Numeric user ID", text: $telegramID)
                    .keyboardType(.numberPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight).padding(12)
                    .background(palette.background, in: RoundedRectangle(cornerRadius: 12)).privacySensitive()
                    .onChange(of: telegramID) { _, value in if value.count > 16 { telegramID = String(value.prefix(16)) } }
                Text(ar ? "ليس رقم الهاتف أو اسم المستخدم أو معرّف البوت. يُقبل الربط من هذا الحساب الشخصي فقط." : "This is not your phone number, username or bot ID. Only this personal account can complete pairing.")
                    .font(.footnote).foregroundStyle(palette.textMuted)
                SettingsSubmitButton(title: ar ? "ربط تيليغرام" : "Link Telegram", symbol: "paperplane", palette: palette,
                                     isWorking: model.busy, isDisabled: !configurationValid) { configure() }
            }.padding(14)
        }
    }

    private var configurationValid: Bool {
        !model.busy && model.status?.mayConfigure == true
        && OmnixTelegramService.validToken(botToken.trimmingCharacters(in: .whitespacesAndNewlines))
        && OmnixTelegramService.userID(telegramID) != nil
    }
    private func configure() {
        guard ownsState, configurationValid, let id = OmnixTelegramService.userID(telegramID) else { return }
        let token = botToken
        botToken = "" // The secure field is cleared before the request starts.
        Task { await model.configure(token: token, userID: id, lang: lang) }
    }

    private var pairingPanel: some View {
        SettingsPanel(title: ar ? "الخطوة الأخيرة في تيليغرام" : "Finish in Telegram", palette: palette, lang: lang) {
            VStack(alignment: .leading, spacing: 12) {
                if let pairing = model.pairing, let command = pairing.command(owner: accountKey, status: model.status) {
                    Text(ar ? "افتح البوت واضغط Start من حساب المعرّف الذي أدخلته، أو أرسل هذا الأمر في محادثته الخاصة." : "Open the bot and tap Start from the account whose ID you entered, or send this command in its private chat.")
                        .font(.subheadline)
                    Text(command).font(.footnote.monospaced()).environment(\.layoutDirection, .leftToRight)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(palette.background, in: RoundedRectangle(cornerRadius: 10)).privacySensitive()
                    Text(ar ? "رمز مؤقت، لا تشاركه. يختفي عند مغادرة هذه الصفحة." : "Temporary code. Do not share it. It disappears when you leave this page.")
                        .font(.footnote).foregroundStyle(palette.textMuted)
                    SettingsSubmitButton(title: ar ? "فتح البوت في تيليغرام" : "Open bot in Telegram", symbol: "arrow.up.right", palette: palette, isDisabled: model.busy) {
                        guard ownsState, !model.busy,
                              let url = model.pairing?.botURL(owner: accountKey, status: model.status) else { return }
                        openURL(url)
                    }
                    SettingsSubmitButton(title: ar ? "نسخ أمر الربط" : "Copy pairing command", symbol: "doc.on.doc", palette: palette, prominent: false, isDisabled: model.busy) {
                        guard ownsState, !model.busy, let pairing = model.pairing,
                              let value = pairing.command(owner: accountKey, status: model.status) else { return }
                        UIPasteboard.general.setItems([["public.utf8-plain-text": value]], options: [.localOnly: true, .expirationDate: pairing.expiresAt])
                        env.toasts.show(ar ? "تم نسخ أمر الربط." : "Pairing command copied.")
                    }
                } else {
                    Text(ar ? "الربط بانتظار التأكيد. إذا فقدت الرمز أو انتهت صلاحيته، أزل الربط وأعد إعداده للحصول على رمز جديد." : "Pairing awaits confirmation. If the code was lost or expired, remove the connection and set it up again to get a new code.")
                        .font(.subheadline)
                }
            }.padding(14)
        }
    }

    private var connectedPanel: some View {
        SettingsNoticeBanner(text: ar ? "الربط جاهز. أرسل طلبك أو صورك أو ملفاتك للبوت في محادثة خاصة. يستمر العمل في السحابة عند إغلاق التطبيق، وتصل النتائج إلى تيليغرام. تبدأ جلسة جديدة فقط عندما تطلبها باستخدام /new." : "Connected. Send requests, images or files to the bot in a private chat. Work continues in the cloud when this app closes, and results arrive in Telegram. A new session starts only when you request one with /new.", kind: .success, palette: palette)
    }

    private var instructionsPanel: some View {
        SettingsPanel(title: ar ? "إعداد بوت خاص" : "Set up a private bot", palette: palette, lang: lang) {
            VStack(alignment: .leading, spacing: 12) {
                Text(ar ? "1. افتح BotFather وأنشئ بوتًا بالأمر /newbot. احتفظ بالرمز الذي يعطيك إياه." : "1. Open BotFather and create a bot with /newbot. Keep the token it supplies.")
                Link(destination: URL(string: "https://t.me/BotFather")!) {
                    Label(ar ? "فتح BotFather" : "Open BotFather", systemImage: "arrow.up.right").frame(minHeight: 44)
                }
                Text(ar ? "2. من /setjoingroups عطّل المجموعات. أوقف inline وguest وbusiness ليبقى البوت خاصًا." : "2. Disable groups with /setjoingroups. Turn off inline, guest and business modes to keep the bot private.")
                Text(ar ? "3. أدخل الرمز ومعرّف حسابك الشخصي الرقمي هنا، ثم أكمل الربط من الحساب نفسه في محادثة البوت الخاصة. لا تُقبل المجموعات أو الرسائل المحوّلة." : "3. Enter the token and your personal numeric user ID here, then finish pairing from that same account in the bot's private chat. Groups and forwarded messages are not accepted.")
                Text(ar ? "يلزم حساب مسجّل وموافقة أومنكس ومساحة سحابية جاهزة." : "A signed-in account, Omnix approval and a ready cloud workspace are required.")
                    .foregroundStyle(palette.textMuted)
            }.font(.subheadline).padding(14)
        }
    }

    private var statusTitle: String {
        switch model.status?.state {
        case .notConfigured: return ar ? "غير مرتبط" : "Not linked"
        case .pairing: return ar ? "بانتظار تأكيدك" : "Waiting for your confirmation"
        case .connected: return ar ? "مرتبط" : "Connected"
        case .setupUncertain: return ar ? "الإعداد غير مؤكّد" : "Setup unconfirmed"
        case .approvalExpired: return ar ? "انتهت موافقة الوصول" : "Access approval expired"
        case .ownerIDRequired: return ar ? "يلزم معرّف حسابك" : "Your user ID is required"
        case .disconnecting: return ar ? "جارٍ إزالة الربط" : "Removing connection"
        case .disconnectUncertain: return ar ? "الإزالة غير مؤكّدة" : "Removal unconfirmed"
        case .disconnected: return ar ? "أُزيل الربط" : "Connection removed"
        case .settingUp: return ar ? "جارٍ إعداد الربط" : "Setting up connection"
        case nil: return model.busy ? (ar ? "جارٍ تحديث الحالة…" : "Refreshing status…") : (ar ? "الحالة غير متاحة" : "Status unavailable")
        }
    }
    private var statusDetail: String {
        switch model.status?.state {
        case .notConfigured, .disconnected:
            return model.status?.mayConfigure == true
                ? (ar ? "يمكنك ربط بوت خاص بحسابك الآن." : "You can now link a private bot to your account.")
                : (ar ? "يُتاح الربط بعد موافقة أومنكس وتجهيز مساحة حسابك السحابية." : "Linking becomes available after Omnix approval and cloud workspace preparation.")
        case .pairing: return ar ? "أكمل الخطوة الأخيرة من حسابك في تيليغرام." : "Complete the last step from your Telegram account."
        case .connected: return ar ? "البوت مرتبط بحسابك الشخصي فقط." : "The bot is linked exclusively to your personal account."
        case .setupUncertain, .disconnectUncertain: return ar ? "رسائل البوت متوقفة. لا تربط بوتًا آخر حتى يراجع المطوّر الحالة ويؤكّد الإزالة." : "Bot messages are stopped. Do not link another bot until the developer reviews the state and confirms removal."
        case .approvalExpired: return ar ? "أُوقفت الطلبات الجديدة. راجع وصول أومنكس أو أزل الربط." : "New requests are stopped. Review Omnix access or remove the connection."
        case .ownerIDRequired: return ar ? "أزل الربط ثم أعد إعداده باستخدام معرّف حسابك الشخصي الرقمي." : "Remove the connection, then set it up again with your personal numeric user ID."
        case .disconnecting: return ar ? "جارٍ تأكيد الإزالة وإيقاف المهام المرتبطة. تُحدّث الحالة تلقائيًا." : "Confirming removal and stopping linked tasks. Status refreshes automatically."
        case .settingUp: return ar ? "الخادم يُعدّ الاتصال. تُحدّث الحالة تلقائيًا." : "The server is setting up the connection. Status refreshes automatically."
        case nil: return ar ? "حدّث الحالة لمعرفة وضع الربط الخاص بحسابك." : "Refresh to check your account's connection state."
        }
    }
}
