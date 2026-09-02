import SwiftUI

/// Batch 0 entry point.
///
/// `AppEnvironment` does not exist yet, so the three stores the stub shell needs are built here, in
/// dependency order, exactly once. Batch 2 replaces this body with
/// `env.inject(into: RootView(env: env))` plus `scenePhase` / `onOpenURL` wiring.
@main
struct FirasAIApp: App {
    @UIApplicationDelegateAdaptor(FirasAppDelegate.self) private var appDelegate

    @State private var preferences: PreferencesStore
    @State private var network: NetworkMonitor
    @State private var session: SessionStore
    @State private var router: Router

    init() {
        // ISOLATED_DEFAULT_VALUES: every store is constructed here, inside the MainActor-isolated
        // `App.init`, never as a stored-property default.
        let api = APIClient(configuration: AppConfiguration.live)
        let preferences = PreferencesStore(defaults: UserDefaults.standard)
        let network = NetworkMonitor()
        let session = SessionStore(api: api, prefs: preferences, network: network)

        _preferences = State(initialValue: preferences)
        _network = State(initialValue: network)
        _session = State(initialValue: session)
        _router = State(initialValue: Router())
    }

    var body: some Scene {
        WindowGroup {
            RootView(prefs: preferences, session: session, network: network)
                .environment(router)
                .onOpenURL { url in
                    router.handle(url: url)
                }
        }
    }
}
