import Foundation

// Studio media: image, video and music jobs, their bytes, the two quota probes and the image edit.
// Wire shapes: server-media.md §1–§3 (verified against server.mjs 3237-3249, 3922-4033,
// 4736-4995, 5138-5236, 5349-5358).

extension APIClient {

    /// `POST /api/image/job` — starts a render, or answers `phase:"done"` with the key when the
    /// prompt+size is already in the cache (identical prompt and size always yield the identical
    /// picture, so a re-roll needs different prompt text). Never send an `image` field here: any
    /// truthy value answers `501 edit_job_unsupported` — edits go through `editImage`.
    func startImageJob(_ req: ImageJobRequest) async throws -> MediaJobStartResponse {
        try await json(
            .post,
            "/api/image/job",
            body: req,
            budget: .interactive,
            as: MediaJobStartResponse.self
        )
    }

    /// `POST /api/video/job` — the window slot is charged at start, not on success.
    /// `image` (the optional first frame) must be a `data:image/…;base64,` URI or an `https://`
    /// URL; raw base64 answers `400 bad_image`.
    func startVideoJob(_ req: VideoJobRequest) async throws -> MediaJobStartResponse {
        try await json(
            .post,
            "/api/video/job",
            body: req,
            budget: .upload,
            as: MediaJobStartResponse.self
        )
    }

    /// `POST /api/music/job` — `prompt` is the style/arrangement tag line, `lyrics` the words to
    /// sing (empty means instrumental). At least one of the two must be non-empty.
    func startMusicJob(_ req: MusicJobRequest) async throws -> MediaJobStartResponse {
        try await json(
            .post,
            "/api/music/job",
            body: req,
            budget: .interactive,
            as: MediaJobStartResponse.self
        )
    }

    /// `GET /api/{image,video,music}/job?id=` — `done` with a key, `fail` with a code, or
    /// `running`. An **unknown id also answers `running`**, which is why every media job needs its
    /// own deadline rather than waiting for a terminal read.
    func mediaJobStatus(kind: MediaKind, id: String) async throws -> MediaJobStatusResponse {
        try await json(
            .get,
            MediaEndpointRoutes.statusPath(for: kind),
            query: ["id": id],
            budget: .poll,
            as: MediaJobStatusResponse.self
        )
    }

    /// The finished bytes: `GET /api/image?key=`, `GET /api/video/file?id=`,
    /// `GET /api/music/file?id=`. Video and music are streamed to a temp file — they are never
    /// held as `Data`. A 404 after a `done` phase means the render was discarded for size.
    func downloadMedia(
        kind: MediaKind,
        key: String
    ) async throws -> (url: URL, filename: String, mime: String?) {
        try await download(
            MediaEndpointRoutes.filePath(for: kind),
            query: [MediaEndpointRoutes.fileQueryKey(for: kind): key]
        )
    }

    /// `POST /api/image/quota` — read-only pre-check; the body is ignored. Charges nothing.
    /// An exhausted day answers `429` (with the counts on the error body), not a 200.
    func imageQuota() async throws -> ImageQuota {
        try await json(
            .post,
            "/api/image/quota",
            budget: .interactive,
            as: ImageQuota.self
        )
    }

    /// `GET /api/video/quota` — only `seconds` (the default clip length) is meaningful; the
    /// `limit`/`used`/`remaining` fields count the dead legacy route, never the job path.
    func videoQuota() async throws -> VideoQuota {
        try await json(
            .get,
            "/api/video/quota",
            budget: .interactive,
            as: VideoQuota.self
        )
    }

    /// `POST /api/image/edit` — synchronous; the reply arrives when the edit is finished (the
    /// upstream waits up to 180 s), hence the upload budget. A cached key comes back free and
    /// before the daily-limit check.
    func editImage(_ req: ImageEditRequest) async throws -> ImageEditResponse {
        try await json(
            .post,
            "/api/image/edit",
            body: req,
            budget: .upload,
            as: ImageEditResponse.self
        )
    }
}

// MARK: - Routes

private enum MediaEndpointRoutes {

    static func statusPath(for kind: MediaKind) -> String {
        switch kind {
        case .image: return "/api/image/job"
        case .video: return "/api/video/job"
        case .music: return "/api/music/job"
        }
    }

    static func filePath(for kind: MediaKind) -> String {
        switch kind {
        case .image: return "/api/image"
        case .video: return "/api/video/file"
        case .music: return "/api/music/file"
        }
    }

    // The image bytes are addressed by `key`; video and music by `id` (both are the same hex key).
    static func fileQueryKey(for kind: MediaKind) -> String {
        switch kind {
        case .image: return "key"
        case .video, .music: return "id"
        }
    }
}
