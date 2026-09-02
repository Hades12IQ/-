import Foundation

/// Local-notification copy.
///
/// The app has no APNs entitlement, so every job-terminal notification is posted locally — but the
/// wording is the server's own table (`server-auth-session-account.md §6.6`, `apnsLocalizedCopy`)
/// so a device that later does receive a push reads exactly the same sentence.
extension Strings {
    enum Notify {

        /// A notification's two lines.
        struct Entry: Sendable, Hashable {
            let title: LText
            let body: LText

            init(title: LText, body: LText) {
                self.title = title
                self.body = body
            }

            /// Both lines resolved at once.
            func resolved(_ lang: AppLanguage) -> (title: String, body: String) {
                (title(lang), body(lang))
            }
        }

        // MARK: - Media jobs (verbatim)

        /// `اضغط لعرض التفاصيل أو المحاولة مجددا.` — one body for all three media failures.
        static let mediaFailedBody = LText(
            ar: "اضغط لعرض التفاصيل أو المحاولة مجددا.",
            en: "Tap to view details or try again."
        )

        static func mediaReady(_ kind: MediaKind) -> Entry {
            switch kind {
            case .image:
                return Entry(
                    title: LText(ar: "صورتك جاهزة", en: "Your image is ready"),
                    body: LText(ar: "اضغط لعرض الصورة وحفظها أو مشاركتها.", en: "Tap to view, save, or share it.")
                )
            case .video:
                return Entry(
                    title: LText(ar: "فيديوك جاهز", en: "Your video is ready"),
                    body: LText(ar: "اضغط لمشاهدة الفيديو وحفظه أو مشاركته.", en: "Tap to watch, save, or share it.")
                )
            case .music:
                return Entry(
                    title: LText(ar: "أغنيتك جاهزة", en: "Your song is ready"),
                    body: LText(ar: "اضغط للاستماع إلى الأغنية وحفظها أو مشاركتها.", en: "Tap to listen, save, or share it.")
                )
            }
        }

        static func mediaFailed(_ kind: MediaKind) -> Entry {
            let title: LText
            switch kind {
            case .image:
                title = LText(ar: "تعذر إنشاء الصورة", en: "Your image could not be created")
            case .video:
                title = LText(ar: "تعذر إنشاء الفيديو", en: "Your video could not be created")
            case .music:
                title = LText(ar: "تعذر إنشاء الأغنية", en: "Your song could not be created")
            }
            return Entry(title: title, body: mediaFailedBody)
        }

        // MARK: - Non-media jobs (verbatim)

        /// `إجابة فِراس` / `مهمة وكيل فِراس` / `مشروع فِراس كود` / `بحث فِراس برين`.
        static func productName(_ product: ProductKind) -> LText {
            switch product {
            case .ai, .studio:
                return LText(ar: "إجابة فِراس", en: "Firas answer")
            case .agent:
                return LText(ar: "مهمة وكيل فِراس", en: "Firas Agent mission")
            case .code:
                return LText(ar: "مشروع فِراس كود", en: "Firas Code project")
            case .brain:
                return LText(ar: "بحث فِراس برين", en: "Firas Brain search")
            }
        }

        static let productDoneBody = LText(ar: "اضغط لعرض النتيجة.", en: "Tap to view the result.")

        static let productFailedBody = LText(
            ar: "اضغط لعرض التفاصيل أو المحاولة مجدداً.",
            en: "Tap to view details or try again."
        )

        static func productDone(_ product: ProductKind) -> Entry {
            let name = productName(product)
            return Entry(
                title: LText(ar: name.ar + " اكتملت", en: name.en + " is ready"),
                body: productDoneBody
            )
        }

        static func productFailed(_ product: ProductKind) -> Entry {
            let name = productName(product)
            return Entry(
                title: LText(ar: name.ar + " لم تكتمل", en: name.en + " could not finish"),
                body: productFailedBody
            )
        }

        /// One call for either outcome.
        static func job(product: ProductKind, mediaKind: MediaKind?, succeeded: Bool) -> Entry {
            if let mediaKind {
                return succeeded ? mediaReady(mediaKind) : mediaFailed(mediaKind)
            }
            return succeeded ? productDone(product) : productFailed(product)
        }

        // MARK: - Call ended while the app was in the background

        static let callEndedTitle = LText(ar: "انتهت المكالمة", en: "Call ended")

        /// `reason` comes from `CallEngine`'s end reason; unknown reasons fall back to the plain line.
        static func callEnded(reason: String) -> Entry {
            let key = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let body: LText
            switch key {
            case "timelimit", "time_limit", "maxduration", "max_duration":
                body = LText(ar: "انتهت مدة المكالمة.", en: "The call reached its time limit.")
            case "idle", "silence":
                body = LText(ar: "انتهت المكالمة بعد فترة صمت.", en: "The call ended after a quiet stretch.")
            case "guestcap", "guest_cap":
                body = LText(
                    ar: "انتهت مدة المكالمة المسموحة للضيف. أنشئ حسابًا مجانيًا للمتابعة بلا حدود.",
                    en: "The guest call limit was reached. Create a free account to keep talking."
                )
            case "failed", "error", "disconnected":
                body = LText(ar: "انقطعت المكالمة.", en: "The call was disconnected.")
            default:
                body = LText(ar: "انتهت مكالمتك مع فِراس.", en: "Your call with Firas has ended.")
            }
            return Entry(title: callEndedTitle, body: body)
        }

        // MARK: - Permission explainer (shown once, after the first accepted job)

        static let permissionTitle = LText(
            ar: "تنبيه عند اكتمال المهمة",
            en: "A nudge when the work is done"
        )

        static let permissionBody = LText(
            ar: "سيصلك تنبيه عندما تنتهي المهمة — عادةً خلال دقائق. المهمة تُكمل على الخادم حتى لو أغلقت التطبيق.",
            en: "You'll get a notification when the task finishes — usually within minutes. The work continues on the server even if you close the app."
        )

        static let permissionAllow = LText(ar: "فعّل التنبيهات", en: "Turn on notifications")

        static let permissionDenied = LText(
            ar: "التنبيهات مغلقة. فعّلها من إعدادات النظام لتصلك نتيجة المهام.",
            en: "Notifications are off. Turn them on in system settings to hear when a task finishes."
        )
    }
}
