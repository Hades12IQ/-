import SwiftUI
import Perception

struct CodeModelPicker: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var access = false
    @State private var error: String?
    private var lang: AppLanguage { env.prefs.lang }
    var body: some View {
        WithPerceptionTracking {
            FirasNavigationStack {
                List {
                    ForEach(ModelGeneration.allCases.reversed()) { generation in
                      Section(header: Text(generation == .current
                        ? (lang == .arabic ? "النماذج الأساسية" : "Primary models")
                        : (lang == .arabic ? "نماذج أخرى" : "Other models"))) {
                      ForEach(ModelTier.allCases.reversed()) { tier in
                        WithPerceptionTracking {
                            Button {
                                Task { await select(tier, generation: generation) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: tier.symbol).frame(width: 24).foregroundStyle(env.prefs.palette.accent)
                                    Text(generation.label(tier, lang)).foregroundStyle(env.prefs.palette.textPrimary)
                                    Spacer()
                                    if env.code.modelSelection.model == tier && env.code.modelSelection.generation == generation { Image(systemName: "checkmark").foregroundStyle(env.prefs.palette.accent) }
                                }.frame(minHeight: 44)
                            }.disabled(checking || env.code.codeOmnix.active.contains(env.code.openProjectID ?? ""))

                            }
                    }
                      }
                    }
                    if env.code.modelSelection.model.showThinking {
                        Toggle(lang == .arabic ? "تفكير أعمق" : "Deeper thinking", isOn: Binding(
                            get: { env.code.modelSelection.think },
                            set: { env.code.selectModel(CodeModelSelection(model: env.code.modelSelection.model, depth: $0 ? "deep" : "standard", generation: env.code.modelSelection.generation)) }
                        ))
                    }
                    if checking { ProgressView().frame(maxWidth: .infinity) }
                    if let error { Text(error).font(.footnote).foregroundStyle(env.prefs.palette.error) }
                    Button(lang == .arabic ? "الوصول إلى أومنكس" : "Omnix access") { access = true }.frame(minHeight: 44)
                }
                .firasScrollContentBackground(.hidden)
                .background(env.prefs.palette.background)
                .navigationTitle(lang == .arabic ? "نموذج فراس كود" : "Firas Code model")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { WithPerceptionTracking {
                    Button(Strings.Common.done(lang)) { dismiss() }
                    } } }
                .sheet(isPresented: $access) { WithPerceptionTracking {
                    OmnixAccessView(env: env)
                    } }
            }.tint(env.prefs.palette.accent).firasSheetBackground(env.prefs.palette)

            }
    }
    private func select(_ tier: ModelTier, generation: ModelGeneration) async {
        guard !checking, let projectID = env.code.openProjectID else { return }
        let owner = env.session.identityID
        if tier == .omnix {
            checking = true; error = nil
            defer { checking = false }
            do {
                guard env.session.isMember else { throw APIError.cancelled }
                let access = try await OmnixService.access(api: env.api)
                guard env.session.identityID == owner, access.status == "approved" else { throw APIError.cancelled }
                let cloud = try await OmnixService.cloud(api: env.api)
                guard env.session.identityID == owner, env.code.openProjectID == projectID, cloud.ready, cloud.state == "ready" else { throw APIError.cancelled }
            } catch { self.error = OmnixCopy.unavailable(lang); return }
        }
        guard env.session.identityID == owner, env.code.openProjectID == projectID else { return }
        env.code.selectModel(CodeModelSelection(model: tier, generation: generation))
        dismiss()
    }
}
