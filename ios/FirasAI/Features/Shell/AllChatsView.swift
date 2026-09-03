import SwiftUI

/// The whole conversation list, as its own page.
///
/// The sidebar shows only the ten most recent conversations, because a drawer is for getting back to
/// what you were just doing, not for browsing an archive — a list of two hundred titles under a
/// product switcher is a wall, and the owner said so. Everything past those ten lives here, on a full
/// page you can actually scroll and search, which is how Claude's app splits the same problem.
///
/// It is deliberately not a second history implementation: `SidebarHistoryList` already owns the
/// row, the live dot, renaming, pinning and deleting, so this page hands it a query and an
/// unlimited row budget and gets out of the way.
@MainActor
struct AllChatsView: View {

    private let env: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SidebarSearch(env: env, query: $query)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                SidebarHistoryList(env: env, query: query, limit: nil)
            }
            .background(palette.background)
            .navigationTitle(Strings.Shell.allChats(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Strings.Common.done(lang)) { dismiss() }
                }
            }
        }
        .tint(palette.accent)
    }
}
