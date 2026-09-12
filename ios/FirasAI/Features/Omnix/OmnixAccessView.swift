import SwiftUI

struct OmnixAccessView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var loading = false
    @State private var error: String?
    private var ar: Bool { env.prefs.lang == .arabic }
    private var state: OmnixState { env.chat.pipeline.omnixState }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("omnix 1").font(.title.weight(.semibold))
                    Text(ar ? "المهام والأدوات والملفات على مساحة حسابك السحابية، بنفس إمكانات الموقع." : "Tasks, tools and files in your account’s cloud workspace, with the website’s capabilities.")
                    if !env.session.isMember {
                        Text(ar ? "سجّل الدخول لاستخدام أومنكس." : "Sign in to use Omnix.")
                    } else if state.access?.status == "approved" {
                        Text(state.ready ? (ar ? "جاهز للاستخدام" : "Ready to use") : (ar ? "يجري تجهيز مساحة حسابك." : "Your account workspace is being prepared."))
                        Button(ar ? "استخدام أومنكس" : "Use Omnix") { env.prefs.tier = .omnix; dismiss() }
                            .buttonStyle(.borderedProminent).disabled(!state.ready || loading)
                    } else if state.access?.status == "pending" {
                        Text(ar ? "طلب الوصول قيد المراجعة." : "Your access request is awaiting review.")
                    } else if state.access != nil && state.access?.canRequest != false {
                        Text(ar ? "اشرح كيف تريد استخدام أومنكس (20–1200 حرف)." : "Explain how you want to use Omnix (20–1200 characters).")
                        TextEditor(text: $reason).frame(minHeight: 140).scrollContentBackground(.hidden)
                            .padding(8).background(env.prefs.palette.surface, in: RoundedRectangle(cornerRadius: 12))
                        Button(ar ? "إرسال طلب الوصول" : "Request access") { Task { await request() } }
                            .buttonStyle(.borderedProminent).disabled(loading || !(20...1200).contains(reason.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count))
                    }
                    if loading { ProgressView() }
                    if let error { Text(error).font(.footnote).foregroundStyle(env.prefs.palette.error) }
                    Button(ar ? "تحديث الحالة" : "Refresh status") { Task { await refresh() } }.frame(minHeight: 44).disabled(loading)
                }.padding(24)
            }
            .background(env.prefs.palette.background).foregroundStyle(env.prefs.palette.textPrimary)
            .navigationTitle(ar ? "الوصول إلى أومنكس" : "Omnix access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings.Common.close(env.prefs.lang)) { dismiss() } } }
        }.tint(env.prefs.palette.accent).task { await refresh() }
    }
    private func refresh() async {
        guard !loading, env.session.isMember else { return }
        loading = true; error = nil
        defer { loading = false }
        do { try await env.chat.pipeline.refreshOmnixAccess() }
        catch { self.error = OmnixCopy.unavailable(env.prefs.lang) }
    }
    private func request() async {
        guard !loading, let owner = env.session.identityID else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let value = try await OmnixService.requestAccess(reason: reason, api: env.api)
            guard env.session.identityID == owner else { return }
            state.access = value
        } catch { self.error = OmnixCopy.unavailable(env.prefs.lang) }
    }
}
