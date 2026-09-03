import SwiftUI

/// The second lock on the door a file card opens.
///
/// `AssistantFileSheet` itself is declared at the foot of `AssistantTurnView.swift`, and it stays
/// there. This file only ADDS to it. Moving the struct here would mean deleting it there, and two
/// declarations of one name is a build that never happens — on the last build anybody intends to
/// download, that is not a tidiness worth spending.
///
/// WHY THERE IS A SECOND LOCK AT ALL. A document turn writes its ```` ```firas-file ```` metadata
/// block FIRST and its HTML design after it, so the card exists for the whole minute the document
/// does not. `FileCard` now refuses to draw Open, Share or Save until the answer has reached a
/// terminal status, which closes the door a reader can actually see. The lock below closes the one
/// they cannot: `DocumentHTML.authored` accepts an unterminated `html` fence as a finished page —
/// deliberately, because a model that ran out of room still designed something — so a preview
/// raised mid-stream does not fail. It succeeds. It hands over a real PDF of half a document with
/// nothing on it to say which half is missing, and there is no error afterwards to catch. The only
/// place to refuse is before.
extension AssistantFileSheet {

    /// The route, or `nil` when the answer is not finished and therefore neither is the file.
    ///
    /// Use it in place of the initialiser wherever a sheet is raised from a turn that might still
    /// be streaming — `AssistantTurnView+Fences.buildFile` is the one such place today:
    ///
    /// ```swift
    /// fileSheet = AssistantFileSheet.route(intent, export: built, answerFinished: settled)
    /// ```
    ///
    /// Returning `nil` rather than throwing or toasting is the honest shape: there is nothing to
    /// apologise for. The reader pressed a button that the card, correctly wired, does not offer
    /// yet; the sheet simply does not open, and the card goes on saying the file is being prepared.
    static func route(
        _ intent: Intent,
        export: ExportController.Export,
        answerFinished: Bool
    ) -> AssistantFileSheet? {
        guard answerFinished else { return nil }
        return AssistantFileSheet(intent: intent, export: export)
    }
}
