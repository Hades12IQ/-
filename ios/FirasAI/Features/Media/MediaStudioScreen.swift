import AVKit
import Foundation
import SwiftUI
import UIKit

struct MediaStudioScreen: View {
    let store: MediaStudioStore
    let focusedJobID: String?
    let onOpenProfile: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: MediaStudioKind = .image
    @State private var prompt = ""
    @State private var lyrics = ""
    @State private var aspect: ImageAspectPreset = .square
    @State private var videoSeconds = 10
    @State private var musicSeconds = 90
    @State private var kindFeedback = 0

    /// Media creation is presented only from Firas Chat. It intentionally has
    /// no product/sidebar initializer.
    init(
        store: MediaStudioStore,
        initialKind: MediaStudioKind = .image,
        focusedJobID: String? = nil,
        onOpenProfile: @escaping () -> Void
    ) {
        self.store = store
        self.focusedJobID = focusedJobID
        _selectedKind = State(initialValue: initialKind)
        self.onOpenProfile = onOpenProfile
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                ScrollViewReader { proxy in
                    ScrollView {
                        MediaGlassStack {
                            LazyVStack(spacing: 16) {
                                MediaHeroCard()
                                kindPicker
                                creationCard

                                if store.isLoading {
                                    ProgressView()
                                        .tint(preferences.palette.accent)
                                        .frame(minHeight: 80)
                                }

                                if !store.creations.isEmpty {
                                    creationsSection
                                }
                            }
                        }
                        .frame(maxWidth: min(900, preferences.contentWidth.maxWidth))
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .task(id: focusedJobID) {
                        await scrollToFocusedCreation(using: proxy)
                    }
                }
            }
            .environment(\.layoutDirection, preferences.language.layoutDirection)
            .navigationTitle(Text(MediaStrings.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbarContent }
            .overlay(alignment: .top) { messageOverlay }
        }
        .task(id: session.identityID) {
            store.resumeIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.resumeIfNeeded() }
        }
        .sensoryFeedback(.selection, trigger: kindFeedback)
    }

    private var kindPicker: some View {
        MediaKindPicker(selection: $selectedKind) {
            kindFeedback &+= 1
        }
    }

    private var creationCard: some View {
        GlassSurface(cornerRadius: 26, tintStrength: 0.055) {
            VStack(alignment: .leading, spacing: 15) {
                Label(MediaStrings.prompt, systemImage: promptIcon)
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)

                TextField(promptPlaceholder, text: $prompt, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(4...9)
                    .padding(14)
                    .background(
                        preferences.palette.surfaceSunken.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                    )
                    .accessibilityLabel(Text(MediaStrings.prompt))

                switch selectedKind {
                case .image:
                    aspectPicker
                case .video:
                    durationPicker(values: [5, 10, 15, 30], selection: $videoSeconds)
                case .music:
                    musicFields
                }

                Text(MediaStrings.runningCloud)
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if session.isAuthenticated {
                    Button(action: create) {
                        Label(MediaStrings.create, systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(preferences.palette.accent)
                    .foregroundStyle(preferences.palette.onAccent)
                    .disabled(!canCreate)
                } else {
                    Button(action: onOpenProfile) {
                        Label(MediaStrings.signIn, systemImage: "person.crop.circle.badge.checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(preferences.palette.accent)
                    .foregroundStyle(preferences.palette.onAccent)
                }
            }
            .padding(17)
        }
        .animation(.snappy(duration: 0.36, extraBounce: 0.04), value: selectedKind)
    }

    private var aspectPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(MediaStrings.aspect)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(preferences.palette.textSecondary)

            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(ImageAspectPreset.allCases) { preset in
                        AspectPresetButton(
                            preset: preset,
                            selected: aspect == preset
                        ) {
                            withAnimation(.snappy(duration: 0.3, extraBounce: 0.08)) {
                                aspect = preset
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var musicFields: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 8) {
                Text(MediaStrings.lyrics)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(preferences.palette.textSecondary)
                TextField(MediaStrings.lyricsOptional, text: $lyrics, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(3...8)
                    .padding(13)
                    .background(
                        preferences.palette.surfaceSunken.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .accessibilityLabel(Text(MediaStrings.lyrics))
            }
            durationPicker(values: [30, 60, 90, 180], selection: $musicSeconds)
        }
    }

    private func durationPicker(values: [Int], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(MediaStrings.duration)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(preferences.palette.textSecondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    durationButtons(values: values, selection: selection)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 8) {
                    durationButtons(values: values, selection: selection)
                }
            }
        }
    }

    @ViewBuilder
    private func durationButtons(values: [Int], selection: Binding<Int>) -> some View {
        ForEach(values, id: \.self) { value in
            Button {
                withAnimation(.snappy(duration: 0.28, extraBounce: 0.06)) {
                    selection.wrappedValue = value
                }
            } label: {
                Text(durationLabel(value))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(
                        selection.wrappedValue == value
                            ? preferences.palette.accent.opacity(0.20)
                            : preferences.palette.surfaceSunken.opacity(0.55),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule().stroke(
                            selection.wrappedValue == value
                                ? preferences.palette.accent.opacity(0.78)
                                : preferences.palette.border,
                            lineWidth: 1
                        )
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                selection.wrappedValue == value
                    ? preferences.palette.accent
                    : preferences.palette.textSecondary
            )
        }
    }

    private var creationsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(MediaStrings.recent, systemImage: "square.stack.3d.up")
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)
                .padding(.horizontal, 4)

            ForEach(store.creations) { creation in
                MediaCreationCard(
                    creation: creation,
                    retry: { store.retry(creation, language: preferences.language) },
                    save: { store.saveToPhotos(creation, language: preferences.language) },
                    remove: { store.remove(creation) }
                )
                .id(creation.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity.combined(with: .move(edge: .trailing))
                ))
            }
        }
        .animation(.snappy(duration: 0.42, extraBounce: 0.04), value: store.creations)
    }

    @ViewBuilder
    private var messageOverlay: some View {
        if let error = store.errorMessage, !error.isEmpty {
            MediaMessageBanner(message: error, isError: true, dismiss: store.clearMessages)
                .padding(.horizontal, 14)
                .padding(.top, 8)
        } else if let confirmation = store.confirmationMessage, !confirmation.isEmpty {
            MediaMessageBanner(message: confirmation, isError: false, dismiss: store.clearMessages)
                .padding(.horizontal, 14)
                .padding(.top, 8)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(MediaStrings.dismiss))
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(MediaStrings.title)
                    .font(.headline)
                Text(MediaStrings.subtitle)
                    .font(.caption2)
                    .foregroundStyle(preferences.palette.textMuted)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onOpenProfile) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(MediaStrings.account))
        }
    }

    private var promptPlaceholder: LocalizedStringResource {
        switch selectedKind {
        case .image: MediaStrings.imagePrompt
        case .video: MediaStrings.videoPrompt
        case .music: MediaStrings.musicPrompt
        }
    }

    private var promptIcon: String {
        switch selectedKind {
        case .image: "photo.artframe"
        case .video: "video"
        case .music: "waveform"
        }
    }

    private var canCreate: Bool {
        let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasLyrics = !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return selectedKind == .music ? hasPrompt || hasLyrics : hasPrompt
    }

    private func create() {
        guard canCreate else { return }
        switch selectedKind {
        case .image:
            store.createImage(prompt: prompt, preset: aspect, language: preferences.language)
        case .video:
            store.createVideo(prompt: prompt, seconds: videoSeconds, language: preferences.language)
        case .music:
            store.createMusic(
                prompt: prompt,
                lyrics: lyrics,
                seconds: musicSeconds,
                language: preferences.language
            )
        }
    }

    private func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 {
            return preferences.language == .arabic ? "\(seconds) ث" : "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return preferences.language == .arabic ? "\(minutes) د" : "\(minutes)m"
        }
        return preferences.language == .arabic
            ? "\(minutes):\(String(format: "%02d", remainder)) د"
            : "\(minutes):\(String(format: "%02d", remainder))"
    }

    private func scrollToFocusedCreation(using proxy: ScrollViewProxy) async {
        guard let focusedJobID, !focusedJobID.isEmpty else { return }
        for _ in 0..<16 {
            if let creation = store.creations.first(where: { $0.jobID == focusedJobID }) {
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.5, extraBounce: 0.04)) {
                    proxy.scrollTo(creation.id, anchor: .top)
                }
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
        }
    }
}

private struct MediaGlassStack<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 16) {
                content
            }
        } else {
            content
        }
    }
}

private struct MediaHeroCard: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 26, tintStrength: 0.065) {
            HStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(preferences.palette.accent.opacity(0.13))
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(preferences.palette.accent)
                }
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(MediaStrings.hero)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(preferences.palette.textPrimary)
                    Text(MediaStrings.heroDetail)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(17)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MediaKindPicker: View {
    @Binding var selection: MediaStudioKind
    let didSelect: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Namespace private var selectionAnimation

    var body: some View {
        GlassSurface(cornerRadius: 20, tintStrength: 0.035) {
            HStack(spacing: 5) {
                ForEach(MediaStudioKind.allCases) { kind in
                    Button {
                        guard kind != selection else { return }
                        withAnimation(.snappy(duration: 0.36, extraBounce: 0.08)) {
                            selection = kind
                        }
                        didSelect()
                    } label: {
                        Label(title(kind), systemImage: systemImage(kind))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                            .contentShape(.rect)
                            .background {
                                if selection == kind {
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(preferences.palette.accent.opacity(0.18))
                                        .matchedGeometryEffect(
                                            id: "media-kind-selection",
                                            in: selectionAnimation
                                        )
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        selection == kind
                            ? preferences.palette.accent
                            : preferences.palette.textSecondary
                    )
                    .accessibilityAddTraits(selection == kind ? .isSelected : [])
                }
            }
            .padding(5)
        }
    }

    private func title(_ kind: MediaStudioKind) -> LocalizedStringResource {
        switch kind {
        case .image: MediaStrings.image
        case .video: MediaStrings.video
        case .music: MediaStrings.music
        }
    }

    private func systemImage(_ kind: MediaStudioKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "video"
        case .music: "waveform"
        }
    }
}

private struct AspectPresetButton: View {
    let preset: ImageAspectPreset
    let selected: Bool
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? preferences.palette.accent.opacity(0.24) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(
                                selected ? preferences.palette.accent : preferences.palette.textMuted,
                                lineWidth: selected ? 2 : 1
                            )
                    }
                    .aspectRatio(CGFloat(preset.ratio), contentMode: .fit)
                    .frame(width: 34, height: 30)

                Text(MediaStrings.aspect(preset))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(width: 74, height: 70)
            .background(
                selected
                    ? preferences.palette.accent.opacity(0.13)
                    : preferences.palette.surfaceSunken.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(selected ? preferences.palette.accent.opacity(0.7) : preferences.palette.border)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? preferences.palette.accent : preferences.palette.textSecondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MediaCreationCard: View {
    let creation: MediaCreation
    let retry: () -> Void
    let save: () -> Void
    let remove: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 25, tintStrength: 0.05) {
            VStack(alignment: .leading, spacing: 13) {
                header

                if creation.phase.isActive {
                    activeContent
                } else if creation.phase == .failed {
                    failedContent
                } else if let url = creation.localFileURL {
                    resultContent(url)
                    resultActions(url)
                } else {
                    preparingResult
                }
            }
            .padding(16)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: kindIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(preferences.palette.accent)
                .frame(width: 38, height: 38)
                .background(preferences.palette.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: creation.prompt.isEmpty ? fallbackTitle : creation.prompt)
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(3)
                Text(creation.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textMuted)
            }
            Spacer(minLength: 4)
            if !creation.phase.isActive {
                Menu {
                    Button(role: .destructive, action: remove) {
                        Label(MediaStrings.remove, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(MediaStrings.remove))
            }
        }
    }

    private var activeContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            FirasMediaActivityLabel()
            HStack(spacing: 9) {
                Image(systemName: "cloud")
                    .foregroundStyle(preferences.palette.accent)
                    .accessibilityHidden(true)
                Text(MediaStrings.runningCloud)
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(
            preferences.palette.surfaceSunken.opacity(0.48),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(MediaStrings.retry, systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(preferences.palette.error)
            Button(action: retry) {
                Label(MediaStrings.retry, systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.bordered)
            .tint(preferences.palette.accent)
        }
    }

    private var preparingResult: some View {
        HStack(spacing: 10) {
            ProgressView().tint(preferences.palette.accent)
            Text(MediaStrings.preparingResult)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(preferences.palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 64)
    }

    @ViewBuilder
    private func resultContent(_ url: URL) -> some View {
        switch creation.kind {
        case .image:
            MediaResultImage(url: url, aspectRatio: creation.aspect?.ratio ?? 1)
        case .video:
            MediaResultVideo(url: url)
        case .music:
            MediaResultAudio(url: url)
        }
    }

    private func resultActions(_ url: URL) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) { actionButtons(url) }
            VStack(spacing: 9) { actionButtons(url) }
        }
    }

    @ViewBuilder
    private func actionButtons(_ url: URL) -> some View {
        if creation.kind != .music {
            Button(action: save) {
                Label(MediaStrings.save, systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            }
            .buttonStyle(.bordered)
            .tint(preferences.palette.accent)
        }

        ShareLink(item: url) {
            Label(MediaStrings.share, systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
        }
        .buttonStyle(.borderedProminent)
        .tint(preferences.palette.accent)
        .foregroundStyle(preferences.palette.onAccent)
    }

    private var kindIcon: String {
        switch creation.kind {
        case .image: "photo"
        case .video: "video"
        case .music: "waveform"
        }
    }

    private var fallbackTitle: String {
        switch (creation.kind, preferences.language) {
        case (.image, .arabic): "صورة فِراس"
        case (.video, .arabic): "فيديو فِراس"
        case (.music, .arabic): "موسيقى فِراس"
        case (.image, .english): "Firas image"
        case (.video, .english): "Firas video"
        case (.music, .english): "Firas music"
        }
    }
}

private struct FirasMediaActivityLabel: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(preferences.palette.accent)
                .accessibilityHidden(true)
            if preferences.motionEnabled && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    sweptText(progress: progress(at: context.date))
                }
            } else {
                baseText
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var baseText: some View {
        Text(MediaStrings.creating)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(preferences.palette.textSecondary)
    }

    private func sweptText(progress: Double) -> some View {
        baseText.overlay {
            GeometryReader { proxy in
                let width = max(44, proxy.size.width * 0.46)
                LinearGradient(
                    colors: [.clear, preferences.palette.accent.opacity(0.95), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width)
                .offset(x: -width + (proxy.size.width + width) * CGFloat(progress))
            }
            .mask(baseText)
            .accessibilityHidden(true)
        }
    }

    private func progress(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.7) / 1.7
    }
}

private struct MediaResultImage: View {
    let url: URL
    let aspectRatio: Double

    @Environment(PreferencesStore.self) private var preferences
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    preferences.palette.surfaceSunken
                    ProgressView().tint(preferences.palette.accent)
                }
            }
        }
        .aspectRatio(CGFloat(aspectRatio), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(preferences.palette.border, lineWidth: 1)
        }
        .task(id: url) {
            guard let data = try? await MediaLocalFileLoader.shared.data(at: url),
                  !Task.isCancelled
            else { return }
            image = UIImage(data: data)
        }
        .accessibilityLabel(Text(MediaStrings.result))
    }
}

private struct MediaResultVideo: View {
    @State private var player: AVPlayer
    @Environment(PreferencesStore.self) private var preferences

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .tint(preferences.palette.accent)
            .clipShape(.rect(cornerRadius: 19))
            .onDisappear { player.pause() }
            .accessibilityLabel(Text(MediaStrings.result))
    }
}

private struct MediaResultAudio: View {
    @State private var player: AVPlayer
    @State private var isPlaying = false

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    preferences.palette.accentDeep.opacity(0.74),
                    preferences.palette.surfaceSunken,
                    preferences.palette.accent.opacity(0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 17) {
                FirasBrandMark(size: 56)
                    .shadow(color: preferences.palette.accent.opacity(0.28), radius: 18)

                waveform

                Button {
                    if isPlaying {
                        player.pause()
                    } else {
                        player.play()
                    }
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0.1)) {
                        isPlaying.toggle()
                    }
                } label: {
                    Label(
                        isPlaying ? MediaStrings.pausePlayback : MediaStrings.pausedPlayback,
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.headline)
                    .frame(minWidth: 136, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(preferences.palette.accent)
                .foregroundStyle(preferences.palette.onAccent)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 250)
        .clipShape(.rect(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(preferences.palette.border, lineWidth: 1)
        }
        .onDisappear {
            player.pause()
            isPlaying = false
        }
    }

    @ViewBuilder
    private var waveform: some View {
        if isPlaying && !reduceMotion && preferences.motionEnabled {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                waveformBars(phase: context.date.timeIntervalSinceReferenceDate * 4.2)
            }
        } else {
            waveformBars(phase: 0)
        }
    }

    private func waveformBars(phase: Double) -> some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<15, id: \.self) { index in
                Capsule()
                    .fill(preferences.palette.accent.opacity(0.72))
                    .frame(width: 3, height: waveformHeight(index, phase: phase))
            }
        }
        .frame(height: 36)
        .accessibilityHidden(true)
    }

    private func waveformHeight(_ index: Int, phase: Double) -> CGFloat {
        let heights: [CGFloat] = [10, 18, 27, 15, 33, 22, 13, 30, 20, 35, 17, 28, 12, 23, 15]
        let base = heights[index % heights.count]
        guard isPlaying && !reduceMotion && preferences.motionEnabled else {
            return max(8, base * 0.62)
        }
        let wave = (sin(phase + Double(index) * 0.86) + 1) * 0.5
        return max(8, base * CGFloat(0.62 + wave * 0.38))
    }
}

private struct MediaMessageBanner: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 16, tintStrength: 0.055) {
            HStack(spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? preferences.palette.error : preferences.palette.success)
                    .accessibilityHidden(true)
                Text(verbatim: message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(MediaStrings.dismiss))
            }
            .padding(.leading, 13)
            .padding(.trailing, 2)
        }
    }
}

private actor MediaLocalFileLoader {
    static let shared = MediaLocalFileLoader()

    func data(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
