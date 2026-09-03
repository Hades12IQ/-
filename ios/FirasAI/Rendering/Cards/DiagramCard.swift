import Photos
import SwiftUI
import UIKit

/// The card a drawing lives in: a titled surface, the figure, and the four things a reader wants to
/// do with a picture — open it, keep it, send it, read its source.
///
/// Calm on purpose (`شيل الخضار…خلي ناعم نفس كلود`): one hairline surface, one quiet head, a row of
/// plain icon buttons, and no colour of its own. The figure inside carries the only saturation on
/// the row, and it carries it because a graph without colour is a worse graph.
///
/// Three states, all of them real:
/// * **drawn** — the figure, at the exact height the island measured, tappable into full screen.
/// * **held back** — an implicit 3D solid costs millions of root-bisections, so it waits behind a
///   Run button instead of freezing the transcript the moment it scrolls into view.
/// * **undrawable** — never an empty box: a sentence in Arabic saying what happened, and the source
///   the model actually wrote, so the reader can see the answer even when the picture failed.
struct DiagramCard: View {

    private let spec: DiagramSpec
    private let palette: FirasPalette
    private let lang: AppLanguage
    private let motionOn: Bool

    @State private var link = DiagramIslandLink()
    @State private var height: CGFloat = 0
    @State private var phase: DiagramIsland.Phase = .loading
    @State private var runToken = 0
    @State private var isOnScreen = false
    @State private var isFullScreen = false
    @State private var showsSource = false
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
        VStack(alignment: .leading, spacing: 0) {
            head
            divider
            stage
            divider
            actions
        }
        .surfaceCard(palette)
        .frame(maxWidth: DiagramCard.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .fullScreenCover(isPresented: $isFullScreen) {
            DiagramFullScreenView(spec: spec, palette: palette, lang: lang, motionOn: motionOn)
        }
        .sheet(isPresented: $isSharing) {
            DiagramShareSheet(items: shareImage.map { [$0] } ?? [])
        }
    }

    // MARK: - Head

    private var head: some View {
        HStack(spacing: 8) {
            Image(systemName: DiagramCard.symbol(for: spec.mode))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
            Text(DiagramCardCopy.title(for: spec.mode)(lang))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let feedback {
                Text(feedback)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .bidiIsland(for: DiagramCardCopy.title(for: spec.mode)(lang), fallback: lang)
        .animation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn), value: feedback)
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.border)
            .frame(height: 1)
    }

    // MARK: - Stage

    @ViewBuilder
    private var stage: some View {
        switch phase {
        case .failed(let reason):
            fallback(reason: reason)
        case .waitingToRun:
            runPlate
        case .loading, .ready:
            figure
        }
    }

    private var figure: some View {
        ZStack {
            if isOnScreen {
                DiagramIsland(
                    spec: spec,
                    palette: palette,
                    interactive: false,
                    runToken: runToken,
                    link: link,
                    onHeight: { measured in
                        guard measured > 1 else { return }
                        height = measured
                    },
                    onPhase: { next in phase = next }
                )
            }
            if phase == .loading {
                FirasActivityLabel(
                    text: DiagramCardCopy.drawing(lang),
                    palette: palette,
                    motionOn: motionOn
                )
            }
        }
        .frame(height: stageHeight)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { openFullScreen() }
        .accessibilityElement()
        .accessibilityLabel(Text(DiagramCardCopy.title(for: spec.mode)(lang)))
        .accessibilityHint(Text(DiagramCardCopy.openFull(lang)))
        .accessibilityAddTraits(.isButton)
    }

    private var stageHeight: CGFloat {
        height > 1 ? min(height, 560) : DiagramCard.placeholderHeight(for: spec.mode)
    }

    private var runPlate: some View {
        VStack(spacing: 12) {
            Text(DiagramCardCopy.runHint(lang))
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.select()
                phase = .loading
                runToken += 1
            } label: {
                Text(DiagramCardCopy.run(lang))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(palette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .bidiIsland(for: DiagramCardCopy.runHint(lang), fallback: lang)
    }

    // MARK: - Fallback

    private func fallback(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(DiagramCardCopy.failedTitle(lang))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(DiagramCardCopy.reason(for: reason)(lang))
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(FirasMotion.gated(FirasMotion.standard, motionOn: motionOn)) {
                    showsSource.toggle()
                }
            } label: {
                Text(showsSource ? DiagramCardCopy.hideSource(lang) : DiagramCardCopy.showSource(lang))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsSource {
                sourceBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .bidiIsland(for: DiagramCardCopy.failedTitle(lang), fallback: lang)
    }

    private var sourceBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(spec.source)
                .font(FirasType.mono)
                .foregroundStyle(palette.textPrimary)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxHeight: 220)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.surfaceSunken)
        }
        .forceLTR()
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 2) {
            if phase == .ready {
                FirasIconButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    label: DiagramCardCopy.openFull(lang),
                    palette: palette,
                    action: openFullScreen
                )
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
            FirasIconButton(
                symbol: "doc.on.doc",
                label: DiagramCardCopy.copySource(lang),
                palette: palette,
                action: copySource
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .forceLTR()
    }

    // MARK: - Behaviour

    private func openFullScreen() {
        guard phase == .ready else { return }
        Haptics.select()
        isFullScreen = true
    }

    private func copySource() {
        UIPasteboard.general.string = spec.source
        Haptics.select()
        flash(Strings.Common.copied(lang))
    }

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

    /// A short line in the card's head instead of a global toast: the card owns this feedback, and
    /// `Rendering/` never reaches for a store.
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

    // MARK: - Constants

    private static let maximumWidth: CGFloat = 520

    /// What the card reserves before the island reports its real height. The 2D figure is 480×300
    /// and the 3D one 480×360 in their own units, so at a typical column width these land within a
    /// few points of the truth and the row never jumps.
    private static func placeholderHeight(for mode: DiagramSpec.Mode) -> CGFloat {
        switch mode {
        case .surface, .implicitSurface: return 260
        case .tikz: return 200
        default: return 230
        }
    }

    static func symbol(for mode: DiagramSpec.Mode) -> String {
        switch mode {
        case .cartesian, .implicitCurve: return "function"
        case .polar, .parametric: return "chart.xyaxis.line"
        case .surface, .implicitSurface: return "cube.transparent"
        case .geometry: return "triangle"
        case .tikz: return "ruler"
        case .unknown: return "chart.xyaxis.line"
        }
    }
}

// MARK: - Share sheet

struct DiagramShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Copy

/// Arabic first. The failure sentences are chosen by code from the island's reason token — never a
/// sentence handed over from anywhere else (`ARCHITECTURE.md §2.15`).
enum DiagramCardCopy {

    static let openFull = LText(ar: "ملء الشاشة", en: "Full screen")
    static let saveImage = LText(ar: "حفظ الصورة", en: "Save image")
    static let copySource = LText(ar: "نسخ المصدر", en: "Copy source")
    static let drawing = LText(ar: "يرسم الشكل…", en: "Drawing…")
    static let close = LText(ar: "إغلاق", en: "Close")

    static let savedToPhotos = LText(ar: "حُفظت في الصور", en: "Saved to Photos")
    static let saveFailed = LText(ar: "تعذّر الحفظ", en: "Could not save")
    static let photosDenied = LText(
        ar: "لم يُسمح بالإضافة إلى الصور.",
        en: "Adding to Photos was not allowed."
    )

    static let run = LText(ar: "ارسمه", en: "Draw it")
    static let runHint = LText(
        ar: "مجسّم ثلاثي الأبعاد يحتاج حسابًا ثقيلًا. اضغط لرسمه.",
        en: "A 3D solid needs a heavy pass. Tap to draw it."
    )

    static let failedTitle = LText(ar: "تعذّر رسم الشكل", en: "The figure could not be drawn")
    static let showSource = LText(ar: "اعرض المصدر", en: "Show source")
    static let hideSource = LText(ar: "أخفِ المصدر", en: "Hide source")

    static let whyParse = LText(
        ar: "ما وصل ليس معادلة ولا شكلًا نعرف رسمه. هذا نصّه كما كتبه فِراس.",
        en: "This is not an equation or a shape we can draw. Here is what Firas wrote."
    )
    static let whyEmpty = LText(
        ar: "لا شيء يظهر داخل هذا المجال — جرّب مجالًا أوسع.",
        en: "Nothing falls inside this range — try a wider one."
    )
    static let whyTikz = LText(
        ar: "رسم TikZ هذا يستعمل أوامر خارج ما نفهمه هنا. هذا مصدره كما كُتب.",
        en: "This TikZ picture uses commands we do not read here. Here is its source."
    )
    static let whyEngine = LText(
        ar: "تعثّر محرّك الرسم قبل أن يكتمل الشكل.",
        en: "The drawing engine stopped before the figure was finished."
    )

    static func reason(for code: String) -> LText {
        switch code {
        case DiagramIsland.Reason.parse: return whyParse
        case DiagramIsland.Reason.empty: return whyEmpty
        case DiagramIsland.Reason.tikz: return whyTikz
        default: return whyEngine
        }
    }

    static func title(for mode: DiagramSpec.Mode) -> LText {
        switch mode {
        case .cartesian: return LText(ar: "رسم دالة", en: "Function graph")
        case .polar: return LText(ar: "رسم قطبي", en: "Polar graph")
        case .parametric: return LText(ar: "منحنى وسيطي", en: "Parametric curve")
        case .implicitCurve: return LText(ar: "منحنى ضمني", en: "Implicit curve")
        case .surface: return LText(ar: "سطح ثلاثي الأبعاد", en: "3D surface")
        case .implicitSurface: return LText(ar: "مجسّم ثلاثي الأبعاد", en: "3D solid")
        case .geometry: return LText(ar: "شكل هندسي", en: "Geometry figure")
        case .tikz: return LText(ar: "رسم هندسي", en: "Figure")
        case .unknown: return LText(ar: "رسم", en: "Figure")
        }
    }
}
