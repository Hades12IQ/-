import SwiftUI
import Perception

/// The same stack presentation on modern systems and a native single-column stack on iOS 15.
/// Destination registration remains explicit; this type never owns a second router or store.
struct FirasNavigationStack<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
                NavigationStack { content() }
            } else {
                NavigationView { content() }
                    .navigationViewStyle(.stack)
            }
        }
    }
}

extension View {
    /// Item-driven file/details navigation, with the same optional binding owning dismissal.
    @ViewBuilder
    func firasNavigationDestination<Item: Hashable, Destination: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17, *), !FirasCompatibility.forceLegacyUI {
            navigationDestination(item: item, destination: destination)
        } else {
            background {
                NavigationLink(
                    isActive: Binding(
                        get: { item.wrappedValue != nil },
                        set: { if !$0 { item.wrappedValue = nil } }
                    ),
                    destination: {
                        WithPerceptionTracking {
                            if let value = item.wrappedValue { destination(value) }
                        }
                    },
                    label: { EmptyView() }
                )
                .isDetailLink(false)
                .hidden()
                .accessibilityHidden(true)
            }
        }
    }
}
