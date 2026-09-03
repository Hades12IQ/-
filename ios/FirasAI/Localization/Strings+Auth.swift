import Foundation

/// Every string the consent door, the landing hero, the auth card, the verification card, the
/// password-recovery sheet and the guest upsell can show.
///
/// Arabic is copied verbatim from the web tables cited in `ios/Docs/web-auth-account-settings.md`
/// (§2, §3.1, §5.4) and `ios/Docs/web-chat-ux.md` (§1.1, §1.3). Where the web ships Arabic only —
/// the whole first-run consent screen — the English twin is new copy written in the same voice,
/// because an English device must not be shown an Arabic-only door.
extension Strings {
    enum Auth {

        // MARK: - Nested value types (namespaced, never global)

        /// One of the four marks under the landing CTA: a product name and what it does.
        struct LandingMark: Identifiable, Sendable {
            let id: String
            /// The product name, always Latin (`AI`, `Agent`, `Code`, `Brain`).
            let name: String
            let label: LText
        }

        /// One of the seven landing cards.
        struct LandingFeature: Identifiable, Sendable {
            let id: String
            /// SF Symbol standing in for the web's icon key.
            let symbol: String
            let title: LText
            let body: LText
        }

        /// One line of the consent screen: a lead-in and the sentence itself.
        struct ConsentLine: Identifiable, Sendable {
            let id: String
            let text: LText
        }

        // MARK: - First-run consent (web-chat-ux.md §1.1 — Arabic verbatim, English new)

        static let consentTitle = LText(
            ar: "أهلًا بك في فِراس AI",
            en: "Welcome to Firas AI"
        )

        static let consentLede = LText(
            ar: "منصّة ذكاء اصطناعي عربية أولًا من شركة مِنترونكس العراقية — مبنية للطلبة في العراق والعالم العربي.",
            en: "An Arabic-first AI platform from MentronX in Iraq — built for students in Iraq and across the Arab world."
        )

        static let consentProductsTitle = LText(
            ar: "أربعة منتجات بحساب واحد",
            en: "Four products, one account"
        )

        static let consentProducts: [ConsentLine] = [
            ConsentLine(
                id: "chat",
                text: LText(
                    ar: "محادثة فِراس — تفهم الفصحى واللهجات، مع بحث في الويب، ومكالمة صوتية، وتوليد الصور والفيديو والأغاني.",
                    en: "Firas chat — understands Modern Standard Arabic and dialects, with web search, a voice call, and image, video and song generation."
                )
            ),
            ConsentLine(
                id: "agent",
                text: LText(
                    ar: "فِراس ايجنت — ينفّذ المهام الطويلة خطوة بخطوة، ويكمل شغله على الخادم حتى لو أغلقت الموقع.",
                    en: "Firas Agent — works through long tasks step by step and keeps going on the server even after you close the app."
                )
            ),
            ConsentLine(
                id: "code",
                text: LText(
                    ar: "فِراس كود — بيئة برمجة كاملة في المتصفح: تكتب وتشغّل وتنشر بلا تنصيب.",
                    en: "Firas Code — a complete development environment: write, run and publish with nothing to install."
                )
            ),
            ConsentLine(
                id: "brain",
                text: LText(
                    ar: "فِراس برين — ترفع كتبك وتسأل عنها، فيجاوبك من محتواها مع رقم الصفحة، ويقرأ الكتب المصوّرة بالرؤية.",
                    en: "Firas Brain — upload your books and ask about them; the answer comes from their content with the page number, and scanned books are read with vision."
                )
            )
        ]

        static let consentWhyTitle = LText(
            ar: "ليش فِراس مختلف",
            en: "Why Firas is different"
        )

        static let consentWhy: [ConsentLine] = [
            ConsentLine(
                id: "arabic",
                text: LText(
                    ar: "العربية ليست ترجمة — التشكيل واللهجات والإعراب والمناهج، من الأساس.",
                    en: "Arabic is not a translation layer — diacritics, dialects, grammar and school curricula, from the ground up."
                )
            ),
            ConsentLine(
                id: "cited",
                text: LText(
                    ar: "كل معلومة موثّقة — الجواب يذكر صفحته لتتحقّق بنفسك.",
                    en: "Every fact is cited — the answer names its page so you can check it yourself."
                )
            ),
            ConsentLine(
                id: "modest",
                text: LText(
                    ar: "يشتغل على هاتف بسيط — مصمّم لاتصال ضعيف وأجهزة متوسطة.",
                    en: "It runs on a modest phone — designed for weak connections and mid-range devices."
                )
            )
        ]

        static let consentFaqTitle = LText(
            ar: "أسئلة سريعة",
            en: "Quick questions"
        )

        static let consentFaq: [ConsentLine] = [
            ConsentLine(
                id: "free",
                text: LText(
                    ar: "هل هو مجاني؟ نعم، تقدر تجرّبه وتنشئ حسابًا مجانًا مع حصّة يومية لكل منتج.",
                    en: "Is it free? Yes — try it and create a free account, with a daily allowance for every product."
                )
            ),
            ConsentLine(
                id: "dialects",
                text: LText(
                    ar: "هل يفهم اللهجة العراقية؟ نعم — والخليجية والمصرية والشامية والمغربية، ويجاوب بها.",
                    en: "Does it understand Iraqi Arabic? Yes — along with Gulf, Egyptian, Levantine and Maghrebi, and it answers in them."
                )
            ),
            ConsentLine(
                id: "scans",
                text: LText(
                    ar: "هل يقرأ كتابًا مدرسيًا مصوّرًا؟ نعم، يقرأ صفحات PDF المصوّرة ويجاوب من محتواها.",
                    en: "Can it read a scanned textbook? Yes — it reads scanned PDF pages and answers from their content."
                )
            ),
            ConsentLine(
                id: "who",
                text: LText(
                    ar: "منو طوّره؟ شركة مِنترونكس العراقية، ومؤسّسها فِراس.",
                    en: "Who built it? MentronX of Iraq, founded by Firas."
                )
            )
        ]

        static let consentAgree = LText(
            ar: "أوافق على شروط الاستخدام وسياسة الخصوصية.",
            en: "I agree to the Terms of Use and the Privacy Policy."
        )

        static let consentContinue = LText(ar: "متابعة", en: "Continue")

        static let consentNote = LText(
            ar: "قد يخطئ فِراس. تحقّق من المعلومات المهمة.",
            en: "Firas can make mistakes. Check important information."
        )

        /// Spoken hint for the consent checkbox, so VoiceOver says why Continue is disabled.
        static let consentAgreeHint = LText(
            ar: "فعّل الموافقة لتفعيل زر المتابعة.",
            en: "Turn the agreement on to enable the Continue button."
        )

        static let termsTitle = LText(ar: "شروط الاستخدام", en: "Terms of Use")
        static let privacyTitle = LText(ar: "سياسة الخصوصية", en: "Privacy Policy")

        static let termsURL = "https://firasai.org/terms"
        static let privacyURL = "https://firasai.org/privacy"

        // MARK: - Landing (web-auth-account-settings.md §2, verbatim)

        static let landingAbout = LText(
            ar: "أربعة منتجات بحساب واحد: محادثة، ووكيل ينفّذ المهام الطويلة خطوة بخطوة، وبيئة برمجة كاملة داخل المتصفح، ومكتبة تقرأ ملفاتك وتجيب منها — مع رقم الصفحة، حتى تتحقّق بنفسك.",
            en: "Four products, one account: chat, an agent that works through long tasks step by step, a full development environment in the browser, and a library that reads your own files and answers from them — with the page number, so you can check it yourself."
        )

        static let landingStart = LText(
            ar: "ابدأ الآن — بدون حساب",
            en: "Get Started — no account"
        )

        static let landingSignIn = LText(
            ar: "لديك حساب؟ تسجيل الدخول",
            en: "Already have an account? Sign in"
        )

        static let landingGuestHint = LText(
            ar: "ادخل فورًا وجرّب فِراس. سجّل لاحقًا لحفظ محادثاتك.",
            en: "Jump straight in and try Firas. Sign up later to save your chats."
        )

        static let landingScale: [LandingMark] = [
            LandingMark(id: "ai", name: "AI", label: LText(ar: "محادثة", en: "Chat")),
            LandingMark(id: "agent", name: "Agent", label: LText(ar: "مهام كبيرة", en: "Big tasks")),
            LandingMark(id: "code", name: "Code", label: LText(ar: "برمجة", en: "Building")),
            LandingMark(id: "brain", name: "Brain", label: LText(ar: "وثائقك", en: "Your documents"))
        ]

        static let landingFeaturesTitle = LText(ar: "لماذا فِراس AI؟", en: "Why Firas AI?")

        static let landingFeaturesSub = LText(
            ar: "منصّة ذكاء اصطناعي متكاملة، تتحدّث العربية والإنجليزية بطلاقة — كل ما تحتاجه في مكان واحد.",
            en: "A complete AI platform — fluent in Arabic and English, with everything you need in one place."
        )

        static let landingFeatures: [LandingFeature] = [
            LandingFeature(
                id: "spark",
                symbol: "sparkles",
                title: LText(ar: "أربعة نماذج ذكية", en: "Four smart models"),
                body: LText(
                    ar: "«ميني» للسرعة، و«برو» للمهام اليومية، و«أولترا» للأسئلة الصعبة والبرمجة، و«ماكس» الأقوى للأسئلة الصعبة والتحليل العميق في كل المجالات.",
                    en: "“Mini” for speed, “Pro” for everyday tasks, “Ultra” for hard questions & coding, and “Max” — the strongest for hard questions & deep analysis across every field."
                )
            ),
            LandingFeature(
                id: "code",
                symbol: "chevron.left.forwardslash.chevron.right",
                title: LText(ar: "فِراس Code — برمجة كاملة بالمتصفح", en: "Firas Code — a full in-browser IDE"),
                body: LText(
                    ar: "بيئة تطوير حقيقية داخل التطبيق: مشاريع متعددة الملفات، ومعاينة حيّة — صِف فكرتك ويبنيها فِراس.",
                    en: "A real dev environment inside the app: multi-file projects and live preview — describe your idea and Firas builds it."
                )
            ),
            LandingFeature(
                id: "devices",
                symbol: "square.stack.3d.up",
                title: LText(ar: "فِراس Agent — وكيل المهام الكبيرة", en: "Firas Agent — for big tasks"),
                body: LText(
                    ar: "يخطّط وينفّذ خطوة بخطوة ويراجع عمله بنفسه، ثم يسلّمك ملفات ومشاريع كاملة جاهزة للتسليم.",
                    en: "Plans, executes step by step, reviews its own work, then hands you complete, ready-to-submit files and projects."
                )
            ),
            LandingFeature(
                id: "brain",
                symbol: "brain.head.profile",
                title: LText(ar: "فِراس Brain — يجيب من ملفاتك أنت", en: "Firas Brain — answers from your own files"),
                body: LText(
                    ar: "ارفع كتبك ومحاضراتك وامتحاناتك — بصيغها المختلفة، حتى المصوّرة — واسأل. الجواب يأتي من داخل ملفك مع اسم الملف ورقم الصفحة، تضغط عليه فيفتح لك النص نفسه.",
                    en: "Upload your books, lectures and past papers — any format, including scans — and ask. The answer comes from inside your file, with the filename and page number; click it and the passage itself opens."
                )
            ),
            LandingFeature(
                id: "file",
                symbol: "doc.text",
                title: LText(ar: "ملفات وامتحانات جاهزة", en: "Ready files & exam papers"),
                body: LText(
                    ar: "يولّد PDF وWord وExcel وPowerPoint بخطوط عربية أنيقة — وأسئلة مع حلولها بتنسيق ورقة امتحان حقيقية.",
                    en: "Generates PDF, Word, Excel and PowerPoint with elegant Arabic fonts — plus questions with solutions in a real exam-paper layout."
                )
            ),
            LandingFeature(
                id: "search",
                symbol: "magnifyingglass",
                title: LText(ar: "بحث الويب المباشر", en: "Live web search"),
                body: LText(
                    ar: "يجلب معلومات حديثة من الإنترنت ويجيبك مع ذكر المصادر القابلة للنقر.",
                    en: "Pulls fresh information from the internet and answers with clickable sources."
                )
            ),
            LandingFeature(
                id: "bulb",
                symbol: "lightbulb",
                title: LText(ar: "وضع التفكير", en: "Thinking mode"),
                body: LText(
                    ar: "تحليل أعمق ودقّة أعلى عند تفعيله — مثالي للأسئلة المعقّدة والمسائل المنطقية.",
                    en: "Deeper analysis and higher accuracy when enabled — ideal for complex, logical problems."
                )
            )
        ]

        static let landingImageBadge = LText(ar: "تجريبي", en: "Beta")

        static let landingImageTitle = LText(ar: "ميزة توليد الصور", en: "Image generation")

        static let landingImageBody = LText(
            ar: "أُطلقت حديثًا وما زالت قيد التطوير، لذا قد تتحسّن النتائج تدريجيًا. الحدّ الحالي: ٥ صور في اليوم لكل مستخدم. جرّبها بكتابة «اصنع لي صورة…» داخل المحادثة.",
            en: "Recently launched and still under active development, so results will keep improving. Current limit: 5 images per day per user. Try it by typing “create an image of…” in the chat."
        )

        // MARK: - Auth card (web-auth-account-settings.md §3.1, verbatim)

        static let signupTitle = LText(ar: "أنشئ حسابك", en: "Create your account")
        static let loginTitle = LText(ar: "مرحبًا بعودتك", en: "Welcome back")
        static let signupSubtitle = LText(ar: "ابدأ المحادثة مع فِراس.", en: "Start your conversation with Firas.")
        static let loginSubtitle = LText(ar: "سجّل الدخول لمتابعة محادثاتك.", en: "Log in to continue your conversations.")

        static let name = LText(ar: "الاسم", en: "Name")
        static let email = LText(ar: "البريد الإلكتروني", en: "Email")
        static let password = LText(ar: "كلمة المرور", en: "Password")

        static let signupButton = LText(ar: "إنشاء حساب", en: "Create account")
        static let loginButton = LText(ar: "تسجيل الدخول", en: "Log in")

        static let toLogin = LText(ar: "لديك حساب بالفعل؟", en: "Already have an account?")
        static let toSignup = LText(ar: "ليس لديك حساب؟", en: "Don't have an account?")
        static let toLoginButton = LText(ar: "تسجيل الدخول", en: "Log in")
        static let toSignupButton = LText(ar: "إنشاء حساب", en: "Sign up")

        static let google = LText(ar: "المتابعة عبر Google", en: "Continue with Google")
        static let or = LText(ar: "أو", en: "or")

        static let googleError = LText(
            ar: "تعذّر تسجيل الدخول عبر Google. حاول مرة أخرى.",
            en: "Couldn't sign in with Google. Please try again."
        )

        static let googleUnavailable = LText(
            ar: "تسجيل الدخول عبر Google غير متاح حاليًا.",
            en: "Google sign-in is unavailable right now."
        )

        /// The signup success toast; `%@` is the address the link was sent to.
        static let signupSent = LText(
            ar: "📧 أرسلنا إيميل التأكيد إلى %@",
            en: "📧 Verification email sent to %@"
        )

        /// Client-side guard before either password request leaves the device.
        static let passwordShort = LText(
            ar: "كلمة المرور يجب أن تكون ٨ أحرف على الأقل.",
            en: "Password must be at least 8 characters."
        )

        /// Empty required fields — the web falls back to `authGenericError` here.
        static let incomplete = LText(
            ar: "تعذّر إتمام العملية. حاول مرة أخرى.",
            en: "Something went wrong. Please try again."
        )

        /// Legal line under the sign-up button.
        static let termsNote = LText(
            ar: "بإنشاء حساب فأنت توافق على شروط الاستخدام وسياسة الخصوصية.",
            en: "By creating an account you agree to the Terms of Use and the Privacy Policy."
        )

        // MARK: - Forgot / reset (§3.1, §3.6, §3.7)

        static let forgot = LText(ar: "نسيت كلمة المرور؟", en: "Forgot password?")

        static let forgotTitle = LText(ar: "استعادة كلمة المرور", en: "Recover your password")

        static let forgotSubtitle = LText(
            ar: "أدخل بريدك المسجّل وسنرسل لك رابط إعادة التعيين.",
            en: "Enter your registered email and we'll send you a reset link."
        )

        static let forgotNeedEmail = LText(
            ar: "اكتب بريدك الإلكتروني أولاً.",
            en: "Enter your email first."
        )

        static let forgotSend = LText(ar: "إرسال رابط الاستعادة", en: "Send the reset link")

        static let forgotSent = LText(
            ar: "إذا كان البريد مسجّلاً، أرسلنا له رابط إعادة التعيين. تحقّق من بريدك (وصندوق الـ Spam).",
            en: "If that email is registered, we sent a reset link. Check your inbox (and Spam)."
        )

        static let resetTitle = LText(ar: "تعيين كلمة مرور جديدة", en: "Set a new password")

        static let resetSubtitle = LText(
            ar: "اختر كلمة مرور جديدة لحسابك.",
            en: "Choose a new password for your account."
        )

        static let resetButton = LText(ar: "تعيين كلمة المرور", en: "Set password")

        static let newPassword = LText(ar: "كلمة المرور الجديدة", en: "New password")

        static let resetDone = LText(
            ar: "تم تغيير كلمة المرور — سجّل الدخول الآن.",
            en: "Password changed — sign in now."
        )

        static let resetInvalid = LText(
            ar: "الرابط غير صالح أو منتهي. اطلب رابطاً جديداً.",
            en: "The link is invalid or expired. Request a new one."
        )

        /// Reset revokes every other session, so the app says so before the sheet closes.
        static let resetSignedOutOthers = LText(
            ar: "سُجّل خروج بقية الأجهزة من الحساب.",
            en: "Every other device was signed out of this account."
        )

        // MARK: - Verification (§3.1, §3.5)

        static let verifyTitle = LText(ar: "📧 تفقّد بريدك الإلكتروني", en: "📧 Check your email")

        static let verifySubtitle = LText(
            ar: "أرسلنا رابط التأكيد إلى",
            en: "We sent a verification link to"
        )

        static let verifyWaiting = LText(
            ar: "افتح الرابط من بريدك واضغط الزر — وسيكتمل الدخول هنا تلقائياً (حتى لو فتحته من جهاز آخر). تحقّق من صندوق الوارد والـ Spam.",
            en: "Open the link from your email and tap the button — this device will finish automatically (even if you open it on another device). Check your inbox and Spam."
        )

        static let verifyBad = LText(
            ar: "رابط التأكيد غير صالح أو منتهي. أعد التسجيل من جديد.",
            en: "The verification link is invalid or expired. Please sign up again."
        )

        static let verifyAlreadyActive = LText(
            ar: "حسابك مُفعّل بالفعل — سجّل الدخول.",
            en: "Your account is already active — please sign in."
        )

        static let resend = LText(ar: "إعادة إرسال الرابط", en: "Resend link")

        /// `%@` is the remaining seconds, in Arabic-Indic digits for the Arabic UI.
        static let resendCountdown = LText(ar: "إعادة إرسال الرابط (%@)", en: "Resend link (%@)")

        static let resendOk = LText(
            ar: "📧 أرسلنا رابطاً جديداً إلى بريدك",
            en: "📧 We sent a new link to your email"
        )

        static let resendWait = LText(
            ar: "انتظر قليلاً قبل إعادة الإرسال",
            en: "Please wait before resending"
        )

        static let codeResent = LText(
            ar: "أرسلنا رابطاً جديداً إلى بريدك.",
            en: "We sent a new link to your email."
        )

        static let backToLogin = LText(ar: "‹ الرجوع لتسجيل الدخول", en: "‹ Back to sign in")

        /// The card's own "still waiting" line, so the poll never looks frozen.
        static let verifyWatching = LText(
            ar: "نتحقّق تلقائيًا كل بضع ثوانٍ…",
            en: "Checking automatically every few seconds…"
        )

        static let verifyPaused = LText(
            ar: "التحقّق متوقّف مؤقتًا — أعد فتح التطبيق لمتابعته.",
            en: "Checking is paused — reopen the app to continue."
        )

        // MARK: - Guest upsell (§5.4, verbatim)

        static let guestImageTitle = LText(
            ar: "توليد الصور يحتاج حسابًا",
            en: "Image generation needs an account"
        )

        static let guestImageBody = LText(
            ar: "أنشئ حسابًا مجانيًا خلال ثوانٍ لتوليد الصور، وحفظ محادثاتك، ورفع حدّك اليومي.",
            en: "Create a free account in seconds to generate images, save your chats, and raise your daily limit."
        )

        static let guestFeatureTitle = LText(
            ar: "هذه الميزة تحتاج حسابًا",
            en: "This feature needs an account"
        )

        static let guestFeatureBody = LText(
            ar: "أنشئ حسابًا مجانيًا لتفعيلها — يستغرق أقل من دقيقة.",
            en: "Create a free account to unlock it — it takes less than a minute."
        )

        static let guestUpgradeCta = LText(ar: "إنشاء حساب مجاني", en: "Create a free account")

        static let guestLater = LText(ar: "لاحقًا", en: "Later")

        /// Reassurance under the upsell CTA: nothing the guest already wrote is lost.
        static let guestKeepsWork = LText(
            ar: "محادثاتك كضيف تنتقل إلى حسابك بعد التسجيل.",
            en: "Your guest chats move into your account once you sign up."
        )

        /// The upsell title for a feature key.
        static func upsellTitle(_ feature: FeatureKey) -> LText {
            feature == .image ? guestImageTitle : guestFeatureTitle
        }

        /// The upsell body for a feature key.
        static func upsellBody(_ feature: FeatureKey) -> LText {
            feature == .image ? guestImageBody : guestFeatureBody
        }
    }
}
