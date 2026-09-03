import Foundation

/// Every sentence the app is allowed to show when something goes wrong.
///
/// `ErrorPresenter` decides **by status and error code** which of these to show; the server's own
/// sentence is never rendered (an Arabic UI must never show an English server line, and the other
/// way round). Copy marked "verbatim" is pasted from the web client through the reports in
/// `ios/Docs`; the rest is new copy written in the same voice.
extension Strings {
    enum Errors {

        // MARK: - Transport and generic

        /// `authNetworkError` — verbatim (`web-chat-ux.md` Appendix A — Guest, landing, session).
        static let offline = LText(
            ar: "تعذّر الاتصال بالخادم. تحقّق من اتصالك.",
            en: "Couldn't reach the server. Check your connection."
        )

        /// Client-side deadline expiry.
        static let timeout = LText(
            ar: "استغرق الطلب وقتًا أطول من اللازم. أعد المحاولة.",
            en: "That took longer than it should have. Try again."
        )

        /// `rate_limited` — verbatim (`server-media.md §5`, `app.js:42253`).
        static let tooFast = LText(
            ar: "طلبات كثيرة في وقت قصير. انتظر دقيقة ثمّ أعد المحاولة.",
            en: "Too many requests in a short time. Wait a minute and try again."
        )

        /// 502 / 503 `storage_unavailable`, `no_engine`, `capacity`, `agent_unavailable`.
        static let serverBusy = LText(
            ar: "الخدمة مشغولة الآن. أعد المحاولة بعد قليل.",
            en: "The service is busy right now. Try again shortly."
        )

        /// `authGenericError` — verbatim.
        static let generic = LText(
            ar: "تعذّر إتمام العملية. حاول مرة أخرى.",
            en: "Something went wrong. Please try again."
        )

        /// `errorTitle` — verbatim; used as the offline banner headline.
        static let connectionTitle = LText(ar: "تعذّر الاتصال.", en: "Couldn't connect.")

        /// `imgWhySignin` — verbatim.
        static let sessionExpired = LText(
            ar: "انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة.",
            en: "Your session ended. Sign in and try again."
        )

        // MARK: - Quota

        /// `guestLimitReached` — verbatim (`server-misc.md §13.4`).
        static let guestLimitReached = LText(
            ar: "انتهت رسائلك المجانية لهذا اليوم كضيف. أنشئ حسابًا مجانيًا للحصول على حدّ أعلى بكثير.",
            en: "You have used today's free guest messages. Create a free account for a much higher limit."
        )

        /// `quota.scope == "network"` — new copy; the web does not distinguish this bucket yet.
        static let guestNetworkLimit = LText(
            ar: "بلغ هذا الاتصال حدّ التجربة المشترك لهذا اليوم. أنشئ حسابًا مجانيًا للمتابعة بلا هذا السقف.",
            en: "This connection has reached today's shared trial limit. Create a free account to carry on without it."
        )

        /// The member 🚦 sentence — verbatim (`server-misc.md §13.4`).
        /// First `%@` is the product name, second `%@` is the limit (Arabic-Indic digits in ar).
        static let quotaMember = LText(
            ar: "🚦 بلغت الحدّ اليومي من %@ (%@/يوم). يتجدّد تلقائيًا بعد منتصف الليل.\n\nفِراس مجاني بالكامل — هذا السقف موجود ليبقى المحرّك متاحًا للجميع، وهو مرتفع لدرجة أن الاستخدام الطبيعي لا يبلغه.",
            en: "🚦 You've reached today's limit of %@ (%@/day). It resets automatically after midnight.\n\nFiras is completely free — this ceiling only keeps the engine available for everyone, and it is set high enough that ordinary use never reaches it."
        )

        /// The quota product names — verbatim, keyed by the server's `quota.product`.
        static let productNames: [String: LText] = [
            "ai": LText(ar: "رسائل فِراس AI", en: "Firas AI messages"),
            "code": LText(ar: "طلبات فِراس Code", en: "Firas Code requests"),
            "agent": LText(ar: "مهام فِراس Agent", en: "Firas Agent tasks"),
            "brain": LText(ar: "أسئلة فِراس Brain", en: "Firas Brain questions")
        ]

        /// Fallback for `internal`, `voice` and anything unknown — verbatim.
        static let productNameFallback = LText(ar: "الرسائل", en: "messages")

        static func productName(_ key: String?) -> LText {
            guard let key, let name = productNames[key.lowercased()] else { return productNameFallback }
            return name
        }

        // MARK: - Max tier (legacy ceiling, kept)

        /// `maxLimitText` auth branch — verbatim (`web-chat-ux.md §3.2`).
        static let maxAuth = LText(
            ar: "🔒 يجب تسجيل الدخول لاستخدام فِراس ماكس.",
            en: "🔒 Please sign in to use Firas Max."
        )

        /// `maxLimitText` limit branch — verbatim; `%@` is the limit.
        static let maxLimit = LText(
            ar: "👑 لقد وصلت إلى حدّك اليومي من فِراس ماكس (%@ رسائل في اليوم). استخدم أولترا أو برو الآن، وسيتجدّد ماكس غداً.",
            en: "👑 You've reached your daily Firas Max limit (%@ messages per day). Use Ultra or Pro for now — Max resets tomorrow."
        )

        // MARK: - Auth field errors (400 / 401 / 409)

        /// The server answers in English here; these replace it.
        static let credentials = LText(
            ar: "البريد أو كلمة المرور غير صحيحة.",
            en: "That email or password is not correct."
        )

        /// 500 on login — the server's "valid input" trap.
        static let credentialsOrGoogle = LText(
            ar: "تعذّر تسجيل الدخول. تأكّد من البريد وكلمة المرور، أو ادخل عبر Google.",
            en: "Couldn't sign you in. Check the email and password, or continue with Google."
        )

        static let nameRequired = LText(ar: "الاسم مطلوب.", en: "Your name is required.")

        static let emailInvalid = LText(ar: "أدخل بريدًا إلكترونيًا صحيحًا.", en: "Enter a valid email address.")

        static let passwordShort = LText(
            ar: "كلمة المرور يجب أن تكون ٨ أحرف على الأقل.",
            en: "The password must be at least 8 characters."
        )

        static let emailTaken = LText(
            ar: "هذا البريد مسجّل بالفعل. سجّل الدخول بدلًا من ذلك.",
            en: "That email is already registered. Sign in instead."
        )

        /// The server's own Arabic sentence for a Google-only account, with an English twin.
        static let googleAccount = LText(
            ar: "هذا الحساب يسجّل عبر Google، لذلك لا كلمة مرور له.",
            en: "This account signs in with Google, so it has no password."
        )

        static let tooManyAttempts = LText(
            ar: "محاولات كثيرة. انتظر دقيقة ثمّ أعد المحاولة.",
            en: "Too many attempts. Wait a minute and try again."
        )

        // MARK: - Media

        /// `bad_image` / `image_too_large` — verbatim (`server-media.md §5`).
        static let badImage = LText(
            ar: "تعذّرت قراءة الصورة المرفقة.",
            en: "That attached image could not be read."
        )

        /// `imgWhyEngine` — verbatim.
        static let imageEngineFailed = LText(
            ar: "لم يُعدِ المحرّك صورة.",
            en: "The engine returned no picture."
        )

        /// `imageLimitText` daily branch — verbatim; `%@` is the limit.
        static let imageDailyLimit = LText(
            ar: "🌙 لقد وصلت إلى الحدّ اليومي لإنشاء الصور (%@ صور في اليوم). يمكنك إنشاء المزيد غداً.",
            en: "🌙 You've reached your daily image limit (%@ images per day). You can create more tomorrow."
        )

        /// `imgWhyQuota` — verbatim (the card variant, no number).
        static let imageQuotaCard = LText(
            ar: "بلغت حدّك اليومي من الصور. الحدّ يتجدّد غدًا.",
            en: "You have reached today's image limit. It resets tomorrow."
        )

        /// Video card generic failure — verbatim (`app.js:4784`).
        static let videoFailed = LText(ar: "تعذّر توليد الفيديو", en: "Video generation failed")

        /// Video `daily_limit` — verbatim (`app.js:4785`).
        static let videoDailyLimit = LText(
            ar: "بلغت حدّك اليومي من الفيديو. جرّب بعدين.",
            en: "Daily video limit reached."
        )

        /// Music generic failure — verbatim (`app.js:4596-4603`).
        static let musicFailed = LText(ar: "ما ضبط التلحين", en: "The song did not come out")

        /// Music `rate_window` / `daily_limit` — verbatim.
        static let musicRateWindow = LText(
            ar: "لقد وصلت إلى الحد — يرجى الانتظار ساعتين",
            en: "You have reached the limit — please wait two hours"
        )

        /// `rate_window` with a real `freesInMin`; `%@` is the number of minutes.
        static let mediaRateWindow = LText(
            ar: "لقد وصلت إلى الحد — يرجى الانتظار %@ دقيقة",
            en: "You have reached the limit — please wait %@ minutes"
        )

        /// `site_media_ceiling` — the whole site, not this account.
        static let mediaBusyToday = LText(
            ar: "الخدمة مشغولة اليوم، جرّب لاحقًا.",
            en: "The service is busy today — try again later."
        )

        // MARK: - Agent (server-agent.md §11.2, verbatim)

        static let agentBusy = LText(
            ar: "توجد مهمة أخرى قيد التنفيذ، ورصيدها محجوز مؤقتًا. افتح المهمة الجارية لمتابعتها.",
            en: "Another task is still running and its credits are temporarily reserved. Open it to follow the work."
        )

        static let agentCreditsSpent = LText(
            ar: "استُهلك رصيد اليوم. يتجدّد تلقائيًا في الموعد الموضّح أعلاه.",
            en: "Today's credits have been used. They refresh automatically at the time shown above."
        )

        static let agentCreditsReserved = LText(
            ar: "الرصيد محجوز مؤقتًا لمهمة سابقة، لذلك لم تُنشأ مهمة مكررة.",
            en: "Credits are temporarily reserved for an earlier task, so no duplicate task was created."
        )

        static let agentSignIn = LText(
            ar: "سجّل الدخول أو أنشئ حسابًا مجانيًا لبدء هذه المهمة. طلبك ما زال محفوظًا.",
            en: "Sign in or create a free account to start this task. Your request is still saved."
        )

        static let agentFailed = LText(
            ar: "تعذّر إكمال المهمة. لم تُحوَّل إلى أداة أخرى؛ أعد المحاولة.",
            en: "The task could not be completed right now. It was not switched to another tool; you can retry."
        )

        // MARK: - Code build (server-code-brainask.md §2.6-2.7, verbatim)

        static let codeBuildFailed = LText(
            ar: "لم يكتمل الإنشاء — أعد المحاولة، أو أضِف تفاصيل للوصف",
            en: "Build didn't complete — retry, or add more detail to your description"
        )

        static let codeEngineUnreachable = LText(
            ar: "تعذّر الاتصال بمحرّك الذكاء — أعد المحاولة",
            en: "AI engine unavailable — retry"
        )

        // MARK: - Brain (server-brain.md §15 `engineFail`, verbatim)

        static let brainEngineFailed = LText(
            ar: "تعذّر الوصول للمحرّك. حاول مرة أخرى.",
            en: "Couldn't reach the engine. Please try again."
        )

        // MARK: - Features the deployment has not configured

        static let featureUnavailable = LText(
            ar: "هذه الميزة غير مهيّأة على الخادم بعد.",
            en: "This feature is not configured on the server yet."
        )

        static let videoNotConfigured = LText(
            ar: "محرّك الفيديو غير مهيّأ بعد",
            en: "The video engine is not configured yet"
        )

        static let musicNotConfigured = LText(
            ar: "محرّك الموسيقى غير مهيّأ بعد",
            en: "The music engine is not configured yet"
        )
    }
}
