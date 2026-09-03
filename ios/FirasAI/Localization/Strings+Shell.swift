import Foundation

/// Copy for the navigation shell: the drawer, the sidebar, the product switcher, the history list,
/// the account pill, the toast host and the hardware-keyboard layer.
///
/// Arabic is verbatim from the web tables cited beside each block (`web-chat-ux.md §2, §11, §14,
/// Appendix A`, `web-auth-account-settings.md §4, §5.5`, `web-agent-ux.md §10`,
/// `design-brief.md §7.2`). The two sentences the web has no equivalent for — the native Code
/// subtitle and the Studio subtitle — are marked `[new]` in the brief and written here once.
extension Strings {

    enum Shell {

        // MARK: - Drawer and sidebar chrome

        /// The drawer's own name, used as the accessibility label of the panel.
        static let drawerTitle = LText(ar: "المحادثات", en: "Conversations")
        static let openSidebar = LText(ar: "افتح قائمة المحادثات", en: "Open the conversations panel")
        static let closeSidebar = LText(ar: "أغلق قائمة المحادثات", en: "Close the conversations panel")
        /// The sidebar shows ten conversations; this row opens the rest as a full page.
        static let allChats = LText(ar: "كل المحادثات", en: "All chats")
        /// `#notifyBtn` title.
        static let announcements = LText(ar: "تحديثات الموقع", en: "Site updates")
        static let announcementsUnseen = LText(ar: "تحديثات غير مقروءة", en: "Unread updates")

        // MARK: - Product switcher (`web-chat-ux.md §2`, `design-brief.md §7.2`)

        static let productsHeader = LText(ar: "المنتجات", en: "Products")

        static let subtitleAI = LText(ar: "المحادثة الذكية", en: "Smart chat")
        static let subtitleAgent = LText(ar: "وكيل ينفّذ المهام الكبيرة", en: "Executes big tasks")
        /// `[new]` — the web says «بيئة تطوير بالمتصفح»; there is no browser here.
        static let subtitleCode = LText(
            ar: "بيئة تطوير كاملة مع مساعد ذكي",
            en: "A full development environment with an AI assistant"
        )
        static let subtitleBrain = LText(
            ar: "اسأل ملفاتك — بإجابات موثّقة بالصفحة",
            en: "Ask your files — answers cited by page"
        )
        /// `[new]` — the native-only fifth product.
        static let subtitleStudio = LText(ar: "صور وفيديو وأغاني", en: "Images, video and songs")

        static func subtitle(for product: ProductKind) -> LText {
            switch product {
            case .ai: return subtitleAI
            case .agent: return subtitleAgent
            case .code: return subtitleCode
            case .brain: return subtitleBrain
            case .studio: return subtitleStudio
            }
        }

        /// `railActivity` — one running job, then the counted form.
        static let runningOne = LText(ar: "مهمة تشتغل الآن", en: "1 running now")
        /// `%@` = an Arabic-Indic count in Arabic, Latin in English.
        static let runningMany = LText(ar: "%@ مهام تشتغل الآن", en: "%@ running now")

        // MARK: - Search (`searchPlaceholder`)

        static let searchPlaceholder = LText(ar: "ابحث في المحادثات", en: "Search conversations")
        static let searchClear = LText(ar: "امسح البحث", en: "Clear the search")
        /// The scope line shown once the query is long enough to read message bodies.
        static let searchInMessages = LText(
            ar: "داخل الرسائل — من المحادثات المفتوحة فقط",
            en: "In messages — opened conversations only"
        )

        // MARK: - History groups (`groupKey`)

        static let groupPinned = LText(ar: "المثبّتة", en: "Pinned")
        static let groupToday = LText(ar: "اليوم", en: "Today")
        static let groupYesterday = LText(ar: "أمس", en: "Yesterday")
        static let groupPrevious7 = LText(ar: "آخر ٧ أيام", en: "Previous 7 days")
        static let groupPrevious30 = LText(ar: "آخر ٣٠ يومًا", en: "Previous 30 days")
        static let groupOlder = LText(ar: "أقدم", en: "Older")

        // MARK: - Row actions

        static let pin = LText(ar: "تثبيت", en: "Pin")
        static let unpin = LText(ar: "إلغاء التثبيت", en: "Unpin")
        static let renamePrompt = LText(ar: "اسم المحادثة", en: "Conversation name")
        /// `paintLiveRows` — the accessibility label of the live dot.
        static let stillWorking = LText(ar: "ما زالت تشتغل", en: "still working")
        static let untitledChat = LText(ar: "محادثة بلا عنوان", en: "Untitled conversation")

        // MARK: - Empty and error states

        /// Named apart from `emptyHistory(for:)` so a stored property and a method never share a
        /// base name inside one type — and so the switch below cannot resolve to itself.
        static let emptyHistoryAI = LText(
            ar: "لا توجد محادثات بعد — اضغط «محادثة جديدة» للبدء.",
            en: "No conversations yet — press “New chat” to begin."
        )
        static let emptyHistoryAgent = LText(
            ar: "لا توجد مهام بعد — اضغط «محادثة جديدة» وصِف مهمتك.",
            en: "No missions yet — press “New chat” and describe your task."
        )
        static let emptyHistoryCode = LText(
            ar: "لا توجد مشاريع بعد — اضغط «محادثة جديدة» لبناء مشروعك الأول.",
            en: "No projects yet — press “New chat” to build your first one."
        )
        static let emptyHistoryBrain = LText(
            ar: "لا توجد محادثات بعد — ارفع ملفاتك واسأل عنها، والإجابة تجيك موثّقة بالصفحة.",
            en: "No conversations yet — upload your files and ask; every answer cites its page."
        )

        static func emptyHistory(for product: ProductKind) -> LText {
            switch product {
            case .agent: return emptyHistoryAgent
            case .code: return emptyHistoryCode
            case .brain: return emptyHistoryBrain
            case .ai, .studio: return emptyHistoryAI
            }
        }

        static let searchEmptyTitle = LText(ar: "لا توجد نتائج.", en: "No results.")
        static let searchEmptySubtitle = LText(
            ar: "جرّب كلمة أخرى، أو افتح محادثة لتُقرأ رسائلها في البحث.",
            en: "Try another word, or open a conversation so its messages join the search."
        )

        // MARK: - Usage row (`usageTitle`, computed on the device)

        static let usageTitle = LText(ar: "استخدامك", en: "Your usage")
        static let usageWeek = LText(ar: "هذا الأسبوع", en: "This week")
        static let usageNote = LText(
            ar: "هذه الأرقام تُحسب على جهازك، ولا تُرسل إلى أي مكان.",
            en: "These numbers are worked out on your device. They are not sent anywhere."
        )
        /// `%@` = product name, `%@` = count.
        static let usageLine = LText(ar: "%@ · %@", en: "%@ · %@")

        // MARK: - Guest slot (`renderGuestUi`)

        static let guestLocalNote = LText(
            ar: "محادثاتك كضيف محفوظة على هذا الجهاز فقط.",
            en: "Guest chats are stored on this device only."
        )
        /// Both languages are always shown; the primary one follows the UI language.
        static let signUpNow = LText(ar: "سجّل الآن", en: "Sign up now")
        static let signUpNowAlt = LText(ar: "Sign up now", en: "سجّل الآن")
        static let guestExit = LText(ar: "الخروج من وضع الضيف", en: "Exit guest mode")
        static let guestExitConfirm = LText(
            ar: "سيتم مسح محادثات الضيف من هذا الجهاز. متابعة؟",
            en: "Guest chats on this device will be cleared. Continue?"
        )

        // MARK: - Account pill (`applyUserIdentity`)

        static let accountFallbackName = LText(ar: "Firas", en: "Firas")
        static let logout = LText(ar: "تسجيل الخروج", en: "Log out")
        static let accountPillHint = LText(ar: "حسابك", en: "Your account")

        // MARK: - Hardware keyboard (`design-brief.md §8`)

        static let kbNewChat = LText(ar: "محادثة جديدة", en: "New chat")
        static let kbSearch = LText(ar: "ابحث في المحادثات", en: "Search conversations")
        static let kbSettings = LText(ar: "الإعدادات", en: "Settings")
        static let kbToggleSidebar = LText(ar: "إظهار/إخفاء القائمة", en: "Show or hide the sidebar")
        static let kbCall = LText(ar: "ابدأ مكالمة", en: "Start a call")
        static let kbCopyAnswer = LText(ar: "انسخ آخر إجابة", en: "Copy the last answer")
        static let kbStop = LText(ar: "أوقف الردّ", en: "Stop the reply")
        /// `%@` = the product's own name.
        static let kbProduct = LText(ar: "افتح %@", en: "Open %@")
        static let copyNoAnswer = LText(
            ar: "لا توجد إجابة لنسخها بعد.",
            en: "There is no answer to copy yet."
        )

        // MARK: - Toast host

        static let toastDismiss = LText(ar: "أخفِ التنبيه", en: "Dismiss the notice")

        // MARK: - Boot and unreachable

        static let bootingLabel = LText(ar: "جارٍ التحضير…", en: "Getting ready…")
        static let cachedNotice = LText(
            ar: "تعذّر الوصول إلى الخادم — هذه نسخة محفوظة على جهازك.",
            en: "The server could not be reached — this is the copy saved on your device."
        )
        static let artifactUnavailable = LText(
            ar: "تعذّر فتح هذا الملف.",
            en: "This file could not be opened."
        )

        // MARK: - The all-chats page (`[new]`)
        //
        // The web has no all-chats page and no relative timestamps in its sidebar, so this copy is
        // native. It was written beside `SidebarHistoryList.Row` in round 3 and folded in here by
        // the round-3 integrator pass, so one namespace lives in one file.

        /// The all-chats page's filter menu (`All chats` / `Pinned`).
        static let filterMenu = LText(ar: "تصفية المحادثات", en: "Filter conversations")

        static let pinnedEmptyTitle = LText(ar: "لا توجد محادثات مثبّتة.", en: "No pinned conversations.")
        static let pinnedEmptySubtitle = LText(
            ar: "ثبّت محادثة من قائمتها وستظهر هنا.",
            en: "Pin a conversation from its menu and it will appear here."
        )

        // MARK: - Relative time (the card caption)

        static let justNow = LText(ar: "الآن", en: "Just now")
        static let relativeYesterday = LText(ar: "أمس", en: "Yesterday")

        static let minutesAgoZero = LText(ar: "قبل أقل من دقيقة", en: "Just now")
        static let minutesAgoOne = LText(ar: "قبل دقيقة", en: "%ld minute ago")
        static let minutesAgoTwo = LText(ar: "قبل دقيقتين", en: "%ld minutes ago")
        static let minutesAgoFew = LText(ar: "قبل %ld دقائق", en: "%ld minutes ago")
        static let minutesAgoMany = LText(ar: "قبل %ld دقيقة", en: "%ld minutes ago")
        static let minutesAgoOther = LText(ar: "قبل %ld دقيقة", en: "%ld minutes ago")

        static let hoursAgoZero = LText(ar: "قبل أقل من ساعة", en: "Less than an hour ago")
        static let hoursAgoOne = LText(ar: "قبل ساعة", en: "%ld hour ago")
        static let hoursAgoTwo = LText(ar: "قبل ساعتين", en: "%ld hours ago")
        static let hoursAgoFew = LText(ar: "قبل %ld ساعات", en: "%ld hours ago")
        static let hoursAgoMany = LText(ar: "قبل %ld ساعة", en: "%ld hours ago")
        static let hoursAgoOther = LText(ar: "قبل %ld ساعة", en: "%ld hours ago")

        static let daysAgoZero = LText(ar: "اليوم", en: "Today")
        static let daysAgoOne = LText(ar: "أمس", en: "Yesterday")
        static let daysAgoTwo = LText(ar: "قبل يومين", en: "%ld days ago")
        static let daysAgoFew = LText(ar: "قبل %ld أيام", en: "%ld days ago")
        static let daysAgoMany = LText(ar: "قبل %ld يومًا", en: "%ld days ago")
        static let daysAgoOther = LText(ar: "قبل %ld يوم", en: "%ld days ago")
    }
}
