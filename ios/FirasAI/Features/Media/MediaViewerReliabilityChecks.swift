#if DEBUG
import SwiftUI
import UIKit

/// The mounted close button supplies its real action. The fixture never duplicates dismissal
/// code, and measures the laid-out label rather than assuming its target size from constants.
@MainActor
final class ViewerCloseReliabilityProbe {
    var action: (@MainActor () -> Void)?
    var buttonSize: CGSize = .zero
}

private struct ViewerCloseReliabilityKey: EnvironmentKey {
    static let defaultValue: ViewerCloseReliabilityProbe? = nil
}

extension EnvironmentValues {
    var viewerCloseReliabilityProbe: ViewerCloseReliabilityProbe? {
        get { self[ViewerCloseReliabilityKey.self] }
        set { self[ViewerCloseReliabilityKey.self] = newValue }
    }
}

@MainActor
enum MediaViewerReliabilityChecks {
    struct Result {
        var failures: [String] = []
        var metrics: [String: Double] = [:]
    }

    /// An unauthenticated smoke launch mounts both actual viewers and executes their actual
    /// button actions. This exercises native presentation wiring; it is not a physical tap test.
    static func run(env: AppEnvironment) async -> Result {
        guard ProcessInfo.processInfo.arguments.contains("--reliability-smoke") else {
            return .init(failures: ["Viewer fixture requires the isolated smoke launch"])
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController,
              presenter.presentedViewController == nil else {
            return .init(failures: ["Viewer fixture has no free foreground presenter"])
        }
        var result = Result()
        let previousCover = env.router.cover
        defer { env.router.cover = previousCover }
        env.router.cover = .mediaViewer(creationID: "viewer-dismiss-smoke")
        let mediaProbe = ViewerCloseReliabilityProbe()
        let generated = AnyView(MediaViewer(env: env, creationID: "viewer-dismiss-smoke")
            .environment(\.viewerCloseReliabilityProbe, mediaProbe))
        await exercise(generated, probe: mediaProbe, presenter: presenter, name: "generated", result: &result)
        result.metrics["generatedRouterCleared"] = env.router.cover == nil ? 1 : 0
        if env.router.cover != nil { result.failures.append("Generated image close left its router cover active") }

        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        let attachedProbe = ViewerCloseReliabilityProbe()
        var callbackCalled = false
        let attached = AnyView(AttachedImageViewer(image: image, palette: env.prefs.palette, lang: env.prefs.lang) {
            callbackCalled = true
        }.environment(\.viewerCloseReliabilityProbe, attachedProbe))
        await exercise(attached, probe: attachedProbe, presenter: presenter, name: "attached", result: &result)
        result.metrics["attachedBindingCallback"] = callbackCalled ? 1 : 0
        if !callbackCalled { result.failures.append("Attached image close did not clear its caller binding") }
        return result
    }

    private static func exercise(_ content: AnyView, probe: ViewerCloseReliabilityProbe,
                                 presenter: UIViewController, name: String, result: inout Result) async {
        let host = UIHostingController(rootView: content)
        host.modalPresentationStyle = .fullScreen
        presenter.present(host, animated: false)
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            if host.viewIfLoaded?.window != nil, !host.isBeingPresented, probe.action != nil { break }
            await JobClock.rest(0.03)
        }
        let mounted = host.viewIfLoaded?.window != nil && host.presentingViewController != nil
        result.metrics[name + "Mounted"] = mounted ? 1 : 0
        result.metrics[name + "CloseWidth"] = Double(probe.buttonSize.width)
        result.metrics[name + "CloseHeight"] = Double(probe.buttonSize.height)
        if !mounted || probe.action == nil { result.failures.append(name + " viewer close button did not mount") }
        if probe.buttonSize.width < 44 || probe.buttonSize.height < 44 {
            result.failures.append(name + " close button target is smaller than 44 points")
        }
        probe.action?()
        probe.action = nil
        let closeStart = Date()
        while host.presentingViewController != nil && Date().timeIntervalSince(closeStart) < 3 {
            await JobClock.rest(0.03)
        }
        let dismissed = host.presentingViewController == nil && presenter.presentedViewController !== host
        result.metrics[name + "NativeDismissed"] = dismissed ? 1 : 0
        result.metrics[name + "DismissMilliseconds"] = Date().timeIntervalSince(closeStart) * 1000
        if !dismissed {
            result.failures.append(name + " close action did not dismiss the native full-screen presentation")
            host.dismiss(animated: false)
            await JobClock.rest(0.1)
        }
    }
}
#endif
