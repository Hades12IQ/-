import AVFoundation

/// A single legacy thumbnail request. The actor serializes installation, cancellation, and the
/// AVFoundation callback so every continuation resumes once, including cancellation before start.
actor LegacyVideoFrameRequest {
    private let generator: AVAssetImageGenerator
    private let time: CMTime
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var finished = false

    init(url: URL, time: CMTime) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        self.time = time
    }

    func image() async -> CGImage? {
        guard !finished, continuation == nil, !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                [weak self] _, image, _, result, _ in
                let frame = result == .succeeded ? image : nil
                Task { await self?.complete(frame) }
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        complete(nil)
        generator.cancelAllCGImageGeneration()
    }

    private func complete(_ image: CGImage?) {
        guard !finished else { return }
        finished = true
        let pending = continuation
        continuation = nil
        pending?.resume(returning: image)
    }
}
