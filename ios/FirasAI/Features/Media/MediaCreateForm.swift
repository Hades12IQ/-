import PhotosUI
import SwiftUI

/// The four things the Studio can make, as one form.
///
/// The kind itself — its label, its glyph, its placeholder and which `MediaKind` it renders as —
/// lives in `MediaCreateForm+Kind.swift`; this file is the form.
@MainActor
struct MediaCreateForm: View {

    private let env: AppEnvironment

    @State private var kind: MediaCreateKind = .image
    @State private var prompt = ""
    @State private var lyrics = ""
    @State private var useOwnLyrics = false
    @State private var genre: MediaPromptPipeline.GenrePreset?
    @State private var shape: ImageShape?
    @State private var seconds: Double = 10
    @State private var targetConversationID: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var sourceCreationID: String?

    init(env: AppEnvironment) {
        self.env = env
    }

    private var palette: FirasPalette { env.prefs.palette }
    private var lang: AppLanguage { env.prefs.lang }
    private var media: MediaStore { env.media }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                kindPicker
                if env.session.isMember {
                    promptSection
                    kindOptions
                    conversationPicker
                    submitButton
                    MediaQuotaPanel(env: env, kind: kind.mediaKind)
                } else {
                    guestCard
                }
                failurePlate
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(palette.background)
        .task { await prepare() }
        .onChange(of: media.pendingEditSourceID) { _, _ in adoptPendingEdit() }
        .onChange(of: media.videoDefaultSeconds) { _, newValue in
            if kind == .video { seconds = Double(newValue) }
        }
        .onChange(of: photoItem) { _, item in
            Task { await loadPickedPhoto(item) }
        }
    }

    /// Everything the form does on appear, in one main-actor method: `.task` hands its body a
    /// `@Sendable` closure that does **not** inherit this view's isolation, so the state touching
    /// has to happen on the other side of an `await`.
    private func prepare() async {
        adoptPendingEdit()
        await media.refreshQuota()
    }

    /// The viewer's Edit action hands the form a source picture; it is consumed once so returning
    /// to the tab later does not silently re-arm an edit the user has moved on from.
    private func adoptPendingEdit() {
        guard let pending = media.pendingEditSourceID else { return }
        kind = .edit
        sourceCreationID = pending
        photoData = nil
        photoItem = nil
        media.pendingEditSourceID = nil
    }

    // MARK: - Kind

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaCreateKind.allCases) { option in
                    FirasPill(
                        text: option.label(lang),
                        symbol: option.symbol,
                        selected: kind == option,
                        palette: palette
                    ) {
                        Haptics.select()
                        // `.edit` and `.video` share `photoData`: one takes it as the picture to
                        // change, the other as the first frame. Leaving it behind means a photo
                        // picked for an edit silently becomes the opening frame of the next clip —
                        // a charged render the user never asked for. Changing kind clears the
                        // source; `photoItem = nil` re-enters `loadPickedPhoto`, which returns at
                        // its own `guard let item`.
                        if option != kind {
                            photoData = nil
                            photoItem = nil
                            sourceCreationID = nil
                        }
                        kind = option
                        if option == .video { seconds = Double(media.videoDefaultSeconds) }
                    }
                    .opacity(media.unavailableKinds.contains(option.mediaKind) ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Media.promptLabel(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textMuted)
            TextField(
                kind.placeholder(lang),
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(3...8)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(palette.textPrimary)
            .padding(12)
            .surfaceCard(palette)
            .bidiIsland(for: prompt, fallback: lang)
        }
    }

    @ViewBuilder
    private var kindOptions: some View {
        switch kind {
        case .image: shapeSection
        case .edit: sourceSection
        case .video: videoSection
        case .song: songSection
        }
    }

    // MARK: - Image

    private var shapeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Media.shapeSectionTitle(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FirasPill(
                        text: Strings.Media.genreAuto(lang),
                        symbol: nil,
                        selected: shape == nil,
                        palette: palette
                    ) { shape = nil }
                    ForEach(ImageShape.allCases) { option in
                        FirasPill(
                            text: Strings.Media.shapeLabel(option)(lang),
                            symbol: nil,
                            selected: shape == option,
                            palette: palette
                        ) { shape = option }
                    }
                }
                .padding(.horizontal, 2)
            }
            Text(Strings.Media.shapeNote(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
        }
    }

    // MARK: - Edit

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.Media.sourceLabel(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textMuted)
            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text(Strings.Media.sourceFromPhotos(lang))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(photoData == nil ? palette.textSecondary : palette.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
                }
                Menu {
                    ForEach(media.editableImages.prefix(20)) { item in
                        Button(String(item.meta.prompt.prefix(48))) {
                            sourceCreationID = item.id
                            photoData = nil
                            photoItem = nil
                        }
                    }
                } label: {
                    Text(Strings.Media.sourceFromLibrary(lang))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(sourceCreationID == nil ? palette.textSecondary : palette.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
                }
                .disabled(media.editableImages.isEmpty)
            }
            if photoData == nil && sourceCreationID == nil {
                Text(Strings.Media.sourceMissing(lang))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textMuted)
            }
        }
    }

    // MARK: - Video

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Strings.Media.durationLabel(lang))
                    .font(FirasType.label)
                    .foregroundStyle(palette.textMuted)
                Spacer(minLength: 8)
                Text(Strings.Media.durationSeconds.fmt(lang, ArabicText.count(Int(seconds), lang)))
                    .font(FirasType.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Slider(value: $seconds, in: 2...30, step: 1)
                .tint(palette.accent)
                .accessibilityLabel(Text(Strings.Media.durationLabel(lang)))

            Text(Strings.Media.firstFrameLabel(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textMuted)
            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text(Strings.Media.firstFramePick(lang))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(photoData == nil ? palette.textSecondary : palette.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background { Capsule(style: .continuous).fill(palette.surfaceSunken) }
                }
                if photoData != nil {
                    Button(Strings.Media.firstFrameClear(lang)) {
                        photoData = nil
                        photoItem = nil
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                }
            }
            Text(Strings.Media.firstFrameHint(lang))
                .font(FirasType.caption)
                .foregroundStyle(palette.textMuted)
        }
    }

    // MARK: - Song

    private var songSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $useOwnLyrics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Strings.Media.useMyLyrics(lang))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Text(Strings.Media.useMyLyricsHint(lang))
                        .font(FirasType.caption)
                        .foregroundStyle(palette.textMuted)
                }
            }
            .tint(palette.accent)

            if useOwnLyrics {
                TextField(Strings.Media.lyricsPlaceholder(lang), text: $lyrics, axis: .vertical)
                    .lineLimit(4...12)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                    .padding(12)
                    .surfaceCard(palette)
                    .bidiIsland(for: lyrics, fallback: lang)
            }

            Text(Strings.Media.genreLabel(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FirasPill(
                        text: Strings.Media.genreAuto(lang),
                        symbol: nil,
                        selected: genre == nil,
                        palette: palette
                    ) { genre = nil }
                    ForEach(MediaPromptPipeline.genrePresets(lang: lang)) { preset in
                        FirasPill(
                            text: preset.label(lang),
                            symbol: nil,
                            selected: genre?.id == preset.id,
                            palette: palette
                        ) { genre = preset }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Target and submit

    private var conversationPicker: some View {
        HStack(spacing: 8) {
            Text(Strings.Media.targetConversation(lang))
                .font(FirasType.label)
                .foregroundStyle(palette.textMuted)
            Spacer(minLength: 8)
            Menu {
                Button(Strings.Media.targetNewConversation(lang)) { targetConversationID = nil }
                ForEach(env.chat.summaries(for: .ai).prefix(20)) { summary in
                    Button(summary.title.isEmpty ? Strings.Media.untitledConversation(lang) : summary.title) {
                        targetConversationID = summary.id
                    }
                }
            } label: {
                Text(targetTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
            }
        }
    }

    private var targetTitle: String {
        guard let id = targetConversationID else { return Strings.Media.targetNewConversation(lang) }
        return media.conversationTitle(id)
    }

    private var submitButton: some View {
        Button {
            Haptics.send()
            Task { await submit() }
        } label: {
            HStack(spacing: 8) {
                if media.isSubmitting { ProgressView().tint(palette.onAccent) }
                Text(media.isSubmitting ? Strings.Media.createWorking(lang) : Strings.Media.createAction(lang))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background { Capsule(style: .continuous).fill(canSubmit ? palette.accent : palette.textMuted) }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    private var canSubmit: Bool {
        guard !media.isSubmitting else { return false }
        guard !media.unavailableKinds.contains(kind.mediaKind) else { return false }
        let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch kind {
        case .edit:
            return hasPrompt && (photoData != nil || sourceCreationID != nil)
        case .song:
            return hasPrompt || !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image, .video:
            return hasPrompt
        }
    }

    // MARK: - Guest and failure

    private var guestCard: some View {
        SurfaceCard(palette: palette) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Strings.Media.guestTitle(kind.mediaKind)(lang))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(Strings.Media.guestBody(kind.mediaKind)(lang))
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
                Button {
                    env.router.showSignUp(feature: kind.mediaKind.featureKey)
                } label: {
                    Text(Strings.Media.guestCreateAccount(lang))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background { Capsule(style: .continuous).fill(palette.accent) }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var failurePlate: some View {
        if let text = media.lastFailureText, !text.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(palette.error)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                    .bidiIsland(for: text, fallback: lang)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(palette)
        }
    }

    // MARK: - Actions

    private func loadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        // HEIC from the camera roll is re-encoded to JPEG by the pipeline before it is sent; the
        // server accepts only png/jpeg/webp/bmp data URIs.
        photoData = try? await item.loadTransferable(type: Data.self)
        if photoData != nil { sourceCreationID = nil }
    }

    private func submit() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .image:
            await media.createImage(prompt: text, shape: shape, in: targetConversationID)
        case .edit:
            if let data = photoData {
                await media.editImage(sourceData: data, prompt: text, in: targetConversationID)
            } else if let id = sourceCreationID, let source = media.creation(id: id) {
                await media.editImage(sourceKey: source.meta.key, prompt: text, in: targetConversationID)
            } else {
                media.present(Strings.Media.sourceMissing(lang))
                return
            }
        case .video:
            let frame = await firstFrame()
            await media.createVideo(
                prompt: text,
                seconds: Int(seconds),
                firstFrameJPEGBase64: frame,
                in: targetConversationID
            )
        case .song:
            let words = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
            if let preset = genre {
                await media.createMusic(
                    prompt: text,
                    lyrics: useOwnLyrics ? words : nil,
                    seconds: 150,
                    styleOverride: preset.style,
                    in: targetConversationID
                )
            } else {
                await media.createMusic(
                    prompt: text,
                    lyrics: useOwnLyrics ? words : nil,
                    seconds: 150,
                    in: targetConversationID
                )
            }
        }
        prompt = ""
        lyrics = ""
        photoData = nil
        photoItem = nil
        sourceCreationID = nil
    }

    private func firstFrame() async -> String? {
        guard let data = photoData else { return nil }
        return await MediaPromptPipeline.firstFrameDataURI(from: data)
    }
}
