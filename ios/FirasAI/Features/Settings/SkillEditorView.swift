import SwiftUI
import Perception

@MainActor
struct SkillEditorView: View {
    let env: AppEnvironment
    let skill: AccountSkill
    let onSaved: (AccountSkill) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var cues: String
    @State private var rules: String
    @State private var mode: String
    @State private var enabled: Bool
    @State private var saving = false
    @State private var problem: String?

    init(env: AppEnvironment, skill: AccountSkill, onSaved: @escaping (AccountSkill) -> Void) {
        self.env = env; self.skill = skill; self.onSaved = onSaved
        _name = State(initialValue: skill.name)
        _cues = State(initialValue: skill.cues.joined(separator: "\n"))
        _rules = State(initialValue: skill.rules.joined(separator: "\n"))
        _mode = State(initialValue: skill.mode); _enabled = State(initialValue: skill.enabled)
    }
    private var lang: AppLanguage { env.prefs.lang }
    private var p: FirasPalette { env.prefs.palette }
    var body: some View {
        WithPerceptionTracking {
            FirasNavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        fieldTitle(LText(ar: "اسم المهارة", en: "Skill name")(lang), hint: "3–80")
                        TextField(LText(ar: "مثلاً: تقاريري الدراسية", en: "For example: My study reports")(lang), text: $name)
                            .font(.title3.weight(.semibold)).padding(14).background(p.surface, in: RoundedRectangle(cornerRadius: 14))
                            .bidiIsland(for: name, fallback: lang).accessibilityIdentifier("skill-name")
                        fieldTitle(LText(ar: "متى يستخدمها فراس؟", en: "When should Firas use it?")(lang), hint: LText(ar: "3–24 عبارة، كل عبارة بسطر", en: "3–24 phrases, one per line")(lang))
                        editor($cues, height: 110, label: LText(ar: "عبارات الاستخدام", en: "Use when")(lang))
                        fieldTitle(LText(ar: "التعليمات", en: "Instructions")(lang), hint: LText(ar: "4–24 تعليمة واضحة، كل تعليمة بسطر", en: "4–24 clear instructions, one per line")(lang))
                        editor($rules, height: 220, label: LText(ar: "تعليمات المهارة", en: "Skill instructions")(lang))
                        Text(LText(ar: "كل تعليمة من 28 إلى 300 حرف. اشرح أسلوب العمل والنتيجة التي تريدها.", en: "Each instruction needs 28–300 characters. Describe the method and the result you want.")(lang))
                            .font(.footnote).foregroundStyle(p.textMuted)
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(LText(ar: "الاستخدام", en: "Use")(lang), selection: $mode) {
                                Text(SkillsCopy.auto(lang)).tag("auto")
                                Text(SkillsCopy.always(lang)).tag("always")
                            }.pickerStyle(.segmented)
                            Text(LText(ar: "«دائماً» يطبّق أول مهارتين مفعّلتين. واختيار / يعطي أولوية لمهارات الرسالة.", en: "Always applies the first two enabled always-on skills. Choosing / gives your message’s skills priority.")(lang)).font(.footnote).foregroundStyle(p.textMuted)
                            Toggle(SkillsCopy.enabled(lang), isOn: $enabled)
                        }.padding(16).background(p.surface, in: RoundedRectangle(cornerRadius: 16))
                        if let problem { Text(SkillsCopy.problem(problem, lang)).font(.subheadline).foregroundStyle(p.textSecondary).accessibilityIdentifier("skill-error") }
                    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                        .bidiIsland(for: SkillsCopy.title(lang), fallback: lang)
                }
                .foregroundStyle(p.textPrimary).background(p.background)
                .navigationTitle((skill.id.isEmpty ? SkillsCopy.add : SkillsCopy.edit)(lang))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(Strings.Common.cancel(lang)) { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { save() } label: {
                            if saving { ProgressView() }
                            else { Text(LText(ar: "حفظ", en: "Save")(lang)).fontWeight(.semibold) }
                        }.disabled(saving || env.skills.mutating || !env.session.isMember)
                    }
                }
            }.tint(p.accent).preferredColorScheme(env.prefs.theme.isLight ? .light : .dark)
                .firasSheetBackground(p).interactiveDismissDisabled(saving)
                .firasOnChange(of: env.session.identityID) { _, _ in dismiss() }
        }
    }
    private func fieldTitle(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(hint).font(.caption).foregroundStyle(p.textMuted)
        }
    }
    private func editor(_ binding: Binding<String>, height: CGFloat, label: String) -> some View {
        TextEditor(text: binding).font(.body).frame(minHeight: height)
            .firasScrollContentBackground(.hidden)
            .padding(8).background(p.surface, in: RoundedRectangle(cornerRadius: 14))
            .bidiIsland(for: binding.wrappedValue, fallback: lang).accessibilityLabel(label)
    }
    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private func save() {
        let value = AccountSkill(id: skill.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            cues: Self.lines(cues), rules: Self.lines(rules), mode: mode, enabled: enabled)
        if let first = SkillValidation.problems(value).first { problem = first; return }
        saving = true; problem = nil
        Task {
            do { let saved = try await env.skills.save(value); saving = false; dismiss(); onSaved(saved) }
            catch { saving = false; problem = AccountSkillsStore.code(error) }
        }
    }
}
