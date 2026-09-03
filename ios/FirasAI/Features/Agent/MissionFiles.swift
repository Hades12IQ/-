import SwiftUI
import UIKit

/// The mission's deliverables: an image grid with the Firas attribution, and a document list that
/// opens the in-app viewer.
///
/// Every byte comes from `/api/agent/artifact?id=&index=` with the session cookie — the `index` is
/// read out of the file's own `url` and is never recomputed from the array position
/// (`server-agent.md §6.5, §12.4`).
struct MissionFiles: View {

    private let env: AppEnvironment
    private let job: AgentJob
    private let onOpen: (MissionArtifactRequest) -> Void

    @State private var documentsExpanded = true

    init(env: AppEnvironment, job: AgentJob, onOpen: @escaping (MissionArtifactRequest) -> Void) {
        self.env = env
        self.job = job
        self.onOpen = onOpen
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    private var files: [AgentFile] { job.surface?.files ?? [] }
    private var images: [AgentFile] { files.filter { MissionFiles.isImage($0) } }
    private var documents: [AgentFile] { files.filter { !MissionFiles.isImage($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            imageGrid
            documentList
        }
    }

    // MARK: - Images

    @ViewBuilder
    private var imageGrid: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 8)], spacing: 8) {
                    ForEach(images) { file in
                        MissionImageTile(env: env, job: job, file: file) { request in
                            onOpen(request)
                        }
                    }
                }
                Text(Strings.Agent.imageAttribution(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
            }
        }
    }

    // MARK: - Documents

    @ViewBuilder
    private var documentList: some View {
        if !documents.isEmpty {
            DisclosureGroup(isExpanded: $documentsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(documents) { file in
                        documentRow(file)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Text(Strings.Agent.filesGroup(lang))
                        .font(FirasType.label)
                        .foregroundStyle(palette.textPrimary)
                    Text(ArabicText.count(documents.count, lang))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                }
            }
            .tint(palette.accent)
        }
    }

    /* A ROW IS A BUTTON ONLY WHEN THERE IS SOMEWHERE TO GO. The action used to open with
       `guard let request = request(for: file) else { return }`, so a file whose url names no index
       drew a row with a chevron on it that ate every tap without a word. The chevron and the button
       are the promise; when the promise cannot be kept, neither is drawn. */
    @ViewBuilder
    private func documentRow(_ file: AgentFile) -> some View {
        if let request = MissionFiles.request(for: file, in: job) {
            Button {
                Haptics.select()
                onOpen(request)
            } label: {
                documentRowBody(file, openable: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(MissionFiles.openLabel(file, lang: lang)))
        } else {
            documentRowBody(file, openable: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(MissionFiles.displayName(file, lang: lang)))
        }
    }

    private func documentRowBody(_ file: AgentFile, openable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: MissionFiles.symbol(for: file))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(openable ? palette.accent : palette.textMuted)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(MissionFiles.displayName(file, lang: lang))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(MissionFiles.typeLabel(for: file, lang: lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
            }
            Spacer(minLength: 6)
            if openable {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.surfaceSunken)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// The only identity a mission file has that anything can fetch by.
    ///
    /// `AgentFile` carries three strings — a name, a MIME type and a url — and the name is a label,
    /// not an address. The address is inside the url: `/api/agent/artifact?id=…&index=…`, which the
    /// server writes for every file it is willing to serve (`server.mjs agentPublicSurface`), and
    /// whose `index` survives the gaps in the public list that an array position would not. A file
    /// whose url carries no index therefore has no bytes anywhere the app can reach: not a failed
    /// download, nothing to download.
    static func request(for file: AgentFile, in job: AgentJob) -> MissionArtifactRequest? {
        guard let index = file.artifactIndex else { return nil }
        return MissionArtifactRequest(
            jobID: file.artifactJobID ?? job.id,
            index: index,
            name: file.name,
            type: file.type
        )
    }

    /// A nameless file still needs something to be called; the document list has always used the
    /// «فتح الملف» stand-in for it, so the grid uses the same one.
    static func displayName(_ file: AgentFile, lang: AppLanguage) -> String {
        file.name.isEmpty ? Strings.Agent.openFile(lang) : file.name
    }

    /// What VoiceOver reads when the row is a control.
    ///
    /// `displayName`'s stand-in is a label for the eye only: dropped into the «%@» of
    /// `openFileNamed` it announces «فتح الملف: فتح الملف». A file with no name has no name to read
    /// out, so the control is announced with the bare verb instead.
    static func openLabel(_ file: AgentFile, lang: AppLanguage) -> String {
        file.name.isEmpty
            ? Strings.Agent.openFile(lang)
            : Strings.Agent.openFileNamed.fmt(lang, file.name)
    }

    // MARK: - Classification

    static func isImage(_ file: AgentFile) -> Bool {
        if file.type.lowercased().hasPrefix("image/") { return true }
        return ["png", "jpg", "jpeg", "webp", "gif", "svg", "heic"].contains(fileExtension(file))
    }

    static func fileExtension(_ file: AgentFile) -> String {
        let name = file.name.lowercased()
        guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else { return "" }
        return String(name[name.index(after: dot)...])
    }

    static func symbol(for file: AgentFile) -> String {
        switch fileExtension(file) {
        case "pdf": return "doc.richtext"
        case "docx", "doc", "rtf": return "doc.text"
        case "pptx", "ppt": return "rectangle.on.rectangle"
        case "xlsx", "xls", "csv", "tsv": return "tablecells"
        case "zip": return "doc.zipper"
        case "md", "markdown", "txt": return "text.alignleft"
        case "json", "xml", "yml", "yaml": return "curlybraces"
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    /// A human word rather than the raw MIME string the audit flagged (`audit-ios-agent-code.md A12`).
    static func typeLabel(for file: AgentFile, lang: AppLanguage) -> String {
        let ext = fileExtension(file).uppercased()
        if !ext.isEmpty { return ext }
        let mime = file.type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mime.isEmpty else { return Strings.Agent.openFile(lang) }
        if let slash = mime.lastIndex(of: "/"), slash < mime.index(before: mime.endIndex) {
            return String(mime[mime.index(after: slash)...]).uppercased()
        }
        return mime.uppercased()
    }
}

// MARK: - Image tile

private struct MissionImageTile: View {

    let env: AppEnvironment
    let job: AgentJob
    let file: AgentFile
    let onOpen: (MissionArtifactRequest) -> Void

    @State private var image: UIImage?
    @State private var failed = false

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }

    private var request: MissionArtifactRequest? {
        MissionFiles.request(for: file, in: job)
    }

    /* A PICTURE, NOT A DEAD BUTTON. The tap used to open with
       `guard let index = file.artifactIndex else { return }` — so a picture the mission made whose
       url names no index was drawn as a control, and the control swallowed every tap in silence.
       There is no second identity to fall back on: the index IS the address (see
       `MissionFiles.request(for:in:)`), and without it there are no bytes to fetch, no thumbnail
       to decode and nothing for the viewer to open.

       So the tile stops pretending. With an index it is a button, it loads its own thumbnail and
       it opens the full picture in `ArtifactViewer`. Without one it is a plain tile that says what
       the file was called and offers nothing — which reads as a picture the app could not fetch,
       and not as an app that ignores you. */
    var body: some View {
        if let request {
            Button {
                Haptics.select()
                onOpen(request)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(MissionFiles.openLabel(file, lang: lang)))
            .task(id: file.url) { await load(request) }
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(name))
                .accessibilityAddTraits(.isImage)
        }
    }

    private var name: String {
        MissionFiles.displayName(file, lang: lang)
    }

    /// The spinner is only honest while something is actually being fetched. A tile with no
    /// artifact to ask for goes straight to the placeholder rather than turning forever.
    private var showsPlaceholder: Bool {
        failed || request == nil
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.surfaceSunken)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if showsPlaceholder {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(palette.textMuted)
                    Text(file.name.isEmpty ? Strings.Agent.viewerFailed(lang) : file.name)
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
            } else {
                ProgressView()
                    .tint(palette.accent)
            }
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        }
    }

    private func load(_ request: MissionArtifactRequest) async {
        guard image == nil else { return }
        guard let url = await env.agent.artifactURL(
            jobID: request.jobID,
            index: request.index,
            download: false
        ) else {
            failed = true
            return
        }
        if let decoded = await ImageCache.shared.image(forFile: url) {
            image = decoded
            failed = false
        } else {
            failed = true
        }
    }
}
