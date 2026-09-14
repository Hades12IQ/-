import SwiftUI
import Perception

@MainActor
struct SkillComposerField: View {
    let env: AppEnvironment
    @Binding var text: String
    let draft: SkillDraft
    let placeholder: String
    var pointSize: CGFloat = 17
    var maxLines: Int = 6
    var focused: FocusState<Bool>.Binding
    var sendOnReturn = false
    var onSubmit: () -> Void = {}
    var pasteCharacterBudget: Int? = nil
    var pasteSlots: Int = 5
    @State private var showsLibrary = false
    @State private var libraryToken: SkillSlashToken?
    @State private var preview: PastedTextItem?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dismiss) private var dismiss
    private var lang: AppLanguage { env.prefs.lang }
    private var p: FirasPalette { env.prefs.palette }
    private var token: SkillSlashToken? { draft.token(text) }
    private var available: [AccountSkill] {
        let selected = Set(draft.mentions.map(\.id))
        let query = SkillSearch.fold(token?.query ?? "")
        return env.skills.skills.filter { $0.enabled && !selected.contains($0.id) && (query.isEmpty || SkillSearch.fold($0.name + " " + $0.cues.joined(separator: " ")).contains(query)) }
    }
    private var commands: [SlashCommand] {
        let query = SkillSearch.fold(token?.query ?? "")
        return SlashCommand.allCases.filter { query.isEmpty || SkillSearch.fold($0.label(lang)).contains(query) || $0.rawValue.hasPrefix(query) }
    }
    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { value in draft.synchronize(value); text = value })
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                if let token, enabled { menu(token) }
                if !draft.pastes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(draft.pastes) { item in
                                PastedTextCard(item: item, palette: p, lang: lang, open: { preview = item },
                                    remove: { draft.pastes.removeAll { $0.id == item.id } })
                            }
                        }
                    }
                }
                FirasGrowingTextField(text: textBinding, placeholder: placeholder, maxLines: maxLines,
                    pointSize: pointSize, palette: p, isFocused: focused,
                    sendOnReturn: sendOnReturn, onSubmit: onSubmit, onKey: handleKey,
                    selection: Binding(get: { draft.selection }, set: { draft.selection = $0 }),
                    highlightedRanges: draft.mentions.map(\.range),
                    onLargePaste: pasteCharacterBudget != nil ? paste : nil)
                    .frame(minHeight: 44).bidiIsland(for: text, fallback: lang)
            }
            .task(id: token != nil) { if token != nil { await env.skills.load() } }
            .firasOnChange(of: text) { _, value in draft.synchronize(value) }
            .firasOnChange(of: env.skills.skills) { _, skills in draft.retainValid(skills: skills, text: text) }
            .firasOnChange(of: env.session.identityID) { _, _ in draft.reset() }
            .onAppear { draft.synchronize(text) }
            .sheet(item: $preview) { item in PastedTextPreview(item: item, palette: p, lang: lang) }
            .sheet(isPresented: $showsLibrary) {
                FirasNavigationStack {
                    SkillsSettingsView(env: env) { skill in
                        showsLibrary = false
                        guard let saved = libraryToken else { return }
                        pick(skill, token: saved)
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button(Strings.Common.close(lang)) { showsLibrary = false }
                    } }
                }.tint(p.accent).preferredColorScheme(env.prefs.theme.isLight ? .light : .dark)
                    .firasSheetBackground(p)
            }
        }
    }
    private func paste(_ text: String) -> Bool {
        let used = draft.pastes.reduce(0) { $0 + $1.text.utf16.count }
        guard draft.pastes.count < pasteSlots, text.utf16.count <= min(120_000, (pasteCharacterBudget ?? 0) - used) else {
            env.toasts.show(LText(ar: "النص أكبر من المساحة المتبقية للمرفقات. قلّله أو أرفقه كملف؛ النص الأصلي يبقى بالحافظة.", en: "This paste exceeds the remaining attachment space. Shorten it or attach a file; the original stays on your clipboard.")(lang), isError: true)
            return true
        }
        draft.pastes.append(PastedTextItem(text: text, number: draft.pastes.count + 1))
        Haptics.attach()
        return true
    }
    private func menu(_ token: SkillSlashToken) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(SkillsCopy.title(lang)).font(.caption.weight(.semibold)).foregroundStyle(p.textMuted)
                Spacer()
                Text("\(draft.mentions.count)/3").font(.caption.monospacedDigit()).foregroundStyle(p.accent)
                Button { draft.dismissedStart = token.range.location } label: { Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44) }
                    .accessibilityLabel(Strings.Common.close(lang))
            }.padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 2) {
                    if env.skills.loading { ProgressView().padding(10) }
                    if !env.session.isMember {
                        Text(SkillsCopy.signIn(lang)).font(.footnote).foregroundStyle(p.textMuted).padding(12)
                    } else if env.skills.failure != nil {
                        Button(LText(ar: "إعادة تحميل المهارات", en: "Reload skills")(lang)) { Task { await env.skills.load(force: true) } }.frame(minHeight: 44)
                    }
                    ForEach(Array(available.enumerated()), id: \.element.id) { index, skill in
                        row(skill.name, hint: skill.cues.prefix(2).joined(separator: " · "), symbol: "sparkles", selected: draft.highlighted == index) { pick(skill, token: token) }
                            .disabled(draft.mentions.count >= 3)
                    }
                    if draft.mentions.count >= 3 { Text(SkillsCopy.limit(lang)).font(.caption).foregroundStyle(p.textMuted).padding(10) }
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        row(command.label(lang), hint: command.hint(lang), symbol: command.symbol,
                            selected: draft.highlighted == available.count + index) { pick(command, token: token) }
                    }
                    if available.isEmpty && commands.isEmpty { Text(SkillsCopy.noResults(lang)).font(.subheadline).foregroundStyle(p.textMuted).padding(12) }
                }.padding(.horizontal, 6)
            }.frame(maxHeight: draft.pastes.isEmpty ? 230 : 150)
            Divider().overlay(p.border)
            Button {
                libraryToken = token; showsLibrary = true
            } label: { Label(SkillsCopy.browse(lang), systemImage: "books.vertical").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44) }
        }
        .firasGlass(.sheet, palette: p, in: FirasAnyShape(RoundedRectangle(cornerRadius: 20)))
        .bidiIsland(for: SkillsCopy.title(lang), fallback: lang)
        .accessibilityIdentifier("skill-slash-menu")
    }
    private func row(_ title: String, hint: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(p.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(p.textPrimary).lineLimit(2)
                    Text(hint).font(.caption).foregroundStyle(p.textMuted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 50)
                .background(selected ? p.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).multilineTextAlignment(.leading).bidiIsland(for: title, fallback: lang)
    }
    private func pick(_ skill: AccountSkill, token: SkillSlashToken) {
        guard let value = draft.insert(skill, token: token, into: text) else { return }
        text = value; focused.wrappedValue = true; Haptics.select()
    }
    private func pick(_ command: SlashCommand, token: SkillSlashToken) {
        guard SkillSlashToken.scan(text, selection: draft.selection) == token else { return }
        let value = (text as NSString).replacingCharacters(in: token.range, with: command.promptBody(lang))
        draft.synchronize(value); text = value
        draft.selection = NSRange(location: token.range.location + command.promptBody(lang).utf16.count, length: 0)
        focused.wrappedValue = true; Haptics.select()
    }
    private func handleKey(_ key: ComposerKey) -> Bool {
        guard let token else { return false }
        let count = available.count + commands.count
        switch key {
        case .up: draft.highlighted = max(0, draft.highlighted - 1)
        case .down: draft.highlighted = min(max(0, count - 1), draft.highlighted + 1)
        case .escape: draft.dismissedStart = token.range.location
        case .accept:
            guard count > 0 else { return false }
            if draft.highlighted < available.count { pick(available[draft.highlighted], token: token) }
            else { let index = draft.highlighted - available.count; if commands.indices.contains(index) { pick(commands[index], token: token) } }
        }
        return true
    }
}
