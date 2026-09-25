import SwiftUI
import Perception

@MainActor
struct SkillsSettingsView: View {
    let env: AppEnvironment
    var onUse: ((AccountSkill) -> Void)? = nil
    @State private var tab = 0
    @State private var query = ""
    @State private var domain = ""
    @State private var catalogue: SkillLibraryResponse?
    @State private var libraryLoading = false
    @State private var libraryFailure = false
    @State private var editor: AccountSkill?
    @State private var deleting: AccountSkill?
    @State private var retry = 0
    @State private var importURL = ""
    @State private var importFailure: String?
    private var p: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var store: AccountSkillsStore { env.skills }

    init(env: AppEnvironment, initialLibrary: Bool = false, onUse: ((AccountSkill) -> Void)? = nil) {
        self.env = env; self.onUse = onUse
        _tab = State(initialValue: initialLibrary ? 1 : 0)
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    if env.session.isMember {
                        Picker(SkillsCopy.title(lang), selection: $tab) {
                            Text(SkillsCopy.mine(lang)).tag(0)
                            Text(SkillsCopy.library(lang)).tag(1)
                        }.pickerStyle(.segmented)
                        search
                        if tab == 0 { importPanel; mySkills } else { library }
                    } else {
                        Text(SkillsCopy.signIn(lang)).foregroundStyle(p.textSecondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(p.background)
            .navigationTitle(SkillsCopy.title(lang))
            .navigationBarTitleDisplayMode(.inline)
            .tint(p.accent)
            .task(id: env.session.identityID) { await store.load(force: true) }
            .task(id: "\(tab)|\(query)|\(domain)|\(retry)|\(env.session.identityID ?? "guest")") { await loadLibrary() }
            .refreshable { await store.load(force: true); retry += 1 }
            .sheet(item: $editor) { skill in
                SkillEditorView(env: env, skill: skill) { saved in
                    if onUse != nil { onUse?(saved) }
                }
            }
            .alert(LText(ar: "حذف المهارة؟", en: "Delete skill?")(lang), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(Strings.Common.cancel(lang), role: .cancel) { deleting = nil }
                Button(LText(ar: "حذف", en: "Delete")(lang), role: .destructive) {
                    guard let skill = deleting else { return }; deleting = nil
                    Task { await store.delete(skill) }
                }
            } message: { Text(LText(ar: "تنحذف من حسابك بالتطبيق والموقع.", en: "This removes the skill from your account in the app and on the website.")(lang)) }
        }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lang == .arabic ? "استيراد مهارة من رابط" : "Import a skill from a link")
                .font(.subheadline.weight(.semibold)).foregroundStyle(p.textPrimary)
            TextField("https://…/SKILL.md", text: $importURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true)
                .textFieldStyle(.plain).padding(12).background(p.surface, in: RoundedRectangle(cornerRadius: 12))
                .environment(\.layoutDirection, .leftToRight)
            Button {
                let submitted = importURL
                Task {
                    do {
                        _ = try await store.importSkill(url: submitted)
                        if importURL == submitted { importURL = "" }
                        importFailure = nil
                    } catch {
                        let code = AccountSkillsStore.code(error)
                        switch code {
                        case "unsupported_url", "url_required": importFailure = lang == .arabic ? "أدخل رابط HTTPS لملف المهارة أو مستودع GitHub." : "Enter an HTTPS skill file or GitHub repository link."
                        case "not_reachable": importFailure = lang == .arabic ? "تعذّر قراءة الرابط. جرّب رابط SKILL.md المباشر." : "The link could not be read. Try the direct SKILL.md link."
                        case "not_a_skill": importFailure = lang == .arabic ? "الملف لا يحتوي اسم مهارة وتعليماتها." : "This file has no skill name and instructions."
                        default: importFailure = lang == .arabic ? "تعذّر الاستيراد. راجع الرابط وحدود المهارات ثم حاول مجددًا." : "Import failed. Check the link and skill limits, then retry."
                        }
                    }
                }
            } label: {
                HStack { if store.mutating { ProgressView() }; Text(lang == .arabic ? "استيراد" : "Import") }
                    .frame(minHeight: 44)
            }.disabled(store.mutating || importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let importFailure { Text(importFailure).font(.footnote).foregroundStyle(p.error) }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(p.accent)
                    .frame(width: 54, height: 54)
                    .firasGlass(.floating, palette: p, in: FirasAnyShape(RoundedRectangle(cornerRadius: 17)))
                VStack(alignment: .leading, spacing: 5) {
                    Text(SkillsCopy.title(lang)).font(.system(size: 25, weight: .bold)).foregroundStyle(p.textPrimary)
                    Text(SkillsCopy.subtitle(lang)).font(.subheadline).foregroundStyle(p.textSecondary)
                }
            }
            Text(SkillsCopy.slashHint(lang)).font(.footnote).foregroundStyle(p.textMuted)
        }.bidiIsland(for: SkillsCopy.title(lang), fallback: lang)
    }
    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(p.textMuted)
            TextField(SkillsCopy.search(lang), text: $query).textFieldStyle(.plain)
                .foregroundStyle(p.textPrimary).disableAutocorrection(true)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(LText(ar: "مسح البحث", en: "Clear search")(lang))
            }
        }.padding(.horizontal, 14).frame(minHeight: 50)
            .firasGlass(.floating, palette: p, in: FirasAnyShape(RoundedRectangle(cornerRadius: 16)))
            .bidiIsland(for: query.isEmpty ? SkillsCopy.search(lang) : query, fallback: lang)
    }
    private var filtered: [AccountSkill] {
        let key = SkillSearch.fold(query)
        return store.skills.filter { key.isEmpty || SkillSearch.fold($0.name + " " + $0.cues.joined(separator: " ")).contains(key) }
    }
    private var mySkills: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(store.skills.count) / 40").font(.caption.monospacedDigit()).foregroundStyle(p.textMuted)
                Spacer()
                Button { editor = AccountSkill(id: "", name: "", cues: [], rules: []) } label: {
                    Label(SkillsCopy.add(lang), systemImage: "plus").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }.disabled(store.mutating || store.skills.count >= 40)
            }
            if let failure = store.failure { errorRow(SkillsCopy.problem(failure, lang)) { Task { await store.load(force: true) } } }
            if store.loading && !store.loaded { ProgressView().frame(maxWidth: .infinity).padding(30) }
            else if filtered.isEmpty {
                emptyState(title: query.isEmpty ? SkillsCopy.empty(lang) : SkillsCopy.noResults(lang), hint: query.isEmpty ? SkillsCopy.emptyHint(lang) : "")
                if query.isEmpty { Button(SkillsCopy.browse(lang)) { tab = 1 }.frame(minHeight: 44) }
            }
            ForEach(filtered) { skill in WithPerceptionTracking { skillRow(skill) } }
        }
    }
    private func skillRow(_ skill: AccountSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(skill.enabled ? p.accent : p.textMuted).frame(width: 24, height: 30)
                Button { editor = skill } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(skill.name).font(.headline).foregroundStyle(p.textPrimary).multilineTextAlignment(.leading)
                        Text(skill.cues.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(p.textMuted).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                }.buttonStyle(.plain)
                Menu {
                    Button(SkillsCopy.edit(lang)) { editor = skill }
                    Button(skill.enabled ? SkillsCopy.disabled(lang) : SkillsCopy.enabled(lang)) { Task { await store.toggle(skill) } }
                    Button(LText(ar: "حذف", en: "Delete")(lang), role: .destructive) { deleting = skill }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .disabled(store.mutating).accessibilityLabel(SkillsCopy.edit(lang))
            }
            HStack {
                Text(skill.enabled ? (skill.mode == "always" ? SkillsCopy.always(lang) : SkillsCopy.auto(lang)) : SkillsCopy.disabled(lang))
                    .font(.caption.weight(.medium)).foregroundStyle(skill.enabled ? p.accent : p.textMuted)
                Spacer()
                if let onUse, skill.enabled {
                    Button(SkillsCopy.use(lang)) { onUse(skill) }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
            }
        }.padding(16).bidiIsland(for: skill.name, fallback: lang)
            .firasGlass(.floating, palette: p, in: FirasAnyShape(RoundedRectangle(cornerRadius: 20)))
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !domain.isEmpty && query.isEmpty {
                    Button { domain = "" } label: { Label(LText(ar: "كل الأقسام", en: "All sections")(lang), systemImage: "square.grid.2x2").frame(minHeight: 44) }
                }
                Spacer()
                Text("\(catalogue?.origin ?? "Mentronx") · \(catalogue?.total ?? 0)").font(.caption).foregroundStyle(p.textMuted)
            }
            if libraryLoading { ProgressView().frame(maxWidth: .infinity).padding(30) }
            else if libraryFailure { errorRow(SkillsCopy.problem("unavailable", lang)) { retry += 1 } }
            else if let catalogue {
                ForEach(catalogue.sections ?? []) { section in
                    Button { domain = section.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(p.accent).frame(width: 28)
                            Text(section.title).font(.body.weight(.medium)).foregroundStyle(p.textPrimary).multilineTextAlignment(.leading)
                            Spacer(minLength: 5)
                            Text("\(section.count)").font(.caption.monospacedDigit()).foregroundStyle(p.textMuted)
                            Image(systemName: "chevron.forward").font(.caption).foregroundStyle(p.textMuted)
                        }.padding(16).frame(minHeight: 62)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).bidiIsland(for: section.title, fallback: lang)
                }
                ForEach(catalogue.library ?? []) { item in
                    Button { editor = item.editableCopy } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.name).font(.headline).foregroundStyle(p.textPrimary)
                            Text(item.section).font(.caption).foregroundStyle(p.accent)
                            Text(item.rules.first ?? "").font(.subheadline).foregroundStyle(p.textSecondary).lineLimit(3)
                            Label(SkillsCopy.addFromLibrary(lang), systemImage: "plus").font(.caption.weight(.semibold)).foregroundStyle(p.accent).padding(.top, 4)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).multilineTextAlignment(.leading).bidiIsland(for: item.name, fallback: lang)
                }
                if (catalogue.sections ?? []).isEmpty && (catalogue.library ?? []).isEmpty { emptyState(title: SkillsCopy.noResults(lang), hint: "") }
            }
        }
    }
    private func emptyState(title: String, hint: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(p.accent)
            Text(title).font(.headline).foregroundStyle(p.textPrimary)
            if !hint.isEmpty { Text(hint).font(.subheadline).foregroundStyle(p.textMuted).multilineTextAlignment(.center) }
        }.padding(.vertical, 28).frame(maxWidth: .infinity).bidiIsland(for: title, fallback: lang)
    }
    private func errorRow(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.subheadline).foregroundStyle(p.textSecondary)
            Button(LText(ar: "إعادة المحاولة", en: "Try again")(lang), action: retry).frame(minHeight: 44)
        }.bidiIsland(for: message, fallback: lang)
    }
    private func loadLibrary() async {
        guard tab == 1, env.session.isMember else { catalogue = nil; return }
        libraryLoading = true; libraryFailure = false; catalogue = nil
        do {
            try await Task.sleep(nanoseconds: query.isEmpty ? 0 : 250_000_000)
            let response = try await store.library(query: query.trimmingCharacters(in: .whitespacesAndNewlines), domain: domain)
            try Task.checkCancellation()
            catalogue = response; libraryLoading = false
        } catch {
            if !Task.isCancelled { libraryFailure = true; libraryLoading = false }
        }
    }
}
