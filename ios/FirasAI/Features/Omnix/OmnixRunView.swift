import SwiftUI
import QuickLook

/// Observed server steps and authenticated files; it never invents a plan or a percentage.
struct OmnixRunView: View {
    let receipt: OmnixReceipt
    let conversationID: String
    let env: AppEnvironment
    @State private var expanded = false
    @State private var previewFile: OmnixFile?
    private var state: OmnixState { env.chat.pipeline.omnixState }
    private var lang: AppLanguage { env.prefs.lang }
    private var ar: Bool { lang == .arabic }
    private var job: OmnixJob? { state.owner == receipt.owner ? state.jobs[receipt.requestKey] : nil }
    private var steps: [OmnixStep] { (job?.progress?.plan ?? []).filter { $0.observed == true } }
    private var savedText: String {
        env.chat.conversation(conversationID)?.messages.first { $0.omnix?.requestKey == receipt.requestKey }?.content ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if env.session.identityID == receipt.owner {
                if receipt.submission != "not_admitted" {
                    HStack(spacing: 8) {
                        Image(systemName: statusIcon)
                        Text(statusLabel).font(.subheadline.weight(.medium))
                        Spacer(minLength: 8)
                        if let job, !job.isTerminal, let start = job.progress?.startedAt ?? job.createdAt, start > 0 {
                            Text(Date(timeIntervalSince1970: start / 1000), style: .timer)
                                .font(.caption.monospacedDigit()).environment(\.layoutDirection, .leftToRight)
                        }
                    }
                    .foregroundStyle(env.prefs.palette.textSecondary)
                    if let notice = state.notices[receipt.requestKey] { Text(notice).font(.footnote).foregroundStyle(env.prefs.palette.textMuted) }
                    if !steps.isEmpty {
                        DisclosureGroup(isExpanded: $expanded) {
                            ForEach(steps) { step in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top) {
                                        Image(systemName: stepIcon(step.s))
                                        Text(step.title).font(.subheadline.monospaced()).textSelection(.enabled)
                                        Spacer(minLength: 0)
                                        Text(stepLabel(step.s)).font(.caption)
                                    }
                                    if let input = step.inputPreview, !input.isEmpty {
                                        Text(input).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                    if let result = step.resultPreview, !result.isEmpty {
                                        Text(result).font(.caption).foregroundStyle(env.prefs.palette.textMuted).textSelection(.enabled)
                                    }
                                }.padding(.vertical, 7)
                            }
                        } label: {
                            Text((ar ? "سجل التنفيذ" : "Execution activity") + " · " + String(steps.count))
                                .font(.subheadline)
                        }
                        .tint(env.prefs.palette.accent)
                    }
                    if job?.state == "waiting_for_approval", let approval = job?.result?.approval {
                        approvalView(approval)
                    }
                }
                let output = job?.visibleText.isEmpty == false ? job!.visibleText : savedText
                if !output.isEmpty {
                    MarkdownView(markdown: output, messageID: "omnix-" + receipt.requestKey,
                        streaming: job.map { !$0.isTerminal } ?? false, lang: lang, palette: env.prefs.palette,
                        prefs: env.prefs, onFence: { _ in nil })
                }
                ForEach((job?.result?.files ?? []).filter { $0.downloadPath != nil }) { file in
                    Button { previewFile = file } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: file.name).lastPathComponent).lineLimit(2)
                                if let size = file.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right.square")
                        }.padding(12).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .background(env.prefs.palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel((ar ? "فتح الملف " : "Open file ") + file.name)
                }
                if job?.result?.filesStatus == "unavailable" {
                    Text(ar ? "جارٍ التحقق من ملفات المهمة…" : "Checking the task’s files…").font(.footnote)
                }
                if job == nil && receipt.submission != "not_admitted" || state.notices[receipt.requestKey] != nil {
                    Button(ar ? "تحديث الحالة" : "Refresh status") {
                        Task { await env.chat.pipeline.refreshOmnixReceipt(receipt, in: conversationID); env.chat.pipeline.restoreOmnix(in: conversationID) }
                    }.frame(minHeight: 44)
                }
            } else {
                Text(ar ? "هذه المهمة تخص حسابًا آخر." : "This task belongs to another account.")
            }
        }
        .foregroundStyle(env.prefs.palette.textPrimary)
        .task(id: receipt.jobId) {
            await env.chat.pipeline.refreshOmnixReceipt(receipt, in: conversationID)
            env.chat.pipeline.restoreOmnix(in: conversationID)
        }
        .sheet(item: $previewFile) { file in OmnixFileView(file: file, owner: receipt.owner, env: env) }
    }

    private var statusIcon: String {
        switch job?.state {
        case "completed": "checkmark.circle"
        case "failed", "interrupted": "exclamationmark.circle"
        case "cancelled", "canceled": "stop.circle"
        case "waiting_for_approval": "hand.raised"
        default: "sparkle"
        }
    }
    private var statusLabel: String {
        switch job?.state {
        case "completed": return ar ? "اكتملت المهمة" : "Task completed"
        case "failed", "interrupted": return ar ? "توقّفت المهمة قبل الاكتمال" : "Task ended before completion"
        case "cancelled", "canceled": return ar ? "تم إيقاف المهمة" : "Task stopped"
        case "waiting_for_approval": return ar ? "بانتظار موافقتك" : "Waiting for your approval"
        case "running": return ar ? "أومنكس يعمل" : "Omnix is working"
        case "stopping": return ar ? "جارٍ الإيقاف…" : "Stopping…"
        default: return OmnixCopy.checking(lang)
        }
    }
    private func stepIcon(_ value: String) -> String {
        switch value { case "done": "checkmark"; case "run": "circle.dotted"; case "fail": "xmark"; default: "questionmark" }
    }
    private func stepLabel(_ value: String) -> String {
        switch value {
        case "done": ar ? "اكتملت" : "Completed"
        case "run": ar ? "يجري الآن" : "In progress"
        case "fail": ar ? "لم تنجح" : "Failed"
        default: ar ? "غير مؤكدة" : "Unconfirmed"
        }
    }
    private func approvalView(_ approval: OmnixApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.reason).font(.subheadline)
            ScrollView(.horizontal) { Text(approval.command).font(.caption.monospaced()).textSelection(.enabled) }
                .environment(\.layoutDirection, .leftToRight)
            HStack {
                Button(ar ? "رفض" : "Deny", role: .destructive) {
                    Task { await env.chat.pipeline.approveOmnix(receipt, approval: approval, choice: "deny", in: conversationID) }
                }.frame(minHeight: 44)
                Spacer()
                Button(ar ? "السماح مرة واحدة" : "Allow once") {
                    Task { await env.chat.pipeline.approveOmnix(receipt, approval: approval, choice: "once", in: conversationID) }
                }.frame(minHeight: 44).disabled(!approval.commandComplete || !approval.choices.contains("once"))
            }.disabled(state.approvalBusy.contains(receipt.requestKey) || state.notices[receipt.requestKey] != nil)
        }.padding(12).background(env.prefs.palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct OmnixFileView: View {
    let file: OmnixFile
    let owner: String
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var failed = false
    @State private var save = false
    var body: some View {
        NavigationStack {
            Group {
                if let url { OmnixQuickLook(url: url) }
                else if failed { Text(env.prefs.lang == .arabic ? "تعذّر فتح الملف. حاول مجددًا." : "The file could not open. Try again.") }
                else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(env.prefs.palette.background)
            .navigationTitle(URL(fileURLWithPath: file.name).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Strings.Common.close(env.prefs.lang)) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let url {
                        HStack {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            Button { save = true } label: { Image(systemName: "folder.badge.plus") }
                        }
                    }
                }
            }
        }
        .task {
            guard env.session.identityID == owner else { failed = true; return }
            do {
                let downloaded = try await OmnixService.download(file, api: env.api)
                guard env.session.identityID == owner, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: downloaded); return
                }
                url = downloaded
            } catch { failed = true }
        }
        .onChange(of: env.session.identityID) { _, value in if value != owner { if let url { try? FileManager.default.removeItem(at: url) }; url = nil; dismiss() } }
        .sheet(isPresented: $save) { if let url { FirasFileSaver(url: url) { _ in save = false } } }
    }
}

private struct OmnixQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
