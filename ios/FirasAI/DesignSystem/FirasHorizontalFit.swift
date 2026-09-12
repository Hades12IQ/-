import SwiftUI
import Perception

/// Two-alternative horizontal fitting without a fixed device-width assumption.
struct FirasHorizontalFit<Primary: View, Fallback: View>: View {
    let primary: () -> Primary
    let fallback: () -> Fallback
    @State private var available: CGFloat = 0
    @State private var ideal: CGFloat = 0

    init(@ViewBuilder primary: @escaping () -> Primary, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.primary = primary
        self.fallback = fallback
    }

    var body: some View {
        WithPerceptionTracking {
            if #available(iOS 16, *), !FirasCompatibility.forceLegacyUI {
                ViewThatFits(in: .horizontal) {
                    WithPerceptionTracking { primary() }
                    WithPerceptionTracking { fallback() }
                }
            } else {
                ZStack(alignment: .topLeading) {
                    if available > 0 && ideal > available + 0.5 { fallback() }
                    else { primary() }
                }
                .frame(maxWidth: .infinity)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: FitAvailableWidth.self, value: proxy.size.width)
                })
                .overlay(alignment: .topLeading) {
                    WithPerceptionTracking { primary() }
                        .fixedSize(horizontal: true, vertical: false)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: FitIdealWidth.self, value: proxy.size.width)
                        })
                        .hidden().accessibilityHidden(true).allowsHitTesting(false).disabled(true)
                        .frame(width: 0, height: 0).clipped()
                }
                .onPreferenceChange(FitAvailableWidth.self) { if abs(available - $0) > 0.5 { available = $0 } }
                .onPreferenceChange(FitIdealWidth.self) { if abs(ideal - $0) > 0.5 { ideal = $0 } }
            }
        }
    }
}

private struct FitAvailableWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct FitIdealWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
