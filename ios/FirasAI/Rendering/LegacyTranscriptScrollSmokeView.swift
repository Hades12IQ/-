#if DEBUG
import SwiftUI
import Perception

/// Mounted by the existing reliability route. This does not create a window or disturb WebKit's
/// attachment; it exercises the fallback even when CI has only a current iOS Simulator runtime.
struct LegacyTranscriptScrollSmokeView: View {
    let onComplete: ([String]) -> Void
    @StateObject private var model = LegacyTranscriptScrollSmokeModel()

    var body: some View {
        return WithPerceptionTracking {
        LegacyTranscriptScroll(identity: model.identity, latestUserID: model.latestUserID,
            motionOn: true, controller: model.controller) { jump in
            Button("Latest", action: jump)
        } content: {
            VStack(spacing: 0) {
                ForEach(0..<model.rows, id: \.self) { index in
                    WithPerceptionTracking {
Text("Scroll fixture \(index)")
                        .frame(maxWidth: .infinity)
                        .frame(height: index == 0 ? 100 + model.firstRowExtra : 100)
                        .background(index.isMultiple(of: 2) ? Color.gray.opacity(0.1) : Color.clear)
                        .legacyTranscriptRowAnchor("fixture-row-\(index)")

                }}
            }
        }
        .frame(height: model.viewport)
        .task { await model.run(onComplete: onComplete) }
            }
    }
}

@MainActor
private final class LegacyTranscriptScrollSmokeModel: ObservableObject {
    @Published var identity = "legacy-scroll-fixture"
    @Published var latestUserID = "initial-user"
    @Published var rows = 20
    @Published var firstRowExtra: CGFloat = 0
    @Published var viewport: CGFloat = 280
    let controller = LegacyTranscriptScrollController(pinnedThreshold: 72, chipThreshold: 72)
    private var started = false

    func run(onComplete: ([String]) -> Void) async {
        guard !started else { return }
        started = true
        var failures = Self.geometryFailures()
        await check("legacy-scroll-did-not-mount-at-measured-bottom", into: &failures) {
            guard let geometry = self.controller.debugGeometry else { return false }
            return geometry.height >= 2_000 && geometry.distance <= 1
        }
        guard controller.debugGeometry != nil else { onComplete(failures); return }
        controller.debugRead(at: 420)
        await check("legacy-scroll-could-not-read-history", into: &failures) {
            self.isOffset(420) && self.controller.showsChip && self.controller.debugAnchor != nil
        }
        let anchor = controller.debugAnchor
        firstRowExtra = 80
        await check("legacy-scroll-jumped-when-an-earlier-row-grew", into: &failures) {
            self.isOffset(500) && self.controller.debugAnchor == anchor
        }
        rows += 1
        await check("legacy-scroll-pulled-reader-down-for-a-new-answer", into: &failures) {
            (self.controller.debugGeometry?.height ?? 0) >= 2_180 && self.isOffset(500)
        }
        controller.debugReattach()
        await check("legacy-scroll-reattach-lost-reader-position", into: &failures) {
            self.isOffset(500) && self.controller.debugAnchor == anchor
        }
        viewport = 220
        await check("legacy-scroll-lost-history-anchor-on-keyboard-sized-resize", into: &failures) {
            abs((self.controller.debugGeometry?.viewport ?? 0) - 220) <= 1 && self.isOffset(500)
        }
        controller.jump(animated: true, dismissKeyboard: true)
        await check("legacy-scroll-arrow-overshot-or-never-settled", into: &failures) {
            (self.controller.debugGeometry?.distance ?? 99) <= 1 && !self.controller.debugIsAnimating
        }
        viewport = 280
        rows += 1
        await check("legacy-scroll-did-not-follow-pinned-content-and-keyboard-layout", into: &failures) {
            guard let geometry = self.controller.debugGeometry else { return false }
            return geometry.height >= 2_280 && abs(geometry.viewport - 280) <= 1 && geometry.distance <= 1
        }
        controller.debugRead(at: 200)
        latestUserID = "new-user"
        await check("legacy-scroll-send-did-not-return-to-bottom", into: &failures) {
            (self.controller.debugGeometry?.distance ?? 99) <= 1 && !self.controller.debugIsAnimating
        }
        controller.debugRead(at: 300)
        identity = "another-legacy-conversation"
        rows = 2
        await check("legacy-scroll-conversation-switch-kept-old-anchor-or-blank-space", into: &failures) {
            guard let geometry = self.controller.debugGeometry else { return false }
            return geometry.height <= 280 && geometry.distance <= 1 && abs(geometry.offsetY - geometry.minimumY) <= 1
        }
        await JobClock.rest(0.2)
        let idleRefreshes = controller.debugRefreshCount
        await JobClock.rest(0.2)
        if controller.debugHasDisplayLink || controller.debugRefreshCount - idleRefreshes > 2 {
            failures.append("legacy-scroll-kept-animating-or-invalidating-while-idle")
        }
        onComplete(failures)
    }

    private func isOffset(_ expected: CGFloat) -> Bool {
        abs((controller.debugGeometry?.offsetY ?? -999) - expected) <= 1
    }

    private func check(_ failure: String, into failures: inout [String], condition: () -> Bool) async {
        // Readiness/deadlock guard only; the result is geometry and lifecycle, never a speed claim.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            await JobClock.rest(0.02)
        }
        if !condition() { failures.append(failure) }
    }

    private static func geometryFailures() -> [String] {
        var failures: [String] = []
        let long = LegacyTranscriptGeometry(height: 2_000, viewport: 500, offsetY: 1_520,
            topInset: 44, bottomInset: 20)
        if long.maximumY != 1_520 || long.minimumY != -44 || long.distance != 0
            || long.clamp(50_000) != 1_520 || long.clamp(-500) != -44 {
            failures.append("legacy-scroll-inset-or-edge-clamping-is-wrong")
        }
        let short = LegacyTranscriptGeometry(height: 100, viewport: 500, offsetY: -44,
            topInset: 44, bottomInset: 20)
        if short.maximumY != -44 || short.distance != 0 || short.clamp(50_000) != -44 {
            failures.append("legacy-scroll-short-content-can-land-in-blank-space")
        }
        return failures
    }
}
#endif
