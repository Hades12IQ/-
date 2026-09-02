import SwiftUI

/// The `firas-ask` clarifying-questions card.
///
/// One question at a time (`web-plan-mode.md §3.4`): recommended options arrive pre-selected with
/// their badge, the free-text row appears only on the last step, and Confirm is dead until something
/// is chosen or typed. While a reply is streaming every tap is refused **with a toast** rather than
/// silently, which is defect D9 fixed (`web-plan-mode.md §7.7`).
struct AskPanelView: View {

    private let spec: AskSpec
    private let answered: Bool
    private let isStreaming: Bool
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let scale: FontScale
    private let motionOn: Bool
    private let onSubmit: ([String: [String]], String) -> Void
    private let onBlocked: () -> Void

    @State private var step: Int
    @State private var answers: [String: [String]]
    @State private var extra: String

    init(
        spec: AskSpec,
        answered: Bool,
        isStreaming: Bool,
        palette: FirasPalette,
        lang: AppLanguage,
        scale: FontScale,
        motionOn: Bool,
        onSubmit: @escaping ([String: [String]], String) -> Void,
        onBlocked: @escaping () -> Void
    ) {
        self.spec = spec
        self.answered = answered
        self.isStreaming = isStreaming
        self.palette = palette
        self.lang = lang
        self.scale = scale
        self.motionOn = motionOn
        self.onSubmit = onSubmit
        self.onBlocked = onBlocked
        _step = State(initialValue: 0)
        _answers = State(initialValue: AskPanelView.seed(spec))
        _extra = State(initialValue: "")
    }

    /// Recommended options start checked (`web-plan-mode.md §3.4`).
    private static func seed(_ spec: AskSpec) -> [String: [String]] {
        var seeded: [String: [String]] = [:]
        for question in spec.questions {
            let picked = question.options
                .map(\.id)
                .filter { question.recommended.contains($0) }
            if !picked.isEmpty {
                seeded[question.id] = question.multi ? picked : Array(picked.prefix(1))
            }
        }
        return seeded
    }

    var body: some View {
        SurfaceCard(palette: palette) {
            VStack(alignment: .leading, spacing: 14) {
                intro
                if let question = current {
                    legend(for: question)
                    options(of: question)
                }
                if isLastStep {
                    extraField
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .bidiIsland(for: directionSample, fallback: lang)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Content

    @ViewBuilder
    private var intro: some View {
        if let text = spec.intro?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            Text(text)
                .font(FirasType.scaled(15, scale: scale))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func legend(for question: AskSpec.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if spec.questions.count > 1 {
                Text(
                    Strings.Chat.askStep.fmt(
                        lang,
                        ArabicText.count(step + 1, lang),
                        ArabicText.count(spec.questions.count, lang)
                    )
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textMuted)
            }
            Text(question.text)
                .font(FirasType.scaled(16, scale: scale, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func options(of question: AskSpec.Question) -> some View {
        VStack(spacing: 6) {
            ForEach(question.options, id: \.id) { option in
                optionRow(option, in: question)
            }
        }
    }

    private func optionRow(_ option: AskSpec.Option, in question: AskSpec.Question) -> some View {
        let picked = (answers[question.id] ?? []).contains(option.id)
        let recommended = question.recommended.contains(option.id)
        return Button {
            toggle(option: option.id, in: question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: mark(picked: picked, multi: question.multi))
                    .font(.system(size: 16))
                    .foregroundStyle(picked ? palette.accent : palette.borderStrong)

                Text(option.label)
                    .font(FirasType.scaled(15, scale: scale))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if recommended {
                    Text(Strings.Chat.askRecommended(lang))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background { Capsule(style: .continuous).fill(palette.accentSoft) }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(picked ? palette.accentSoft : palette.surfaceSunken)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(picked ? palette.accentRing : palette.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(answered)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func mark(picked: Bool, multi: Bool) -> String {
        if multi { return picked ? "checkmark.square.fill" : "square" }
        return picked ? "largecircle.fill.circle" : "circle"
    }

    @ViewBuilder
    private var extraField: some View {
        if !answered {
            TextField(
                Strings.Chat.askExtraPlaceholder(lang),
                text: $extra,
                axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(.plain)
            .font(FirasType.scaled(15, scale: scale))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.surfaceSunken)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if step > 0 && !answered {
                Button(Strings.Chat.askBack(lang)) { back() }
                    .buttonStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .frame(minHeight: 44)
            }

            Spacer(minLength: 0)

            Button {
                advance()
            } label: {
                HStack(spacing: 6) {
                    Text(primaryTitle)
                        .font(.system(size: 15, weight: .semibold))
                    if !answered {
                        Image(systemName: isLastStep ? "checkmark" : "chevron.forward")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .foregroundStyle(primaryEnabled ? palette.onAccent : palette.textMuted)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background {
                    Capsule(style: .continuous)
                        .fill(primaryEnabled ? palette.accent : palette.surfaceSunken)
                }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(answered)
            .frame(minHeight: 44)
        }
    }

    private var primaryTitle: String {
        if answered { return Strings.Chat.askAnswered(lang) }
        return isLastStep ? Strings.Chat.askSubmit(lang) : Strings.Chat.askContinue(lang)
    }

    private var primaryEnabled: Bool {
        guard !answered else { return false }
        guard isLastStep else { return true }
        return hasAnySelection || !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - State

    private var current: AskSpec.Question? {
        guard step >= 0, step < spec.questions.count else { return spec.questions.first }
        return spec.questions[step]
    }

    private var isLastStep: Bool {
        step >= spec.questions.count - 1
    }

    private var hasAnySelection: Bool {
        answers.values.contains { !$0.isEmpty }
    }

    private var directionSample: String {
        spec.intro ?? spec.questions.first?.text ?? ""
    }

    private func toggle(option: String, in question: AskSpec.Question) {
        guard guardTaps() else { return }
        Haptics.select()
        var picked = answers[question.id] ?? []
        if question.multi {
            if let index = picked.firstIndex(of: option) {
                picked.remove(at: index)
            } else {
                picked.append(option)
            }
        } else {
            picked = picked.contains(option) ? [] : [option]
        }
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            answers[question.id] = picked
        }
    }

    private func back() {
        guard guardTaps() else { return }
        withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
            step = max(0, step - 1)
        }
    }

    private func advance() {
        guard guardTaps() else { return }
        if isLastStep {
            guard primaryEnabled else { return }
            Haptics.send()
            onSubmit(answers, extra.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                step = min(spec.questions.count - 1, step + 1)
            }
        }
    }

    /// D9: a tap during streaming says why instead of doing nothing.
    private func guardTaps() -> Bool {
        guard !answered else { return false }
        guard !isStreaming else {
            onBlocked()
            return false
        }
        return true
    }
}
