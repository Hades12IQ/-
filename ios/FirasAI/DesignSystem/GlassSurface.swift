import SwiftUI

struct GlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let tintStrength: Double
    let content: Content

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        cornerRadius: CGFloat = 22,
        tintStrength: Double = 0.08,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tintStrength = tintStrength
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, *), !reduceTransparency {
            content
                .glassEffect(
                    .regular.tint(preferences.palette.accent.opacity(tintStrength)),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(
                    reduceTransparency
                        ? AnyShapeStyle(preferences.palette.surface)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(preferences.palette.border.opacity(0.9), lineWidth: 1)
                }
        }
    }
}

struct GlassIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var prominent = false
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        if #available(iOS 26, *) {
            if prominent {
                Button(title, systemImage: systemImage, action: action)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel(title)
            } else {
                Button(title, systemImage: systemImage, action: action)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.glass)
                    .accessibilityLabel(title)
            }
        } else {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(preferences.palette.border, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(prominent ? preferences.palette.onAccent : preferences.palette.textPrimary)
            .background(prominent ? preferences.palette.accent : .clear, in: Circle())
            .accessibilityLabel(title)
        }
    }
}

struct FirasBackground: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            preferences.palette.background

            RadialGradient(
                colors: [
                    preferences.palette.accent.opacity(preferences.theme == .black ? 0.08 : 0.16),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 560
            )
            .opacity(reduceMotion ? 0.55 : 1)

            LinearGradient(
                colors: [
                    .clear,
                    preferences.palette.backgroundSubtle.opacity(0.42)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
