import Photos
import SwiftUI
import UIKit

/// The figure on its own, big, and finally touchable.
///
/// This is the only place the island takes a finger: inside a transcript a drag belongs to the list,
/// but here a 2D figure pans and pinches and a 3D surface rotates and zooms, exactly as
/// `makePlotInteractive` / `make3dInteractive` behave on the web (`app.js:8586`, `app.js:9020`).
/// The ⟲ button inside the figure returns the home view.
struct DiagramFullScreenView: View {

    private let spec: DiagramSpec
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var link = DiagramIslandLink()
    @State private var height: CGFloat = 0
    @State private var phase: DiagramIsland.Phase = .loading
    @State private var shareImage: UIImage?
    @State private var isSharing = false
    @State private var feedback: String?
    @State private var feedbackToken = 0

    init(
        spec: DiagramSpec,
        palette: FirasPalette,
        lang: AppLanguage,
        motionOn: Bool = true
    ) {
        self.spec = spec
        self.palette = palette
        self.lang = lang
        self.motionOn = motionOn
    }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                bar
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
                footer
            }
        }
        .sheet(isPresented: $isSharing) {
            DiagramShareSheet(items: shareImage.map { [$0] } ?? [])
        }
    }

    // MARK: - Chrome

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: DiagramCard.symbol(for: spec.mode))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
            Text(DiagramCardCopy.title(for: spec.mode)(lang))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                Haptics.select()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(DiagramCardCopy.close(lang)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .bidiIsland(for: DiagramCardCopy.title(for: spec.mode)(lang), fallback: lang)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .failed(let reason):
            Text(DiagramCardCopy.reason(for: reason)(lang))
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .bidiIsland(for: DiagramCardCopy.reason(for: reason)(lang), fallback: lang)
        case .loading, .ready, .waitingToRun:
            island
        }
    }

    private var island: some View {
        ZStack {
            DiagramIsland(
                spec: spec,
                palette: palette,
                interactive: true,
                // The reader asked for this figure by opening it, so even the heavy 3D pass runs.
                runToken: 1,
                link: link,
                onHeight: { measured in
                    guard measured > 1 else { return }
                    height = measured
                },
                onPhase: { next in phase = next }
            )
            if phase != .ready {
                FirasActivityLabel(
                    text: DiagramCardCopy.drawing(lang),
                    palette: palette,
                    motionOn: motionOn
                )
            }
        }
        .frame(height: height > 1 ? min(height, 900) : 320)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let feedback {
                Text(feedback)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                    .padding(.leading, 10)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if phase == .ready {
                FirasIconButton(
                    symbol: "square.and.arrow.down",
                    label: DiagramCardCopy.saveImage(lang),
                    palette: palette,
                    action: { Task { await saveToPhotos() } }
                )
                FirasIconButton(
                    symbol: "square.and.arrow.up",
                    label: Strings.Common.share(lang),
                    palette: palette,
                    action: { Task { await share() } }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .animation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn), value: feedback)
    }

    // MARK: - Behaviour

    private func saveToPhotos() async {
        guard let image = await link.snapshot() else {
            flash(DiagramCardCopy.saveFailed(lang))
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            flash(DiagramCardCopy.photosDenied(lang))
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            Haptics.select()
            flash(DiagramCardCopy.savedToPhotos(lang))
        } catch {
            flash(DiagramCardCopy.saveFailed(lang))
        }
    }

    private func share() async {
        guard let image = await link.snapshot() else {
            flash(DiagramCardCopy.saveFailed(lang))
            return
        }
        shareImage = image
        isSharing = true
    }

    private func flash(_ text: String) {
        feedback = text
        feedbackToken += 1
        let token = feedbackToken
        let counter = $feedbackToken
        let slot = $feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            MainActor.assumeIsolated {
                guard counter.wrappedValue == token else { return }
                slot.wrappedValue = nil
            }
        }
    }
}
