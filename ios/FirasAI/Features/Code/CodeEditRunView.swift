import SwiftUI
import Perception

struct CodeEditRunView: View {
    let turn: CodeChatMessage
    let receipt: CodeEditReceipt
    let env: AppEnvironment
    @State private var plan: CodeEditPlan?
    @State private var preparing = false
    private var lang: AppLanguage { env.prefs.lang }
    private var state: CodeOmnixState { env.code.codeOmnix }
    private var status: ChatJobStatus? { state.edits[receipt.cid] }
    private var owns: Bool { env.session.identityID == receipt.owner && env.code.openProjectID == receipt.conversationId }
    var body: some View {
        WithPerceptionTracking {
                if owns {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(ModelGeneration.history(turn.mgen).label(ModelTier.lenient(turn.model), lang)).font(.caption.weight(.semibold)).foregroundStyle(env.prefs.palette.accent)
                            Spacer()
                            if !CodeStore.editIsTerminal(status?.phase ?? turn.editPhase) { ProgressView().controlSize(.small) }
                        }
                        ForEach(ExecutionStep.merge(turn.steps, status?.steps ?? []) ?? []) { step in
                            ExecutionStepRow(step: step, lang: lang, palette: env.prefs.palette,
                                streaming: !CodeStore.editIsTerminal(status?.phase ?? turn.editPhase))
                        }
                        if !turn.content.isEmpty {
                            MarkdownView(markdown: turn.content, messageID: "code-edit-" + turn.id, streaming: false, lang: lang,
                                palette: env.prefs.palette, prefs: env.prefs, onFence: { _ in nil })
                        } else {
                            Text(lang == .arabic ? "المهمة محفوظة وتستمر على الخادم." : "The saved task continues on the server.")
                                .font(.subheadline).foregroundStyle(env.prefs.palette.textSecondary)
                        }
                        if let notice = state.notices[receipt.cid] { Text(notice).font(.footnote).foregroundStyle(env.prefs.palette.textMuted) }
                        HStack {
                            if (status?.phase ?? turn.editPhase) == "completed" {
                                Button(lang == .arabic ? "مراجعة التغييرات" : "Review changes") { Task { await review() } }
                                    .frame(minHeight: 44).disabled(preparing)
                            }
                            Button(lang == .arabic ? "تحديث" : "Refresh") { Task { await env.code.refreshCodeEdit(receipt) } }.frame(minHeight: 44)
                            Spacer()
                            if !CodeStore.editIsTerminal(status?.phase ?? turn.editPhase) {
                                Button(Strings.Common.stop(lang), role: .destructive) { Task { await env.code.stopCodeEdit(receipt) } }
                                    .frame(minHeight: 44).disabled(state.stopping.contains(receipt.cid))
                            }
                            if preparing { ProgressView().controlSize(.small) }
                        }.font(.subheadline)
                    }.padding(.vertical, 10).tint(env.prefs.palette.accent).foregroundStyle(env.prefs.palette.textPrimary)
                        .task(id: receipt.cid) { await env.code.refreshCodeEdit(receipt) }
                        .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
                            WithPerceptionTracking {
                                    if let plan { DiffReviewSheet(env: env, plan: plan) }

                                    }
                        }
                        .firasOnChange(of: env.session.identityID) { _, value in if value != receipt.owner { plan = nil } }
                }

                }
    }
    private func review() async {
        guard owns, !preparing, let source = env.code.project else { return }
        let generation = state.generation
        preparing = true; defer { preparing = false }
        await env.code.refreshCodeEdit(receipt)
        guard owns, state.generation == generation, env.code.project == source, let current = state.edits[receipt.cid], current.phase == "completed" else { return }
        do {
            var result = try CodeEditService.proposal(text: current.text, source: source, expectedBaseHash: receipt.baseHash)
            result.sourceProject = source; result.sourceProjectID = receipt.conversationId; result.sourceOwnerID = receipt.owner
            if result.isEmpty { env.toasts.show(Strings.Code.noChanges(lang)) }
            else { plan = result }
        } catch {
            env.toasts.show(lang == .arabic ? "تغيّر المشروع أو تعذّر التحقق من المقترح. أرسل طلبًا جديدًا على الملفات الحالية." : "The project changed or the proposal could not be verified. Send a new request against the current files.", isError: true)
        }
    }
}
