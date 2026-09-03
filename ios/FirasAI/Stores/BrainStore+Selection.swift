import Foundation

// The selection model: which documents a question searches, the pins that hold documents in, the
// page window and the compare arming (`web-brain-ux.md §5.2, §5.3, §10, §13`).
//
// The persisted set is the *excluded* one, so a document added later arrives selected; the pins are
// reconciled on every library read.
extension BrainStore {

    /// A pinned row ignores the tap (`web-brain-ux.md §5.2`).
    func toggleExcluded(_ id: String) {
        guard !pins.contains(id) else { return }
        if excluded.contains(id) {
            excluded.remove(id)
        } else {
            excluded.insert(id)
        }
        persistSelection()
        dropRangeIfSelectionChanged()
        if compareArmed && activeDocIDs.count != 2 { compareArmed = false }
    }

    func togglePin(_ id: String) {
        if pins.contains(id) {
            pins.remove(id)
        } else {
            pins.insert(id)
            excluded.remove(id)
        }
        if pins.count > 40 {
            pins = Set(docs.map(\.id).filter { pins.contains($0) }.suffix(40))
        }
        persistSelection()
        dropRangeIfSelectionChanged()
    }

    /// Tapping the pin chip clears every pin; it does not re-include what they held out.
    func clearPins() {
        pins.removeAll()
        persistSelection()
    }

    /// Both empty clears it; only `from` means "to the end"; only `to` means "from page one";
    /// reversed values are swapped (`web-brain-ux.md §10.1`).
    func setRange(from: Int?, to: Int?) {
        let lower = from.flatMap { $0 > 0 ? max(1, $0) : nil }
        let upper = to.flatMap { $0 > 0 ? max(1, $0) : nil }
        switch (lower, upper) {
        case (nil, nil):
            range = nil
        case (.some(let low), nil):
            range = low...1_000_000_000
        case (nil, .some(let high)):
            range = 1...high
        case (.some(let low), .some(let high)):
            range = min(low, high)...max(low, high)
        }
        rangeKey = selectionKey
    }

    func clearRange() {
        range = nil
    }

    func toggleCompare() {
        guard !isAsking else { return }
        if compareArmed {
            compareArmed = false
            return
        }
        guard activeDocIDs.count == 2 else {
            toasts.show(Strings.Brain.compareNeedsTwo(prefs.lang))
            return
        }
        compareArmed = true
        Haptics.select()
        toasts.show(Strings.Brain.compareOn(prefs.lang))
    }

    var selectionKey: String { activeDocIDs.joined(separator: ",") }

    func dropRangeIfSelectionChanged() {
        guard range != nil else { return }
        if rangeKey != selectionKey { range = nil }
    }

    /// `§5.3` — pins for deleted documents are dropped, pinned documents are forced into the
    /// selection, and while any pin is live a document seen for the first time arrives excluded.
    func applyPins() {
        let ids = docs.map(\.id)
        let known = Set(ids)
        pins = pins.intersection(known)
        excluded = excluded.intersection(known)

        if !pinSeenSeeded {
            if !ids.isEmpty {
                pinSeen = known
                pinSeenSeeded = true
            }
        } else if !pins.isEmpty {
            for id in ids where !pinSeen.contains(id) {
                excluded.insert(id)
            }
            pinSeen.formUnion(known)
        } else {
            pinSeen.formUnion(known)
        }

        excluded.subtract(pins)
        persistSelection()
    }

    // MARK: - Device persistence (namespaced by identity, `web-brain-ux.md §13`)

    var storageOwner: String { session.identityID ?? "guest" }

    func loadSelectionIfNeeded() {
        let owner = storageOwner
        guard selectionLoadedFor != owner else { return }
        selectionLoadedFor = owner
        excluded = Set(defaults.stringArray(forKey: "firas_brain_sel_" + owner) ?? [])
        pins = Set(defaults.stringArray(forKey: "firas_brain_pin_" + owner) ?? [])
        pinSeen = []
        pinSeenSeeded = false
    }

    func persistSelection() {
        let owner = storageOwner
        defaults.set(Array(excluded), forKey: "firas_brain_sel_" + owner)
        defaults.set(Array(pins.prefix(40)), forKey: "firas_brain_pin_" + owner)
    }
}
