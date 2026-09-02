import SwiftUI

struct AgentScreen: View {
    let store: AgentStore
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void
    let onOpenProfile: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @FocusState private var isPromptFocused: Bool

    init(
        store: AgentStore,
        showsSidebarButton: Bool,
        onOpenSidebar: @escaping () -> Void,
        onOpenProfile: @escaping () -> Void
    ) {
        self.store = store
        self.showsSidebarButton = showsSidebarButton
        self.onOpenSidebar = onOpenSidebar
        self.onOpenProfile = onOpenProfile
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                content
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
            }
            .navigationTitle(Text(AgentStrings.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !store.isRunning {
                    AgentComposer(
                        draft: $draft,
                        isFocused: $isPromptFocused,
                        canSend: session.isAuthenticated,
                        onSend: startMission
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                }
            }
            .overlay(alignment: .top) {
                if let error = store.errorMessage, !error.isEmpty {
                    AgentErrorBanner(message: error) {
                        store.errorMessage = nil
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                }
            }
        }
        .task { store.resumeIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if store.currentJob != nil || store.isRunning || !store.pendingTask.isEmpty {
            missionContent
        } else {
            welcome
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(preferences.palette.accent.opacity(0.10))
                        .frame(width: 84, height: 84)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 35, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(preferences.palette.accent)
                }
                .accessibilityHidden(true)

                Text(AgentStrings.hero)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text(AgentStrings.heroDetail)
                    .font(.body)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if !session.isAuthenticated {
                    Button(action: onOpenProfile) {
                        Label(AgentStrings.signIn, systemImage: "person.crop.circle.badge.checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(preferences.palette.accent)
                    .foregroundStyle(preferences.palette.onAccent)
                    .padding(.top, 6)
                }
            }
            .padding(26)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var missionContent: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                missionHeader

                if store.isRunning {
                    HStack(spacing: 10) {
                        FirasActivityLabel(kind: .thinking, isActive: true)
                        Text(AgentStrings.runningCloud)
                            .font(.footnote)
                            .foregroundStyle(preferences.palette.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !store.stepRows.isEmpty {
                    AgentSectionCard(title: AgentStrings.plan, systemImage: "checklist") {
                        VStack(spacing: 0) {
                            ForEach(store.stepRows) { row in
                                AgentStepView(step: row.step)
                                if row.id != store.stepRows.last?.id {
                                    Divider().overlay(preferences.palette.border)
                                }
                            }
                        }
                    }
                }

                if !store.speechRows.isEmpty || !store.toolRows.isEmpty {
                    AgentSectionCard(title: AgentStrings.activity, systemImage: "waveform.path.ecg") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(store.speechRows.suffix(4)) { row in
                                Text(verbatim: row.text)
                                    .font(.body)
                                    .foregroundStyle(preferences.palette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(store.toolRows.suffix(8)) { row in
                                AgentToolView(tool: row.tool)
                            }
                        }
                    }
                }

                if !store.files.isEmpty {
                    AgentSectionCard(title: AgentStrings.files, systemImage: "tray.full") {
                        VStack(spacing: 10) {
                            ForEach(store.files) { file in
                                if let index = store.files.firstIndex(where: { $0.id == file.id }) {
                                    AgentFileView(
                                        file: file,
                                        shareURL: store.sharedArtifactURLs[index],
                                        onDownload: { Task { await store.downloadArtifact(at: index) } }
                                    )
                                }
                            }
                        }
                    }
                }

                if let credits = store.currentJob?.credits {
                    AgentSectionCard(title: AgentStrings.credits, systemImage: "sparkles") {
                        HStack(spacing: 0) {
                            AgentCreditMetric(
                                title: AgentStrings.creditsRemaining,
                                value: credits.remaining
                            )
                            Divider()
                                .frame(height: 38)
                                .overlay(preferences.palette.border)
                            AgentCreditMetric(
                                title: AgentStrings.creditsUsed,
                                value: credits.used
                            )
                        }
                    }
                }

                if !store.finalText.isEmpty {
                    AgentSectionCard(title: AgentStrings.result, systemImage: "sparkles") {
                        Text(verbatim: store.finalText)
                            .font(.body)
                            .foregroundStyle(preferences.palette.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !store.isRunning {
                    Button {
                        withAnimation(contentAnimation) {
                            store.clearFinishedMission()
                            draft = ""
                        }
                    } label: {
                        Label(AgentStrings.newMission, systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(preferences.palette.accent)
                    .foregroundStyle(preferences.palette.onAccent)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: preferences.contentWidth.maxWidth)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var missionHeader: some View {
        GlassSurface(cornerRadius: 24, tintStrength: 0.055) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(preferences.palette.accent)
                        .frame(width: 44, height: 44)
                        .background(preferences.palette.accent.opacity(0.10), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: store.currentJob?.title ?? store.pendingTitle)
                            .font(.headline)
                            .foregroundStyle(preferences.palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(verbatim: store.pendingTask)
                            .font(.subheadline)
                            .foregroundStyle(preferences.palette.textSecondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 10) {
                    AgentPhaseChip(phase: store.currentJob?.phase, isStarting: store.isStarting)
                    AgentElapsedView(startedAt: effectiveStartedAt)
                    Spacer(minLength: 4)
                    if let remaining = store.currentJob?.credits?.remaining {
                        Label {
                            Text(remaining, format: .number.precision(.fractionLength(0...1)))
                        } icon: {
                            Image(systemName: "sparkle")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(preferences.palette.textSecondary)
                        .accessibilityLabel(Text(AgentStrings.credits))
                    }
                }
            }
            .padding(16)
        }
    }

    private var effectiveStartedAt: Date? {
        if let milliseconds = store.activity?.startedAt, milliseconds > 0 {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        }
        return store.startedAt
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsSidebarButton {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(AgentStrings.openSidebar))
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onOpenProfile) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(AgentStrings.account))
        }
    }

    private var contentAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .snappy(duration: 0.28, extraBounce: 0)
    }

    private func startMission() {
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isPromptFocused = false
        store.start(task: clean, tier: preferences.tier, language: preferences.language)
        if store.isRunning { draft = "" }
    }
}

private struct AgentComposer: View {
    @Binding var draft: String
    var isFocused: FocusState<Bool>.Binding
    let canSend: Bool
    let onSend: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GlassSurface(cornerRadius: 25, tintStrength: 0.045) {
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(AgentStrings.prompt)
                            .font(.body)
                            .foregroundStyle(preferences.palette.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $draft, axis: .vertical)
                        .focused(isFocused)
                        .lineLimit(1...5)
                        .font(.body)
                        .foregroundStyle(preferences.palette.textPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 10)
                        .accessibilityLabel(Text(AgentStrings.prompt))
                        .onSubmit { if hasText && canSend { onSend() } }
                }

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(
                            hasText && canSend
                                ? preferences.palette.accent
                                : preferences.palette.surfaceSunken,
                            in: Circle()
                        )
                        .foregroundStyle(
                            hasText && canSend
                                ? preferences.palette.onAccent
                                : preferences.palette.textMuted
                        )
                }
                .buttonStyle(.plain)
                .disabled(!hasText || !canSend)
                .accessibilityLabel(Text(AgentStrings.send))
            }
            .padding(.leading, 12)
            .padding(.trailing, 7)
            .padding(.vertical, 6)
        }
    }
}

private struct AgentSectionCard<Content: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    let content: Content

    @Environment(PreferencesStore.self) private var preferences

    init(
        title: LocalizedStringResource,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        GlassSurface(cornerRadius: 22, tintStrength: 0.035) {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentStepView: View {
    let step: AgentStep
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: step.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let output = step.out, !output.isEmpty {
                    Text(verbatim: output)
                        .font(.caption)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch step.s {
        case .done: "checkmark.circle.fill"
        case .run: "circle.dotted.circle"
        case .fail: "exclamationmark.circle.fill"
        case .todo: "circle"
        }
    }

    private var color: Color {
        switch step.s {
        case .done: preferences.palette.success
        case .run: preferences.palette.accent
        case .fail: preferences.palette.error
        case .todo: preferences.palette.textMuted
        }
    }
}

private struct AgentToolView: View {
    let tool: AgentTool
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(preferences.palette.accent)
                .frame(width: 32, height: 32)
                .background(preferences.palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: tool.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .environment(\.layoutDirection, .leftToRight)
                if !tool.arg.isEmpty {
                    Text(verbatim: tool.arg)
                        .font(.caption2.monospaced())
                        .foregroundStyle(preferences.palette.textMuted)
                        .lineLimit(2)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentFileView: View {
    let file: AgentFile
    let shareURL: URL?
    let onDownload: () -> Void
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(preferences.palette.accent)
                .frame(width: 38, height: 38)
                .background(preferences.palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: file.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(1)
                Text(verbatim: file.type)
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let shareURL {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(AgentStrings.share))
            } else {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(AgentStrings.download))
            }
        }
        .padding(8)
        .background(preferences.palette.surfaceSunken.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AgentPhaseChip: View {
    let phase: AgentJobPhase?
    let isStarting: Bool
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(color.opacity(0.10), in: Capsule())
            .accessibilityElement(children: .combine)
    }

    private var label: LocalizedStringResource {
        if isStarting { return AgentStrings.queued }
        return switch phase {
        case .queued, nil: AgentStrings.queued
        case .run: AgentStrings.running
        case .done: AgentStrings.done
        case .fail: AgentStrings.failed
        }
    }

    private var icon: String {
        switch phase {
        case .done: "checkmark"
        case .fail: "exclamationmark"
        case .queued, .run, nil: "clock"
        }
    }

    private var color: Color {
        switch phase {
        case .done: preferences.palette.success
        case .fail: preferences.palette.error
        case .queued, .run, nil: preferences.palette.accent
        }
    }
}

private struct AgentElapsedView: View {
    let startedAt: Date?
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(from: startedAt, to: context.date))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(preferences.palette.textSecondary)
            }
            .accessibilityHidden(true)
        }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct AgentCreditMetric: View {
    let title: LocalizedStringResource
    let value: Double
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(spacing: 4) {
            Text(value, format: .number.precision(.fractionLength(0...1)))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(preferences.palette.textPrimary)
            Text(title)
                .font(.caption)
                .foregroundStyle(preferences.palette.textMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 16, tintStrength: 0.02) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(preferences.palette.error)
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(AgentStrings.dismissError))
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
        }
    }
}
