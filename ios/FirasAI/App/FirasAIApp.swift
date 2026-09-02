import SwiftUI

/// The entry point.
///
/// Three responsibilities and nothing else: build `AppEnvironment` exactly once, hand the app
/// delegate a lifecycle host so a tapped notification can reach the router, and forward the three
/// signals the system sends a scene — first appearance, phase changes and opened URLs.
///
/// `BGTaskScheduler.register` is deliberately **not** here: it must run before
/// `application(_:didFinishLaunchingWithOptions:)` returns, so `FirasAppDelegate` calls
/// `BackgroundRefresh.register` there and routes the task back through
/// `FirasAppDelegate.lifecycle`.
@main
struct FirasAIApp: App {
    @UIApplicationDelegateAdaptor(FirasAppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    @State private var env: AppEnvironment
    @State private var lifecycle: AppLifecycle

    init() {
        // ISOLATED_DEFAULT_VALUES: every store is constructed inside this MainActor-isolated
        // `App.init`, never as a stored-property default.
        let environment = AppEnvironment(config: AppConfiguration.live)
        let lifecycle = AppLifecycle(env: environment)

        _env = State(initialValue: environment)
        _lifecycle = State(initialValue: lifecycle)

        // Assigning this flushes a notification that arrived — or launched the app — before the
        // environment existed. The delegate's reference is weak; `@State` above owns the object.
        FirasAppDelegate.lifecycle = lifecycle
    }

    var body: some Scene {
        WindowGroup {
            env.inject(into: RootView(env: env))
                .onAppear {
                    // Re-assert it from the value `@State` actually kept: SwiftUI is free to build
                    // the `App` struct more than once, and only this object is the live one.
                    FirasAppDelegate.lifecycle = lifecycle
                }
                .task {
                    await lifecycle.didBecomeActive()
                }
                .onOpenURL { url in
                    lifecycle.handle(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    handle(phase: phase)
                }
        }
    }

    /// `.inactive` is a transient state (a system alert, the app switcher): nothing is flushed and
    /// nothing is re-attached until the phase settles.
    @MainActor
    private func handle(phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await lifecycle.didBecomeActive() }
        case .background:
            lifecycle.didEnterBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
