import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    @FocusState.Binding var isFocused: Bool
    let isSending: Bool
    let selectedTier: ModelTier
    let contextCount: Int
    let onAddContext: () -> Void
    let onDraftChanged: () -> Void
    let onSelectModel: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onStartCall: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassSurface(cornerRadius: 25, tintStrength: 0.045) {
            VStack(spacing: 4) {
                messageField
                actionRow
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var messageField: some View {
        TextField("chat.placeholder", text: $draft, axis: .vertical)
            .font(.body)
            .foregroundStyle(preferences.palette.textPrimary)
            .tint(preferences.palette.accent)
            .lineLimit(1 ... 6)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 44)
            .focused($isFocused)
            .submitLabel(preferences.sendOnReturn ? .send : .return)
            .onSubmit {
                guard preferences.sendOnReturn else { return }
                onSend()
            }
            .onChange(of: draft) {
                onDraftChanged()
            }
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                contextButton
                modelButton
                Spacer(minLength: 4)
                primaryAction
                    .animation(primaryActionAnimation, value: primaryActionState)
            }

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    contextButton
                    modelButton
                    Spacer(minLength: 4)
                }
                HStack {
                    Spacer(minLength: 0)
                    primaryAction
                        .animation(primaryActionAnimation, value: primaryActionState)
                }
            }
        }
    }

    private var contextButton: some View {
        Button(action: onAddContext) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .overlay(alignment: .topTrailing) {
                    if contextCount > 0 {
                        Text(verbatim: "\(contextCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(preferences.palette.onAccent)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(preferences.palette.accent, in: Capsule())
                            .offset(x: 1, y: 1)
                    } else if preferences.webSearchEnabled || preferences.thinkingEnabled {
                        Circle()
                            .fill(preferences.palette.accent)
                            .frame(width: 7, height: 7)
                            .offset(x: -4, y: 5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(preferences.palette.textSecondary)
        .accessibilityLabel(Text(ChatStrings.context))
        .accessibilityValue(
            contextCount > 0
                ? Text(verbatim: "\(contextCount)")
                : Text(verbatim: "")
        )
    }

    private var modelButton: some View {
        Button(action: onSelectModel) {
            HStack(spacing: 6) {
                Text(verbatim: selectedTier.label(language: preferences.language))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(preferences.palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ChatStrings.selectModel))
        .accessibilityValue(Text(verbatim: selectedTier.label(language: preferences.language)))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if isSending {
            ComposerCircleButton(
                title: LocalizedStringResource("chat.stop"),
                systemImage: "stop.fill",
                isProminent: true,
                action: onStop
            )
            .id(ComposerPrimaryAction.stop)
            .transition(.scale(scale: 0.84).combined(with: .opacity))
        } else if canSend {
            ComposerCircleButton(
                title: LocalizedStringResource("chat.send"),
                systemImage: "arrow.up",
                isProminent: true,
                action: onSend
            )
            .id(ComposerPrimaryAction.send)
            .transition(.scale(scale: 0.84).combined(with: .opacity))
        } else {
            ComposerCircleButton(
                title: ChatStrings.startVoiceCall,
                systemImage: "waveform",
                isProminent: false,
                action: onStartCall
            )
            .id(ComposerPrimaryAction.call)
            .transition(.scale(scale: 0.84).combined(with: .opacity))
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var primaryActionState: ComposerPrimaryAction {
        if isSending { return .stop }
        return canSend ? .send : .call
    }

    private var primaryActionAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .spring(duration: 0.28, bounce: 0.16)
    }
}

private enum ComposerPrimaryAction: Hashable {
    case call
    case send
    case stop
}

private struct ComposerCircleButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isProminent: Bool
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 42, height: 42)
                .foregroundStyle(
                    isProminent ? preferences.palette.onAccent : preferences.palette.textSecondary
                )
                .background(
                    isProminent ? preferences.palette.accent : preferences.palette.surfaceSunken,
                    in: Circle()
                )
                .overlay {
                    if !isProminent {
                        Circle()
                            .stroke(preferences.palette.border, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.circle)
        .accessibilityLabel(Text(title))
    }
}
