import Foundation
import Observation

/// The facts the server keeps about the signed-in member ("what Firas remembers about you").
///
/// The list is member-only: `GET /api/memory` answers 401 for a guest, so every screen gates on
/// identity **before** calling — a guest sees the sign-up prompt, never a failed request.
///
/// The handle for one entry is its **position** in the array the server returns
/// (`DELETE /api/memory?i=<index>`), which is why a delete is always followed by a reload: every
/// entry after the removed one has just changed id.
@MainActor
@Observable
final class MemoryStore {

    private(set) var entries: [MemoryEntry] = []

    private(set) var isLoading = false
    private(set) var isMutating = false
    /// Kept as an `LText` rather than a resolved string: this store is built with the API client
    /// alone (the frozen initialiser), so it has no view of the language preference, and a string
    /// resolved here would go stale the moment the reader switches languages.
    private(set) var failure: LText?
    /// Distinguishes "not fetched yet" from "fetched and empty".
    private(set) var hasLoaded = false

    @ObservationIgnored private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    // MARK: - Loading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            entries = try await api.memory()
            failure = nil
            hasLoaded = true
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// Drops everything this store holds — called when the identity changes so one member's facts
    /// are never shown to the next.
    func reset() {
        entries = []
        failure = nil
        hasLoaded = false
    }

    // MARK: - Deleting

    /// `nil` clears the whole list. The reload afterwards is not politeness: the ids are indices.
    func delete(id: String?) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }

        // Take the row away immediately — the request is a confirmation, not a question — and put
        // it back if the server refuses.
        let previous = entries
        if let id {
            entries.removeAll { $0.id == id }
        } else {
            entries = []
        }

        do {
            try await api.deleteMemory(id: id)
            failure = nil
        } catch {
            entries = previous
            failure = Self.message(for: error)
            return
        }
        await load()
    }

    // MARK: - Learning

    /// Fire and forget: the server runs three extractions and takes seconds. Nothing waits on it,
    /// and a failure is invisible by design (`web-auth-account-settings.md §7`).
    func learn(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let bounded = String(trimmed.prefix(4_000))
        Task { [api] in
            try? await api.memoryLearn(text: bounded)
        }
    }

    // MARK: - Errors

    /// `ErrorPresenter` decides by status and code; only the `LText` half of its answer is kept,
    /// because the language is chosen at render time.
    private static func message(for error: Error) -> LText {
        switch ErrorPresenter.present(error, feature: .memory, isGuest: false, lang: .arabic) {
        case .toast(let text):
            return text
        case .sessionExpired:
            return Strings.Errors.sessionExpired
        default:
            return Strings.Errors.generic
        }
    }
}
