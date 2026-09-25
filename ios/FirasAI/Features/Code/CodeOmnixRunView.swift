import SwiftUI
import Perception
import QuickLook

struct CodeOmnixRunView: View {
    let turn: CodeChatMessage
    let receipt: OmnixReceipt
    let env: AppEnvironment
    @State private var expanded = false
    @State private var preview: OmnixFile?
    @State private var plan: CodeEditPlan?
    @State private var reviewing = false
    private var ar: Bool { env.prefs.lang == .arabic }
    private var state: CodeOmnixState { env.code.codeOmnix }
    private var job: OmnixJob? { state.jobs[receipt.requestKey] }
    private var owns: Bool { env.session.identityID == receipt.owner && env.code.openProjectID == receipt.conversationId }
    var body: some View {
        WithPerceptionTracking {
            if owns {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: job?.state == "completed" ? "checkmark.circle" : job?.state == "failed" ? "exclamationmark.circle" : "sparkles")
                            .foregroundStyle(env.prefs.palette.accent)
                        Text(ModelGeneration.history(turn.mgen).label(.omnix, env.prefs.lang)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(statusText).font(.caption).foregroundStyle(env.prefs.palette.textMuted)
                    }
                    if let notice = state.notices[receipt.requestKey] { Text(notice).font(.footnote).foregroundStyle(env.prefs.palette.textSecondary) }
                    if let approval = job?.result?.approval {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(approval.reason).font(.subheadline)
                            ScrollView(.horizontal) { Text(approval.command).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                                .environment(\.layoutDirection, .leftToRight)
                            HStack {
                                Button(ar ? "رفض" : "Deny", role: .destructive) { approve(approval, choice: "deny") }.frame(minHeight: 44)
                                Spacer()
                                Button(ar ? "السماح مرة واحدة" : "Allow once") { approve(approval, choice: "once") }
                                    .frame(minHeight: 44).disabled(!approval.commandComplete || !approval.choices.contains("once"))
                            }.disabled(state.approvalBusy.contains(receipt.requestKey) || state.notices[receipt.requestKey] != nil)
                        }.padding(12).background(env.prefs.palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    let text = job?.visibleText.isEmpty == false ? job!.visibleText : turn.content
                    OmnixActivityView(progress: job?.progress, output: text, identity: "code-omnix-" + turn.id,
                        streaming: job.map { !$0.isTerminal } ?? false, prefs: env.prefs)
                    if job?.state == "completed", job?.result?.filesStatus == "ready", let files = job?.result?.files, !files.isEmpty {
                        ForEach(files.filter { $0.downloadPath != nil }) { file in
                            WithPerceptionTracking {
                                Button { preview = file } label: {
                                    Label(file.name, systemImage: "doc").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }

                                }
                        }
                        Button {
                            Task { await prepareReview() }
                        } label: {
                            HStack { if reviewing { ProgressView() }; Text(ar ? "مراجعة الملفات في المحرر" : "Review files in editor") }.frame(minHeight: 44)
                        }.disabled(reviewing)
                    }
                    HStack {
                        Button(ar ? "تحديث" : "Refresh") { Task { await env.code.refreshCodeOmnix(receipt) } }.frame(minHeight: 44)
                        Spacer()
                        if receipt.submission != "not_admitted", job?.isTerminal != true {
                            Button(ar ? "إيقاف" : "Stop", role: .destructive) { Task { await env.code.stopCodeOmnix(receipt) } }
                                .frame(minHeight: 44).disabled(state.stopping.contains(receipt.requestKey))
                        }
                    }.font(.subheadline)
                }
                .padding(.vertical, 10).foregroundStyle(env.prefs.palette.textPrimary).tint(env.prefs.palette.accent)
                .task(id: receipt.requestKey) { await env.code.refreshCodeOmnix(receipt) }
                .sheet(item: $preview) { file in WithPerceptionTracking {
                    OmnixFileView(file: file, owner: receipt.owner, env: env)
                    } }
                .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
                    WithPerceptionTracking {
                        if let plan { DiffReviewSheet(env: env, plan: plan) }

                        }
                }
                .firasOnChange(of: env.session.identityID) { _, owner in if owner != receipt.owner { plan = nil; preview = nil } }
            }

            }
    }
    private var statusText: String {
        if receipt.submission == "not_admitted" { return ar ? "لم تبدأ" : "Not started" }
        switch job?.state {
        case "completed": return ar ? "اكتملت" : "Completed"
        case "failed": return ar ? "لم تكتمل" : "Failed"
        case "cancelled", "canceled", "interrupted": return ar ? "متوقفة" : "Stopped"
        default: return ar ? "جارٍ العمل" : "Working"
        }
    }
    private func approve(_ approval: OmnixApproval, choice: String) {
        Task { await env.code.approveCodeOmnix(receipt, approval: approval, choice: choice) }
    }
    private func prepareReview() async {
        guard owns, !reviewing, let source = env.code.project else { return }
        let generation = state.generation
        reviewing = true
        defer { reviewing = false }
        do {
            var result = try await CodeOmnixImport.load(receipt: receipt, source: source, api: env.api, isCurrent: {
                owns && state.generation == generation && env.code.project == source
            })
            guard owns, state.generation == generation, env.code.project == source else { return }
            result.sourceProject = source; result.sourceProjectID = receipt.conversationId; result.sourceOwnerID = receipt.owner
            plan = result
        } catch {
            if owns { env.toasts.show(ar ? "تعذّر تجهيز مراجعة الملفات. حدّث المهمة وتأكد أن المشروع لم يتغيّر." : "File review could not be prepared. Refresh the task and check that the project has not changed.", isError: true) }
        }
    }
}

private struct CodeOmnixPreview: View {
    let file: OmnixFile
    let owner: String
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var failed = false
    @State private var save = false
    @State private var share = false
    var body: some View {
        WithPerceptionTracking {
            FirasNavigationStack {
                Group {
                    if let url { CodeOmnixQuickLook(url: url) }
                    else if failed { Text(env.prefs.lang == .arabic ? "تعذّر فتح الملف." : "The file could not open.") }
                    else { ProgressView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(env.prefs.palette.background)
                    .navigationTitle(URL(fileURLWithPath: file.name).lastPathComponent).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { WithPerceptionTracking {
                            Button(Strings.Common.close(env.prefs.lang)) { dismiss() }
                            } }
                        ToolbarItem(placement: .primaryAction) {
                            WithPerceptionTracking {
                                if let url {
                                    HStack {
                                        Button { share = true } label: { Image(systemName: "square.and.arrow.up") }
                                            .accessibilityLabel(Strings.Common.share(env.prefs.lang))
                                        Button { save = true } label: { Image(systemName: "folder.badge.plus") }
                                    }
                                }

                                }
                        }
                    }
            }
            .task {
                guard env.session.identityID == owner else { return }
                do {
                    let downloaded = try await OmnixService.download(file, api: env.api)
                    guard env.session.identityID == owner, !Task.isCancelled else { try? FileManager.default.removeItem(at: downloaded); return }
                    url = downloaded
                } catch { failed = true }
            }
            .firasOnChange(of: env.session.identityID) { _, value in
                if value != owner { if let url { try? FileManager.default.removeItem(at: url) }; url = nil; dismiss() }
            }
            .sheet(isPresented: $save) { WithPerceptionTracking {
                if let url { FirasFileSaver(url: url) { _ in save = false } }
                } }
            .sheet(isPresented: $share) {
                WithPerceptionTracking {
                        if let url, env.session.identityID == owner { CodeWorkspaceShareSheet(url: url) }
                    }
            }

            }
    }
}
private struct CodeOmnixQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let view = QLPreviewController(); view.dataSource = context.coordinator; return view
    }
    func updateUIViewController(_ view: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
