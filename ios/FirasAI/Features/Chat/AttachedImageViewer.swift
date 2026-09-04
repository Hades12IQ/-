import SwiftUI
import UIKit

/// A picture the reader attached, opened full screen.
///
/// Deliberately not `MediaViewer`: that one belongs to a `MediaCreation` — it knows a job id, a
/// library record, a share URL and a regenerate action, none of which exist for a photo someone
/// picked off their camera roll. What this needs is the picture, a way out, and a way to save or
/// send it on.
///
/// Pinch and drag are hand-rolled rather than taken from a `ScrollView`: a scroll view inside a
/// cover fights the dismiss gesture, and the whole surface is one gesture target anyway.
@MainActor
struct AttachedImageViewer: View {

    private let image: UIImage
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @Environment(\.viewerCloseReliabilityProbe) private var closeProbe
    #endif

    /// The settled zoom, and the live pinch on top of it. Kept apart so a gesture that ends
    /// mid-pinch does not lose the scale it had before the finger landed.
    @State private var scale: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero

    init(image: UIImage, palette: FirasPalette, lang: AppLanguage, onClose: (() -> Void)? = nil) {
        self.image = image
        self.palette = palette
        self.lang = lang
        self.onClose = onClose
    }

    private var zoom: CGFloat { max(1, min(scale * pinch, 6)) }
    private var isZoomed: Bool { zoom > 1.02 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .gesture(magnification)
                .simultaneousGesture(pan)
                .onTapGesture(count: 2) { toggleZoom() }
                .accessibilityLabel(Text(Strings.Chat.attachedImage(lang)))
        }
        .overlay(alignment: .top) { bar }
        .statusBarHidden(true)
        .accessibilityAction(.escape) { close() }
    }

    // MARK: - Chrome

    private var bar: some View {
        HStack(spacing: 12) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.42)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .background {
                        #if DEBUG
                        GeometryReader { geometry in
                            Color.clear.onAppear {
                                closeProbe?.buttonSize = geometry.size
                                closeProbe?.action = close
                            }
                        }
                        .allowsHitTesting(false)
                        #endif
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Strings.Common.close(lang)))
            .accessibilityIdentifier("attached-image-viewer-close")

            Spacer(minLength: 0)

            /* `ShareLink` over a `UIImage` gives the reader the system sheet: save to Photos, send
               it on, copy it. Nothing here writes to the library itself — that is the sheet's job
               and it is the only path that asks permission properly. */
            ShareLink(item: Image(uiImage: image), preview: SharePreview(Strings.Chat.attachedImage(lang), image: Image(uiImage: image))) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.42)))
                    .contentShape(Circle())
            }
            .accessibilityLabel(Text(Strings.Common.share(lang)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func close() {
        onClose?()
        dismiss()
    }

    // MARK: - Gestures

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { pinch = $0 }
            .onEnded { _ in
                scale = zoom
                pinch = 1
                if !isZoomed { settle() }
            }
    }

    /// Panning only means something once the picture is larger than the screen; below that the
    /// drag belongs to the cover's own dismiss.
    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard isZoomed else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard isZoomed else { return }
                offset.width += value.translation.width
                offset.height += value.translation.height
                drag = .zero
            }
    }

    private func toggleZoom() {
        withAnimation(FirasMotion.standard) {
            if isZoomed {
                settle()
            } else {
                scale = 2.5
            }
        }
    }

    private func settle() {
        scale = 1
        pinch = 1
        offset = .zero
        drag = .zero
    }
}
