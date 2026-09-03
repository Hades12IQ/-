import Foundation

// Firas Brain: the document library, part-by-part ingestion, retrieval, passage reads and the
// whole-corpus answer. Wire shapes: server-brain.md §5–§10 (verified against server.mjs
// 8974-9101, 9174-9206, and the routes at 13804-13808).

extension APIClient {

    /// `GET /api/brain/docs` — reads storage directly, so it is always fresh after an upload or a
    /// delete. `limits.pagesPerDay` is `-1` for members (unmetered); show the pages line only when
    /// it is positive.
    func brainDocs() async throws -> BrainLibraryResponse {
        try await json(
            .get,
            "/api/brain/docs",
            budget: .interactive,
            as: BrainLibraryResponse.self
        )
    }

    /// `POST /api/brain/doc` — ingests **one part**. The first part omits `docId` and creates the
    /// document; every following part sends the returned id and the same `kind` (the splitter is
    /// picked per part). `ocr` rides on the first part only. Up to 1 200 page records per post.
    func brainAddDoc(_ req: BrainUploadRequest) async throws -> BrainUploadResponse {
        try await json(
            .post,
            "/api/brain/doc",
            body: req,
            budget: .upload,
            as: BrainUploadResponse.self
        )
    }

    /// `DELETE /api/brain/doc?id=` — idempotent: 200 even when the id is unknown.
    func brainDeleteDoc(id: String) async throws {
        _ = try await raw(
            .delete,
            "/api/brain/doc",
            query: ["id": id],
            budget: .interactive
        )
    }

    /// `POST /api/brain/search` — retrieval. **Every call charges one Brain answer before any
    /// retrieval happens**, including `overview`/`all` modes and an empty query, so `cid` must be
    /// the turn's id: it is the idempotency key for that charge.
    func brainSearch(_ req: BrainSearchRequest) async throws -> BrainSearchResponse {
        try await json(
            .post,
            "/api/brain/search",
            body: req,
            budget: .interactive,
            as: BrainSearchResponse.self
        )
    }

    /// `GET /api/brain/passage?doc=&i=&w=` — the cited chunk plus up to `w` neighbours on each
    /// side, restricted to the same page. Free, uncharged, uses the 60 s corpus cache.
    /// `w` is clamped 0…5 by the server; a deleted document answers 404.
    func brainPassage(docID: String, index: Int, window: Int) async throws -> BrainPassage {
        let clampedWindow = min(max(window, 0), 5)
        return try await json(
            .get,
            "/api/brain/passage",
            query: ["doc": docID, "i": String(index), "w": String(clampedWindow)],
            budget: .interactive,
            as: BrainPassage.self
        )
    }

    /// `POST /api/brain/whole` — member-only whole-corpus answer. It does not stream and has no
    /// upstream timeout, so it runs on the upload budget. A 429 carrying `quota` is a real
    /// refusal; every other failure is a decline and the retrieval path should answer instead.
    func brainWhole(_ req: BrainWholeRequest) async throws -> BrainWholeResponse {
        try await json(
            .post,
            "/api/brain/whole",
            body: req,
            budget: .upload,
            as: BrainWholeResponse.self
        )
    }
}
