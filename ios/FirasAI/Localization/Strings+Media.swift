import Foundation

/// Every sentence the Studio can show.
///
/// Copy marked "verbatim" is the deployed web client's own wording, carried through
/// `web-media-ux.md §3.5, §3.7, §4.2, §5.2, §6.4, §11` and `server-media.md §1.8, §2.7, §3.6, §5`.
/// The rest is new copy for the surfaces the web does not have (the library, the create form, the
/// quota panel), written in the same voice.
///
/// Numbers are never interpolated into a literal: they arrive through `fmt` as `%@` after
/// `ArabicText.count`, so Arabic renders Arabic-Indic digits and English renders Latin ones.
extension Strings {
    enum Media {

        // MARK: - Surface

        static let title = LText(ar: "الاستوديو", en: "Studio")
        static let libraryTab = LText(ar: "المكتبة", en: "Library")
        static let createTab = LText(ar: "إنشاء", en: "Create")

        /// The bottom strip while renders are in flight; `%@` is the count.
        static let stillRendering = LText(
            ar: "قيد التنفيذ الآن: %@",
            en: "Still rendering: %@"
        )

        // MARK: - Kinds

        static let kindImage = LText(ar: "صورة", en: "Image")
        static let kindEdit = LText(ar: "تعديل", en: "Edit")
        static let kindVideo = LText(ar: "فيديو", en: "Video")
        static let kindSong = LText(ar: "أغنية", en: "Song")

        static func kindLabel(_ kind: MediaKind) -> LText {
            switch kind {
            case .image: return kindImage
            case .video: return kindVideo
            case .music: return kindSong
            }
        }

        // MARK: - Library

        static let libraryEmptyTitle = LText(
            ar: "ما زال الاستوديو فارغًا",
            en: "The studio is still empty"
        )

        static let libraryEmptyBody = LText(
            ar: "اكتب «اصنع لي صورة…» في المحادثة، أو ابدأ من هنا.",
            en: "Type “make me an image…” in a chat, or start here."
        )

        static let libraryEmptyAction = LText(ar: "ابدأ الإنشاء", en: "Start creating")

        static let libraryFilterAll = LText(ar: "الكل", en: "All")

        static let libraryLoadFailed = LText(
            ar: "تعذّر قراءة المكتبة. اسحب للتحديث.",
            en: "The library could not be read. Pull to refresh."
        )

        /// The sticky header of a conversation that has no title yet.
        static let untitledConversation = LText(ar: "محادثة بلا عنوان", en: "Untitled chat")

        /// `%@` is the number of items in that conversation.
        static let conversationCount = LText(ar: "%@ عنصر", en: "%@ items")

        // MARK: - Create form

        static let promptLabel = LText(ar: "الوصف", en: "Prompt")

        static let promptPlaceholderImage = LText(
            ar: "صف الصورة التي تريدها…",
            en: "Describe the picture you want…"
        )

        static let promptPlaceholderEdit = LText(
            ar: "صف التعديل: «اجعل السماء بنفسجية»…",
            en: "Describe the change: “make the sky purple”…"
        )

        static let promptPlaceholderVideo = LText(
            ar: "صف المشهد المتحرّك…",
            en: "Describe the moving shot…"
        )

        static let promptPlaceholderSong = LText(
            ar: "صف الأغنية: الموضوع، اللهجة، الإيقاع…",
            en: "Describe the song: subject, dialect, rhythm…"
        )

        static let lyricsLabel = LText(ar: "الكلمات", en: "Lyrics")

        static let lyricsPlaceholder = LText(
            ar: "اكتب كلماتك هنا…",
            en: "Write your own lyrics here…"
        )

        static let useMyLyrics = LText(ar: "كلماتي", en: "My lyrics")

        static let useMyLyricsHint = LText(
            ar: "يغنّي كلماتك كما كتبتها، بلا كاتب كلمات.",
            en: "Sings your words exactly as written — no lyric author."
        )

        static let genreLabel = LText(ar: "الطابع", en: "Genre")
        static let genreAuto = LText(ar: "تلقائي", en: "Auto")

        /// The section header. Named apart from `shapeLabel(_:)` on purpose — a stored property and
        /// a method may not share a name in one type.
        static let shapeSectionTitle = LText(ar: "الشكل", en: "Shape")
        static let shapeSquare = LText(ar: "مربّع ١٠٢٤×١٠٢٤", en: "Square 1024×1024")
        static let shapeTall = LText(ar: "طولي ١٠٢٤×١٥٣٦", en: "Tall 1024×1536")
        static let shapeWide = LText(ar: "عرضي ١٥٣٦×١٠٢٤", en: "Wide 1536×1024")

        static func shapeLabel(_ shape: ImageShape) -> LText {
            switch shape {
            case .square: return shapeSquare
            case .tall: return shapeTall
            case .wide: return shapeWide
            }
        }

        static let shapeNote = LText(
            ar: "يقصّ الخادم أي بُعد فوق ١٢٨٠ بكسل، وقد يقرّب المحرّك النسبة إلى أقرب نسبة يعرفها.",
            en: "The server clamps any side above 1280 px, and the engine may snap to the nearest ratio it knows."
        )

        static let sourceLabel = LText(ar: "الصورة المصدر", en: "Source picture")
        static let sourceFromLibrary = LText(ar: "من المكتبة", en: "From the library")
        static let sourceFromPhotos = LText(ar: "من الصور", en: "From Photos")
        static let sourceMissing = LText(
            ar: "اختر صورة لتعديلها.",
            en: "Pick a picture to edit."
        )

        static let firstFrameLabel = LText(ar: "الإطار الأول", en: "First frame")
        static let firstFramePick = LText(ar: "اختر صورة", en: "Choose a photo")
        static let firstFrameClear = LText(ar: "أزل الصورة", en: "Remove photo")
        static let firstFrameHint = LText(
            ar: "يبدأ المقطع من صورتك ثم يتحرّك منها.",
            en: "The clip starts from your photo and moves on from there."
        )

        static let durationLabel = LText(ar: "المدة", en: "Duration")
        /// `%@` is the number of seconds.
        static let durationSeconds = LText(ar: "%@ ثانية", en: "%@ s")

        static let targetConversation = LText(ar: "تُضاف إلى", en: "Add to")
        static let targetNewConversation = LText(ar: "محادثة جديدة", en: "A new chat")

        static let createAction = LText(ar: "أنشئ", en: "Create")
        static let createWorking = LText(ar: "جارٍ…", en: "Working…")

        static let promptRequired = LText(
            ar: "اكتب وصفًا أولًا.",
            en: "Write a description first."
        )

        // MARK: - Quota panel

        static let quotaTitle = LText(ar: "حدودك اليوم", en: "Your limits today")

        /// `%@` used, `%@` limit.
        static let quotaImages = LText(
            ar: "الصور: %@ من %@ اليوم",
            en: "Images: %@ of %@ today"
        )

        static let quotaImagesUnmetered = LText(
            ar: "الصور: بلا حدّ يومي.",
            en: "Images: no daily limit."
        )

        static let quotaImagesUnknown = LText(
            ar: "الصور: تعذّرت قراءة الحدّ الآن.",
            en: "Images: the limit could not be read right now."
        )

        static let quotaResets = LText(
            ar: "يتجدّد الحدّ بعد منتصف الليل بتوقيت بغداد.",
            en: "The limit resets after midnight, Baghdad time."
        )

        static let quotaVideoWindow = LText(
            ar: "الفيديو: ٦ مقاطع كل ساعتين.",
            en: "Video: 6 clips every 2 hours."
        )

        static let quotaMusicWindow = LText(
            ar: "الأغاني: ١٠ أغانٍ كل ساعتين.",
            en: "Songs: 10 songs every 2 hours."
        )

        /// After a 429 `rate_window`; `%@` is `freesInMin`.
        static let quotaFreesIn = LText(
            ar: "يتحرّر مكان بعد %@ دقيقة.",
            en: "A slot frees up in %@ minutes."
        )

        // MARK: - Loaders (verbatim, web-media-ux.md §3.5, §5.2, §6.4)

        static let imageLoaderWords: [LText] = [
            LText(ar: "أقرأ طلبك", en: "Reading your prompt"),
            LText(ar: "أُركّب المشهد", en: "Composing the scene"),
            LText(ar: "أضبط الضوء", en: "Setting the light"),
            LText(ar: "أصقل التفاصيل", en: "Refining details")
        ]

        static let videoPreparing = LText(ar: "يجهّز الفيديو…", en: "Preparing the video…")

        static let videoWorking = LText(
            ar: "يولّد الفيديو… قد يستغرق نحو نصف دقيقة",
            en: "Generating video… this takes about half a minute"
        )

        static let songWritingLyrics = LText(ar: "يكتب الكلمات…", en: "Writing the lyrics…")

        /// The lyric author came back empty — verbatim (`app.js:42007`).
        static let lyricAuthorFailed = LText(
            ar: "ما قدرت أكتب الكلمات. جرّب توصف النشيد بشكل أوضح.",
            en: "I could not write the lyrics. Try describing the song more clearly."
        )

        static let songComposing = LText(
            ar: "يلحّن الأغنية… حوالي دقيقة",
            en: "Composing… about a minute"
        )

        static func loaderText(_ kind: MediaKind, step: Int, lang: AppLanguage) -> String {
            switch kind {
            case .image:
                let words = imageLoaderWords
                guard !words.isEmpty else { return videoPreparing(lang) }
                return words[((step % words.count) + words.count) % words.count](lang)
            case .video:
                return videoWorking(lang)
            case .music:
                return songComposing(lang)
            }
        }

        // MARK: - Guest upsell (verbatim, web-media-ux.md §2)

        static let guestImageTitle = LText(
            ar: "توليد الصور يحتاج حسابًا",
            en: "Image generation needs an account"
        )

        static let guestImageBody = LText(
            ar: "أنشئ حسابًا مجانيًا خلال ثوانٍ لتوليد الصور، وحفظ محادثاتك، ورفع حدّك اليومي.",
            en: "Create a free account in seconds to generate images, save your chats, and raise your daily limit."
        )

        static let guestVideoTitle = LText(
            ar: "توليد الفيديو للأعضاء",
            en: "Video generation is for members"
        )

        static let guestVideoBody = LText(
            ar: "أنشئ حسابًا مجانيًا لتوليد مقاطع فيديو.",
            en: "Create a free account to generate video clips."
        )

        static let guestSongTitle = LText(ar: "الأناشيد للأعضاء", en: "Songs are for members")

        static let guestSongBody = LText(
            ar: "أنشئ حسابًا مجانيًا حتى تصنع نشيدًا.",
            en: "Create a free account to make one."
        )

        static let guestCreateAccount = LText(ar: "إنشاء حساب مجاني", en: "Create a free account")

        static func guestTitle(_ kind: MediaKind) -> LText {
            switch kind {
            case .image: return guestImageTitle
            case .video: return guestVideoTitle
            case .music: return guestSongTitle
            }
        }

        static func guestBody(_ kind: MediaKind) -> LText {
            switch kind {
            case .image: return guestImageBody
            case .video: return guestVideoBody
            case .music: return guestSongBody
            }
        }

        // MARK: - Outcomes (verbatim)

        /// `imageRemainingText` — `%@` remaining, `%@` limit.
        static let imageRemaining = LText(
            ar: "تم إنشاء الصورة • تبقّى لك %@ من %@ اليوم",
            en: "Image created • %@ of %@ left today"
        )

        static let imageCreated = LText(ar: "تم إنشاء الصورة", en: "Image created")
        static let videoCreated = LText(ar: "صار الفيديو جاهزًا", en: "Your video is ready")
        static let songCreated = LText(ar: "صارت الأغنية جاهزة", en: "Your song is ready")

        static func createdText(_ kind: MediaKind) -> LText {
            switch kind {
            case .image: return imageCreated
            case .video: return videoCreated
            case .music: return songCreated
            }
        }

        // MARK: - Failure plates (verbatim)

        static let imageFailedTitle = LText(ar: "تعذّر توليد الصورة", en: "Image generation failed")
        static let retryAgain = LText(ar: "إعادة المحاولة", en: "Try again")
        static let regenerate = LText(ar: "أعد التوليد", en: "Regenerate")
        static let regenerateSong = LText(ar: "أعد التلحين", en: "Regenerate")
        static let working = LText(ar: "جارٍ…", en: "Working…")

        static let imageWhyNetwork = LText(
            ar: "تعذّر الوصول إلى الصورة — تحقّق من اتّصالك.",
            en: "The picture could not be fetched — check your connection."
        )

        static let imageWhyEngine = LText(ar: "لم يُعدِ المحرّك صورة.", en: "The engine returned no picture.")

        static let imageWhyQuota = LText(
            ar: "بلغت حدّك اليومي من الصور. الحدّ يتجدّد غدًا.",
            en: "You have reached today's image limit. It resets tomorrow."
        )

        static let imageWhySignIn = LText(
            ar: "انتهت جلستك. سجّل الدخول ثمّ أعد المحاولة.",
            en: "Your session ended. Sign in and try again."
        )

        static let videoFailed = LText(ar: "تعذّر توليد الفيديو", en: "Video generation failed")
        static let songFailed = LText(ar: "ما ضبط التلحين", en: "The song did not come out")

        static let renderTimedOut = LText(
            ar: "طال الانتظار أكثر من اللازم. أعِد المحاولة — النتيجة قد تكون جاهزة في الذاكرة.",
            en: "That took too long. Try again — the result may already be cached."
        )

        static func failureText(_ kind: MediaKind, code: String?, lang: AppLanguage) -> String {
            let raw = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch raw {
            case "signin_required", "account_required":
                return imageWhySignIn(lang)
            case "daily_limit":
                return imageWhyQuota(lang)
            case "rate_window", "site_media_ceiling":
                return Strings.Errors.musicRateWindow(lang)
            case "rate_limited":
                return Strings.Errors.tooFast(lang)
            case "not_configured":
                return kind == .music
                    ? Strings.Errors.musicNotConfigured(lang)
                    : Strings.Errors.videoNotConfigured(lang)
            case "bad_image", "image_too_large":
                return Strings.Errors.badImage(lang)
            case "timeout", "expired":
                return renderTimedOut(lang)
            default:
                switch kind {
                case .image: return imageWhyEngine(lang)
                case .video: return videoFailed(lang)
                case .music: return songFailed(lang)
                }
            }
        }

        // MARK: - Image edit outcomes (verbatim, web-media-ux.md §4.2)

        static let editDailyLimit = LText(
            ar: "بلغت حدّك اليومي من تعديل الصور. جرّب غدًا.",
            en: "You have reached your daily image-editing limit. Try again tomorrow."
        )

        static let editUnavailable = LText(
            ar: "تعديل الصور غير متاح حاليًا — المحرّك الذي يقوم به نفد رصيده. توليد صور جديدة ما زال يعمل.",
            en: "Image editing is unavailable right now — the engine that performs it is out of credit. Generating new images still works."
        )

        static let editSignIn = LText(ar: "سجّل الدخول لتعديل الصور.", en: "Sign in to edit images.")

        static let editBadImage = LText(
            ar: "تعذّرت قراءة الصورة المرفقة.",
            en: "That attached image could not be read."
        )

        static let editFailed = LText(
            ar: "تعذّر تعديل الصورة. حاول مرة أخرى، أو صِف التعديل بتفصيل أوضح.",
            en: "The image could not be edited. Try again, or describe the change more specifically."
        )

        static func editErrorText(code: String?, lang: AppLanguage) -> String {
            switch (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "daily_limit": return editDailyLimit(lang)
            case "edit_unavailable", "openai_unconfigured", "no_budget": return editUnavailable(lang)
            case "signin_required", "account_required": return editSignIn(lang)
            case "bad_image": return editBadImage(lang)
            default: return editFailed(lang)
            }
        }

        // MARK: - Viewer and item actions

        static let openInChat = LText(ar: "اعرضها في المحادثة", en: "Show it in the chat")
        static let saveToPhotos = LText(ar: "حفظ في الصور", en: "Save to Photos")
        static let editPicture = LText(ar: "تعديل", en: "Edit")
        static let regenerateItem = LText(ar: "إعادة التوليد", en: "Regenerate")
        static let removeItem = LText(ar: "إزالة من المكتبة", en: "Remove from library")

        static let savedToPhotos = LText(ar: "تم الحفظ في الصور.", en: "Saved to Photos.")

        static let saveFailed = LText(ar: "تعذّر حفظ الصورة.", en: "The image could not be saved.")

        static let photosDenied = LText(
            ar: "اسمح لفِراس بإضافة الوسائط إلى الصور من إعدادات iPhone.",
            en: "Allow Firas to add media to Photos in iPhone Settings."
        )

        static let songNotSavable = LText(
            ar: "الأغاني لا تُحفظ في الصور — استخدم المشاركة لحفظها في الملفات.",
            en: "Songs cannot go to Photos — use Share to keep one in Files."
        )

        static let downloadFailed = LText(
            ar: "تعذّر تنزيل الملف. تحقّق من اتصالك ثم أعد المحاولة.",
            en: "The file could not be downloaded. Check your connection and try again."
        )

        static let preparingFile = LText(ar: "يجهّز الملف…", en: "Preparing the file…")

        static let noteLabel = LText(ar: "التعليق", en: "Caption")

        // MARK: - Song player

        static let play = LText(ar: "تشغيل", en: "Play")
        static let pause = LText(ar: "إيقاف مؤقّت", en: "Pause")
        static let seek = LText(ar: "موضع التشغيل", en: "Seek")
        static let songUntitled = LText(ar: "نشيد", en: "Song")
        static let lyricsSectionTitle = LText(ar: "الكلمات", en: "Lyrics")

        // MARK: - Accessibility

        static let imageTileLabel = LText(ar: "صورة: %@", en: "Image: %@")
        static let videoTileLabel = LText(ar: "فيديو: %@", en: "Video: %@")
        static let songTileLabel = LText(ar: "أغنية: %@", en: "Song: %@")

        static func tileLabel(_ kind: MediaKind) -> LText {
            switch kind {
            case .image: return imageTileLabel
            case .video: return videoTileLabel
            case .music: return songTileLabel
            }
        }
    }
}
