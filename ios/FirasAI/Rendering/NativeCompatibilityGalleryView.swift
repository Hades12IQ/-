#if DEBUG
import SwiftUI
import Perception
import UIKit

/// Actual app screens mounted in the smoke host's existing window. Fixture text is local and
/// synthetic; no session is restored and the transport cannot address the production server.
@MainActor
struct NativeCompatibilityGalleryView: View {
    @ObservedObject var gallery: NativeCompatibilityGalleryModel

    var body: some View {
        WithPerceptionTracking {
            let screen = gallery.screen
            Group {
                switch screen {
                case .chat:
                    FirasNavigationStack {
                        ChatScreen(env: gallery.env, conversationID: gallery.chatID, product: .ai)
                    }
                case .settings:
                    SettingsView(env: gallery.env, section: .account)
                case .telegram:
                    FirasNavigationStack {
                        OmnixTelegramView(env: gallery.env)
                            .navigationTitle("تيليغرام أومنكس")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                case .code:
                    CodeCompatibilityGalleryView(env: gallery.env, surface: .workspace)
                case .codeModels:
                    CodeCompatibilityGalleryView(env: gallery.env, surface: .models)
                }
            }
            .environment(gallery.env.prefs)
            .environment(\.locale, Locale(identifier: "ar"))
            .environment(\.layoutDirection, .rightToLeft)
            .preferredColorScheme(.dark)
            .tint(gallery.env.prefs.palette.accent)
            .background(gallery.env.prefs.palette.background)
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { gallery.markMounted(screen, size: geometry.size) }
                }
            }
            .id(screen)
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
        }
    }
}

@MainActor
final class NativeCompatibilityGalleryModel: ObservableObject {
    enum Screen: String, CaseIterable {
        case chat, settings, telegram, code
        case codeModels = "code-models"

        var components: [String] {
            switch self {
            case .chat: return ["ChatScreen", "TranscriptView", "MarkdownView", "ComposerView"]
            case .settings: return ["SettingsView"]
            case .telegram: return ["OmnixTelegramView"]
            case .code: return ["CodeWorkspaceView"]
            case .codeModels: return ["CodeModelPicker"]
            }
        }
    }

    @Published var screen: Screen = .chat
    let env: AppEnvironment
    let chatID = "native-gallery-local-chat"
    private var mounted: Screen?
    private var mountedSize: CGSize = .zero
    private let defaultsSuite: String

    init() {
        let suite = "org.firasai.native-gallery." + UUID().uuidString
        defaultsSuite = suite
        let defaults = UserDefaults(suiteName: suite)!
        env = AppEnvironment(config: .init(apiBaseURL: URL(string: "https://native-gallery.invalid")!),
                             defaults: defaults)
        env.prefs.language = .arabic
        env.prefs.theme = .dark
        env.prefs.fontScale = .medium
        env.prefs.motionPreference = .reduced
        env.prefs.tier = .pro
        let messages = [
            ChatMessage(id: "native-gallery-question", role: .user,
                        content: "اشرح لي التكامل بخطوات واضحة ومرتبة.", lang: "ar"),
            ChatMessage(id: "native-gallery-answer", role: .assistant, content: Self.answer,
                        tier: ModelTier.pro.rawValue, lang: "ar")
        ]
        env.chat.setConversation(ChatConversation(id: chatID, title: "مثال توضيحي محلي",
                                                 messages: messages, ephemeral: true), forKey: chatID)
        _ = env.chat.state(for: chatID)
        CodeCompatibilityGalleryView.prepare(env: env)
    }

    static let answer = #"""
    نستخدم قاعدة القوة لإيجاد التكامل، ثم نعوّض بحدَّيه:

    $$\int_0^1 x\,dx=\frac12$$

    **النتيجة:** المساحة تحت المنحنى من صفر إلى واحد تساوي نصف وحدة مربعة.

    وفي التكامل بالتجزئة نختار:

    $dv = \cot\theta\,d\theta \Rightarrow v=\ln(\sin\theta)$
    """#

    func markMounted(_ value: Screen, size: CGSize) {
        guard value == screen else { return }
        mountedSize = size
        mounted = value
    }

    func capture(directory: URL) async -> (report: [String: Any], failures: [String]) {
        var failures: [String] = []
        var rows: [[String: Any]] = []
        let actualVersion = UIDevice.current.systemVersion
        let mode = FirasCompatibility.forceLegacyUI ? "forced-legacy" : "modern"
        let prefix = "native-gallery-ios-" + actualVersion.replacingOccurrences(of: ".", with: "-") + "-" + mode
        #if targetEnvironment(simulator)
        let runtimeKind = "simulator"
        #else
        let runtimeKind = "device"
        #endif

        for value in Screen.allCases {
            mounted = nil
            screen = value
            // The first screen may already have appeared before this async task was resumed.
            if value == .chat, mountedSize.width > 100 { mounted = .chat }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while mounted != value || mountedSize.width < 100 || mountedSize.height < 100 {
                guard ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else { break }
                await JobClock.rest(0.05)
            }
            guard mounted == value, mountedSize.width >= 100, mountedSize.height >= 100 else {
                failures.append("Native gallery did not mount " + value.rawValue)
                continue
            }
            if value == .chat {
                let style = MathIslandStyle(palette: env.prefs.palette, background: env.prefs.palette.background,
                                            fontScale: env.prefs.fontScale)
                let spans = MathScanner.spans(in: Self.answer)
                let mathDeadline = ProcessInfo.processInfo.systemUptime + 30
                while spans.contains(where: { MathIsland.shared.peekForReliability($0.id, style: style) == nil }),
                      ProcessInfo.processInfo.systemUptime < mathDeadline, !Task.isCancelled {
                    await JobClock.rest(0.05)
                }
                if spans.contains(where: { MathIsland.shared.peekForReliability($0.id, style: style) == nil }) {
                    failures.append("Native gallery chat mathematics did not finish drawing")
                }
            }
            // Allow UIKit navigation/list layout and the next display commit to settle.
            await JobClock.rest(0.3)
            let filename = prefix + "-" + value.rawValue + ".png"
            do {
                let dimensions = try saveScreen(directory.appendingPathComponent(filename))
                rows.append(["screen": value.rawValue, "file": filename, "components": value.components,
                             "pixelWidth": dimensions.width, "pixelHeight": dimensions.height])
            } catch {
                failures.append("Native gallery could not save " + value.rawValue)
            }
        }

        var report: [String: Any] = [
            "status": failures.isEmpty ? "passed" : "failed",
            "actualOSVersion": actualVersion,
            "operatingSystemDescription": ProcessInfo.processInfo.operatingSystemVersionString,
            "runtimeKind": runtimeKind,
            "forcedLegacyUI": FirasCompatibility.forceLegacyUI,
            "deterministicLocalFixture": true,
            "networkBase": "https://native-gallery.invalid",
            "authenticatedSessionRestored": false,
            "evidence": "Actual native app screens. Forced compatibility branches do not emulate an older OS runtime.",
            "screens": rows,
            "errors": failures
        ]
        do {
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: directory.appendingPathComponent(prefix + ".json"), options: .atomic)
        } catch {
            failures.append("Native gallery metadata could not be saved")
        }
        report["errors"] = failures
        report["status"] = failures.isEmpty ? "passed" : "failed"
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: directory.appendingPathComponent("native-gallery-complete.json"), options: .atomic)
        }
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        return (report, failures)
    }

    private func saveScreen(_ url: URL) throws -> CGSize {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) else {
            throw GalleryError.noWindow
        }
        window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        var drew = false
        let image = renderer.image { _ in drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard drew, let bytes = image.pngData() else { throw GalleryError.noImage }
        try bytes.write(to: url, options: .atomic)
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    private enum GalleryError: Error { case noWindow, noImage }
}
#endif
