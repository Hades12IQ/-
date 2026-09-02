import Foundation

/// Every user-visible string in the Settings tree, the memory viewer and the announcements feed.
///
/// Copy marked "verbatim" is the web client's, quoted through `web-auth-account-settings.md §6–§8`
/// and `web-chat-ux.md §14, §16`. The rest is new copy written in the same voice — mostly the
/// native-only rows (notifications, UI sounds, memory) that the web has no place for.
///
/// The nested namespaces are deliberately not called `Data`: an enum with that name would shadow
/// `Foundation.Data` for every expression written inside this scope.
extension Strings {
    enum Settings {

        // MARK: - Container

        /// `tx.title` / `tx.sub` — verbatim.
        static let title = LText(ar: "الإعدادات", en: "Settings")
        static let subtitle = LText(ar: "إدارة حسابك وأمانه", en: "Manage your account & security")

        /// The five tabs — verbatim.
        static let tabAccount = LText(ar: "الحساب", en: "Account")
        static let tabAppearance = LText(ar: "المظهر", en: "Appearance")
        static let tabChat = LText(ar: "المحادثة", en: "Chat")
        static let tabVoice = LText(ar: "الصوت", en: "Voice")
        static let tabData = LText(ar: "البيانات", en: "Data")

        /// Subtitles for the five rows of the container list. New copy.
        static let tabAccountSub = LText(ar: "هويتك وبريدك وكلمة مرورك", en: "Your identity, email and password")
        static let tabAppearanceSub = LText(ar: "الثيم وحجم النص واللغة", en: "Theme, text size and language")
        static let tabChatSub = LText(ar: "النموذج الافتراضي وسلوك الردّ", en: "Default model and reply behaviour")
        static let tabVoiceSub = LText(ar: "صوت المكالمة ولهجة الإملاء", en: "Call voice and dictation dialect")
        static let tabDataSub = LText(ar: "النسخ الاحتياطي والتنبيهات والذاكرة", en: "Backup, alerts and memory")

        /// `tx.working` — verbatim.
        static let working = LText(ar: "جارٍ…", en: "Working…")

        // MARK: - Account

        enum Account {
            /// Hero eyebrow — verbatim.
            static let eyebrow = LText(ar: "الحساب", en: "Account")
            /// `guestName` — verbatim.
            static let guestName = LText(ar: "ضيف", en: "Guest")

            /// Plan card — verbatim (`subCardHtml`).
            static let planHeader = LText(ar: "الاشتراك", en: "Plan")
            static let planChip = LText(ar: "✦ مجاني بالكامل", en: "✦ Free — everything included")
            static let planBody = LText(
                ar: "كل مزايا فِراس متاحة للجميع مجانًا. يحصل كل حساب على ٥٠٠ كريديت في Firas Agent تتجدد يوميًا.",
                en: "Every Firas feature is available free. Each account receives 500 Firas Agent credits refreshed daily."
            )
            /// New copy: the one line that replaces four "Unlimited" tiles.
            static let unmetered = LText(
                ar: "لا عدّادات على حسابك — كل المنتجات مفتوحة بلا حدّ يومي.",
                en: "No counters on your account — every product is open with no daily cap."
            )
            static let usageHeader = LText(ar: "استهلاك اليوم", en: "Today's usage")
            /// `%@` used, `%@` limit.
            static let usageLine = LText(ar: "%@ من %@", en: "%@ of %@")

            /// Change email — verbatim.
            static let changeEmailHeader = LText(ar: "تغيير البريد الإلكتروني", en: "Change email")
            static let newEmail = LText(ar: "البريد الجديد", en: "New email")
            static let currentPassword = LText(ar: "كلمة المرور الحالية", en: "Current password")
            static let saveEmail = LText(ar: "حفظ البريد", en: "Save email")
            static let emailRequired = LText(ar: "أدخل البريد الجديد", en: "Enter the new email")
            static let emailUpdated = LText(ar: "تم تحديث البريد ✓", en: "Email updated ✓")

            /// Change password — verbatim.
            static let changePasswordHeader = LText(ar: "تغيير كلمة المرور", en: "Change password")
            static let newPassword = LText(ar: "كلمة المرور الجديدة", en: "New password")
            static let passwordHint = LText(ar: "٨ أحرف على الأقل", en: "at least 8 characters")
            static let savePassword = LText(ar: "حفظ كلمة المرور", en: "Save password")
            static let passwordShort = LText(ar: "كلمة المرور 8 أحرف على الأقل", en: "Password must be 8+ characters")
            static let passwordChanged = LText(ar: "تم تغيير كلمة المرور ✓", en: "Password changed ✓")

            /// New copy for the §3.9 limitation: the account object never says which kind it is.
            static let googleHint = LText(
                ar: "الحسابات المسجّلة عبر Google بلا كلمة مرور — استخدم زر Google عند تسجيل الدخول.",
                en: "Accounts created with Google have no password — use the Google button when you sign in."
            )

            /// Danger zone — verbatim.
            static let dangerHeader = LText(ar: "منطقة الخطر", en: "Danger zone")
            static let dangerBody = LText(
                ar: "حذف الحساب يمسح جميع محادثاتك نهائياً ولا يمكن التراجع عنه.",
                en: "Deleting your account erases all your conversations permanently. This can't be undone."
            )
            static let deleteButton = LText(ar: "حذف حسابي", en: "Delete my account")
            static let deleteConfirmBody = LText(
                ar: "للتأكيد، أدخل كلمة مرورك ثم اضغط «حذف نهائي».",
                en: "To confirm, enter your password then tap “Delete permanently”."
            )
            static let deleteFinal = LText(ar: "حذف نهائي", en: "Delete permanently")
            static let deleted = LText(ar: "تم حذف حسابك", en: "Your account was deleted")

            /// Guest card — verbatim.
            static let guestHeader = LText(ar: "أنت تتصفّح كضيف", en: "You’re browsing as a guest")
            static let guestBody = LText(
                ar: "محادثاتك محفوظة على هذا الجهاز وحده، ولا يوجد حساب بعد — فلا بريد ولا كلمة مرور ولا حذف حساب هنا. أنشئ حسابًا مجانيًا وتنتقل محادثاتك إليه كما هي.",
                en: "Your conversations are saved on this device only, and there is no account yet — so there is no email, no password and no account to delete here. Create a free account and these chats move into it exactly as they are."
            )
            static let guestCTA = LText(ar: "أنشئ حسابًا مجانيًا", en: "Create a free account")

            /// `logout` — verbatim.
            static let signOut = LText(ar: "تسجيل الخروج", en: "Log out")
            static let signOutConfirm = LText(
                ar: "تسجيل الخروج من هذا الجهاز؟",
                en: "Log out of this device?"
            )

            /// Redeem codes: admin-only, legacy (`§10`).
            static let redeemHeader = LText(ar: "أكواد التفعيل", en: "Redeem codes")
            static let redeemNote = LText(
                ar: "الموقع مجاني بالكامل — الأكواد باقية للإدارة فقط.",
                en: "The site is completely free — codes remain for administration only."
            )
            static let redeemField = LText(ar: "الكود", en: "Code")
            static let redeemButton = LText(ar: "تفعيل", en: "Redeem")
            static let redeemDone = LText(ar: "تم تفعيل الكود ✓", en: "Code redeemed ✓")

            static let signedOutTitle = LText(ar: "لا يوجد حساب مفتوح", en: "No account open")
            static let signedOutBody = LText(
                ar: "سجّل الدخول لتظهر تفاصيل حسابك هنا.",
                en: "Sign in and your account details appear here."
            )
            static let signIn = LText(ar: "تسجيل الدخول", en: "Sign in")
        }

        // MARK: - Appearance

        enum Appearance {
            /// `themeH` / `themeSub` — verbatim.
            static let themeHeader = LText(ar: "الثيم", en: "Theme")
            static let themeSub = LText(ar: "ستة أمزجة", en: "six moods")

            /// `readingH` and the three sizes — verbatim.
            static let textSizeHeader = LText(ar: "حجم النص", en: "Text size")
            static let textSizeSmall = LText(ar: "صغير", en: "Small")
            static let textSizeMedium = LText(ar: "متوسط", en: "Medium")
            static let textSizeLarge = LText(ar: "كبير", en: "Large")

            /// `widthH` — verbatim.
            static let widthHeader = LText(ar: "عرض القراءة", en: "Reading width")
            static let widthNormal = LText(ar: "عادي", en: "Normal")
            static let widthWide = LText(ar: "واسع", en: "Wide")

            /// `motionH` — verbatim.
            static let motionHeader = LText(ar: "الحركة", en: "Motion")
            static let motionFull = LText(ar: "كاملة", en: "Full")
            static let motionReduced = LText(ar: "مخفّفة", en: "Reduced")
            static let motionSystemNote = LText(
                ar: "«تقليل الحركة» في إعدادات النظام يغلبها دائمًا.",
                en: "Reduce Motion in the system settings always wins."
            )

            /// `langH` — verbatim.
            static let languageHeader = LText(ar: "لغة الواجهة", en: "Interface language")
            static let languageArabic = LText(ar: "العربية", en: "العربية")
            static let languageEnglish = LText(ar: "English", en: "English")
            static let languageChanged = LText(ar: "تم تغيير لغة الواجهة ✓", en: "Interface language changed ✓")

            static func textSize(_ scale: FontScale) -> LText {
                switch scale {
                case .small: return textSizeSmall
                case .medium: return textSizeMedium
                case .large: return textSizeLarge
                }
            }

            static func width(_ width: ContentWidth) -> LText {
                width == .wide ? widthWide : widthNormal
            }

            static func motion(_ preference: MotionPreference) -> LText {
                preference == .full ? motionFull : motionReduced
            }

            static func language(_ language: AppLanguage) -> LText {
                language == .arabic ? languageArabic : languageEnglish
            }
        }

        // MARK: - Chat

        enum Chat {
            /// `modelH` / `modelSub` / `modelSet` — verbatim.
            static let modelHeader = LText(ar: "النموذج الافتراضي", en: "Default model")
            static let modelSub = LText(ar: "للمحادثات الجديدة", en: "for new conversations")
            static let modelSet = LText(ar: "تم تعيين النموذج الافتراضي ✓", en: "Default model set ✓")

            /// `MODES` — verbatim (`web-chat-ux.md §6`).
            static let styleHeader = LText(ar: "أسلوب الردّ", en: "Reply style")
            static let styleAuto = LText(ar: "تلقائي", en: "Auto")
            static let styleAutoHint = LText(ar: "ذكي ومباشر — يجيب فورًا.", en: "Smart & direct — answers right away.")
            static let stylePlan = LText(ar: "تخطيط", en: "Plan")
            static let stylePlanHint = LText(
                ar: "يسأل ويضع خطة، ثم ينفّذ بعد موافقتك.",
                en: "Asks & plans first, then executes once you approve."
            )

            /// `behaveH` and its switches — verbatim.
            static let behaviourHeader = LText(ar: "سلوك الردّ", en: "Reply behaviour")
            static let think = LText(ar: "التفكير العميق", en: "Deep thinking")
            static let thinkHint = LText(
                ar: "أبطأ وأدقّ في المسائل الصعبة",
                en: "slower, more careful on hard questions"
            )
            /// New copy: Mini has no thinking pass, so the row explains itself instead of vanishing.
            static let thinkUnavailable = LText(
                ar: "غير متاح مع ميني — اختر برو أو أعلى.",
                en: "Not available on Mini — pick Pro or higher."
            )
            static let webSearch = LText(ar: "البحث في الويب", en: "Web search")
            static let webSearchHint = LText(ar: "يبحث قبل كلّ ردّ", en: "searches before every reply")
            static let enterSend = LText(ar: "الإرسال بمفتاح Enter", en: "Send with Enter")
            /// The web says `Shift+Enter`; on a hardware keyboard the native glyphs are clearer.
            static let enterSendHint = LText(ar: "و ⇧↩ لسطر جديد", en: "⇧↩ for a new line")
            static let enterSendNote = LText(
                ar: "يخصّ لوحة المفاتيح الخارجية فقط.",
                en: "Applies to a hardware keyboard only."
            )

            /// `imgH` / `srLbl` / `srHint` — verbatim.
            static let imagesHeader = LText(ar: "الصور", en: "Images")
            static let sharpen = LText(ar: "شحذ الصور تلقائيًّا", en: "Sharpen pictures automatically")
            static let sharpenHint = LText(
                ar: "شبكة تعمل على جهازك — ثانية أو اثنتان، وبلا أي كلفة",
                en: "a network on your own device — a second or two, and free"
            )
        }

        // MARK: - Voice

        enum Voice {
            /// `voiceH` / `voiceSub` / `voiceNote` — verbatim.
            static let callVoiceHeader = LText(ar: "صوت المكالمة", en: "Call voice")
            static let callVoiceSub = LText(ar: "يُطبَّق على مكالمتك القادمة", en: "applies to your next call")
            static let callVoiceNote = LText(
                ar: "أصوات المكالمة المباشرة. جرّب حتى تجد الأقرب إلى أذنك.",
                en: "Live-call voices. Try a few until one sounds right."
            )
            /// `firasSetCallVoice` toast — verbatim; `%@` is the voice name.
            static let callVoiceSet = LText(
                ar: "صوت المكالمة: %@ — يُطبَّق على المكالمة القادمة",
                en: "Call voice: %@ — applies to the next call"
            )

            /// New copy: barge-in has no web equivalent.
            static let duringCallHeader = LText(ar: "أثناء المكالمة", en: "During a call")
            static let bargeIn = LText(ar: "المقاطعة أثناء الكلام", en: "Interrupt while it speaks")
            static let bargeInHint = LText(
                ar: "يتوقّف فِراس فور ما تبدأ الكلام. أطفئها إن قاطعك صدى السمّاعة.",
                en: "Firas stops the moment you start talking. Turn it off if speaker echo cuts him short."
            )

            /// `dictH` / `dictSub` — verbatim.
            static let dialectHeader = LText(ar: "لهجة الإملاء", en: "Dictation dialect")
            static let dialectSub = LText(ar: "حين تُملي كلامك نصّاً", en: "when you speak instead of type")

            /// New copy: the app has interface sounds, the web has none.
            static let soundsHeader = LText(ar: "أصوات الواجهة", en: "Interface sounds")
            static let sounds = LText(ar: "نغمة الإرسال والاكتمال", en: "Send and completion tones")
            static let soundsHint = LText(
                ar: "نغمة قصيرة جدًا، وتصمت أثناء المكالمة.",
                en: "A very short tone, silent during a call."
            )
        }

        // MARK: - Data

        enum Storage {
            /// `convH` / `convSub` / `exportBtn` / `importBtn` — verbatim.
            static let conversationsHeader = LText(ar: "المحادثات", en: "Conversations")
            static let conversationsNote = LText(
                ar: "احفظ محادثاتك في ملف احتياطي، أو استعدها لاحقاً.",
                en: "Save your chats to a backup file, or restore them later."
            )
            static let exportButton = LText(ar: "تصدير نسخة", en: "Export backup")
            static let importButton = LText(ar: "استيراد من ملف", en: "Import file")
            static let exporting = LText(ar: "جارٍ التصدير…", en: "Exporting…")
            static let importing = LText(ar: "جارٍ الاستيراد…", en: "Importing…")
            static let exported = LText(ar: "تم تصدير محادثاتك ✓", en: "Chats exported ✓")
            static let nothingToExport = LText(ar: "لا توجد محادثات لتصديرها", en: "No conversations to export")
            static let invalidBackup = LText(ar: "ملف النسخة غير صالح", en: "Invalid backup file")
            static let backupTooLarge = LText(ar: "ملف النسخة كبير جدًا", en: "That backup file is too large")
            static let importConfirm = LText(
                ar: "استيراد المحادثات من هذا الملف؟ ستُضاف إلى قائمتك.",
                en: "Import conversations from this file? They'll be added to your list."
            )
            static let imported = LText(ar: "تم استيراد المحادثات ✓", en: "Chats imported ✓")
            /// Partial import (`audit F21`): `%@` landed, `%@` in the file.
            static let importedPartial = LText(
                ar: "استُوردت %@ محادثة من أصل %@.",
                en: "Imported %@ of %@ conversations."
            )
            static let importFailed = LText(ar: "تعذّر الاستيراد. حاول مرة أخرى.", en: "Import failed. Try again.")

            /// `storageH` / `storageSub` / `guestStorageSub` / `clearBtn` / `clearConfirm` — verbatim.
            static let storageHeader = LText(ar: "التخزين", en: "Storage")
            static let storageNote = LText(
                ar: "يمسح تفضيلات هذا الجهاز فقط — محادثاتك محفوظة في حسابك.",
                en: "Clears this device's preferences only — your chats live safely in your account."
            )
            static let storageNoteGuest = LText(
                ar: "يمسح تفضيلات هذا الجهاز فقط — محادثاتك كضيف محفوظة على هذا الجهاز ولن تُمسح.",
                en: "Clears this device’s preferences only — your guest chats live on this device and are kept."
            )
            static let clearButton = LText(ar: "مسح بيانات الجهاز", en: "Clear device data")
            static let clearConfirm = LText(
                ar: "مسح تفضيلات هذا الجهاز؟ محادثاتك لن تُحذف.",
                en: "Clear this device's preferences? Your chats won't be deleted."
            )
            static let cleared = LText(ar: "تمت إعادة التفضيلات ✓", en: "Preferences reset ✓")

            /// `aboutH` / `versionLbl` / `updatesLink` — verbatim.
            static let aboutHeader = LText(ar: "عن التطبيق", en: "About")
            static let versionLabel = LText(ar: "الإصدار", en: "Version")
            static let serverLabel = LText(ar: "إصدار الخادم", en: "Server build")
            static let updatesLink = LText(ar: "عرض آخر التحديثات", en: "See what's new")
            static let company = LText(ar: "من شركة مِنترونكس", en: "By MentronX")
        }

        // MARK: - Notifications

        enum Notifications {
            static let header = LText(ar: "التنبيهات", en: "Notifications")
            /// The honest promise (`audit F2/F22`): never "instantly".
            static let explainer = LText(
                ar: "المهام الطويلة تكمل على الخادم حتى لو أغلقت التطبيق. حين تجهز النتيجة يصلك تنبيه على هذا الجهاز — عادةً خلال دقائق.",
                en: "Long tasks keep running on the server even after you close the app. When a result is ready this device shows a notification — usually within minutes."
            )
            static let statusLabel = LText(ar: "الحالة", en: "Status")
            static let statusOn = LText(ar: "مُفعّلة", en: "On")
            static let statusOff = LText(ar: "مرفوضة", en: "Off")
            static let statusUnknown = LText(ar: "لم تُطلب بعد", en: "Not asked yet")
            static let enableButton = LText(ar: "تفعيل التنبيهات", en: "Turn on notifications")
            static let openSystemSettings = LText(ar: "فتح إعدادات النظام", en: "Open system settings")
            static let deniedNote = LText(
                ar: "التنبيهات مرفوضة من إعدادات النظام. افتحها وفعّلها لفِراس.",
                en: "Notifications are off in the system settings. Open them and allow Firas."
            )
            static let onNote = LText(
                ar: "ستصلك رسالة واحدة لكل مهمة تنتهي وأنت خارج التطبيق.",
                en: "You get one message per task that finishes while you are away."
            )
            static let notNow = LText(ar: "ليس الآن", en: "Not now")
        }

        // MARK: - Memory

        enum Memory {
            /// Verbatim (`web-auth-account-settings.md §7`).
            static let title = LText(ar: "ما يتذكّره فراس عنك", en: "What Firas remembers about you")
            static let subtitle = LText(
                ar: "أستخدمها لتخصيص ردودي. خاصة بك وحدك.",
                en: "Used to personalize my replies. Private to you."
            )
            static let empty = LText(
                ar: "ما حفظت معلومات عنك بعد — كل ما نتحدّث، أتعلّم وأتذكّر أكثر.",
                en: "Nothing saved about you yet — I learn and remember more as we chat."
            )
            static let clearAll = LText(ar: "مسح الكل", en: "Clear all")
            static let clearAllConfirm = LText(
                ar: "مسح كل ما يتذكّره فِراس عنك؟",
                en: "Erase everything Firas remembers about you?"
            )
            static let deleteOne = LText(ar: "حذف", en: "Delete")
            static let open = LText(ar: "ما يتذكّره فِراس", en: "What Firas remembers")
            static let guestTitle = LText(ar: "الذاكرة للأعضاء", en: "Memory is for members")
            static let guestBody = LText(
                ar: "الذاكرة محفوظة في حسابك، لا على هذا الجهاز. أنشئ حسابًا مجانيًا لتفعيلها.",
                en: "Memory lives in your account, not on this device. Create a free account to switch it on."
            )
            /// Footer count — the six Arabic forms of `معلومة`.
            static let countZero = LText(ar: "لا معلومات", en: "No items")
            static let countOne = LText(ar: "معلومة واحدة", en: "%ld item")
            static let countTwo = LText(ar: "معلومتان", en: "%ld items")
            static let countFew = LText(ar: "%ld معلومات", en: "%ld items")
            static let countMany = LText(ar: "%ld معلومة", en: "%ld items")
            static let countOther = LText(ar: "%ld معلومة", en: "%ld items")

            static func count(_ n: Int, _ lang: AppLanguage) -> String {
                ArabicPlurals.count(
                    n,
                    lang,
                    zero: countZero,
                    one: countOne,
                    two: countTwo,
                    few: countFew,
                    many: countMany,
                    other: countOther
                )
            }
        }

        // MARK: - Announcements

        enum Announcements {
            /// Verbatim (`§8.3`).
            static let title = LText(ar: "تحديثات Firas AI", en: "Firas AI updates")
            static let subtitle = LText(ar: "آخر أخبار وتحديثات المنصّة.", en: "Latest platform news & updates.")
            static let empty = LText(ar: "لا توجد تحديثات بعد.", en: "No updates yet.")
            static let untitled = LText(ar: "تحديث", en: "Update")
            static let pinned = LText(ar: "مثبّت", en: "Pinned")
            static let video = LText(ar: "فيديو", en: "Video")
            static let edited = LText(ar: "مُعدّل", en: "edited")

            /// Reader language toggle — verbatim.
            static let original = LText(ar: "الأصل", en: "Original")
            static let arabic = LText(ar: "عربي", en: "عربي")
            static let english = LText(ar: "EN", en: "EN")
            static let translating = LText(ar: "جارٍ الترجمة…", en: "Translating…")
            static let translateFailed = LText(
                ar: "تعذّرت الترجمة، حاول مجدداً",
                en: "Translation failed, please try again"
            )
            static let translateMembersOnly = LText(
                ar: "الترجمة للأعضاء — أنشئ حسابًا مجانيًا.",
                en: "Translation is for members — create a free account."
            )
            static let loadFailed = LText(
                ar: "تعذّر تحميل التحديثات.",
                en: "Couldn't load the updates."
            )
        }
    }
}
