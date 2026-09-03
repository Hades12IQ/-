import Foundation

/// Every user-visible string the call screen, the dictation bar and the Listen button need.
///
/// The Arabic is verbatim from the web's `STR.ar` table as transcribed in
/// `server-voice.md §6` and `web-voice-call-mic.md §2.2, §7.2, §8`; the English is the matching
/// `STR.en` row. Where the native app needs a sentence the web never had (a call that ends by
/// itself, a Retry button, the iOS Settings app instead of "browser settings") the new copy is
/// marked below and follows the same voice.
extension Strings {

    enum Voice {

        // MARK: - Call chrome

        /// The caller's name on the call screen; the web sets `#callName` to "Firas" at open.
        static let callName = LText(ar: "فِراس", en: "Firas")

        /// Accessibility label of the call button in the composer.
        static let callLabel = LText(ar: "مكالمة صوتية مع فِراس", en: "Voice call with Firas")

        static let callTimerLabel = LText(ar: "مدة المكالمة", en: "Call duration")

        // MARK: - Phases (app.js 243-251 / 1365-1373)

        static let callConnecting = LText(ar: "جارٍ الاتصال…", en: "Connecting…")

        static let callListening = LText(ar: "أستمع… تكلّم الآن", en: "Listening… speak now")

        static let callThinking = LText(ar: "فِراس يفكّر…", en: "Firas is thinking…")

        static let callSpeaking = LText(ar: "فِراس يتحدّث…", en: "Firas is speaking…")

        static let callMuted = LText(ar: "الميكروفون مكتوم", en: "Microphone muted")

        static let callHello = LText(
            ar: "مرحبًا، معك فِراس. تفضّل، أنا أسمعك.",
            en: "Hi, Firas here. Go ahead, I'm listening."
        )

        /// New for iOS: the teardown window between pressing End and the screen closing.
        static let callEnding = LText(ar: "جارٍ الإنهاء…", en: "Ending…")

        /// New for iOS: the screen's resting line after the call is over.
        static let callEnded = LText(ar: "انتهت المكالمة", en: "Call ended")

        // MARK: - Captions (three-hop only)

        static let callTapInterrupt = LText(ar: "اضغط الدائرة لمقاطعته", en: "Tap the circle to interrupt")

        static let callTapTalk = LText(ar: "اضغط للتحدث", en: "Tap to talk")

        static let callRecording = LText(ar: "أستمع… اضغط عند الانتهاء", en: "Listening… tap when done")

        // MARK: - Consent and failures (app.js 252-256 / 1374-1378)

        static let callConsentText = LText(
            ar: "للتحدث في المكالمة، اسمح باستخدام الميكروفون",
            en: "To talk on the call, allow microphone access"
        )

        static let callConsentBtn = LText(
            ar: "السماح بالميكروفون والبدء",
            en: "Allow microphone & start"
        )

        static let callError = LText(
            ar: "تعذّرت المكالمة — تأكد من إذن الميكروفون.",
            en: "Call failed — check microphone permission."
        )

        static let callSorry = LText(
            ar: "عذرًا، لم أستطع المتابعة. حاول مرة أخرى.",
            en: "Sorry, I couldn't continue. Please try again."
        )

        static let callUnsupported = LText(
            ar: "المكالمة الصوتية غير مدعومة على هذا الجهاز.",
            en: "Voice calls aren't supported on this device."
        )

        /// The 403 `signin_required` answer from `/api/live/token` (app.js:49179).
        static let callSignInRequired = LText(
            ar: "المكالمة الصوتية الذكية تحتاج تسجيل دخول — بدونها تشتغل بالوضع البسيط",
            en: "The AI voice call needs an account — without one it runs in basic mode"
        )

        /// Guest ceiling, spoken and toasted before the screen closes (app.js:49505). `%@` is the
        /// number of seconds, already rendered through `ArabicText.count`.
        static let callGuestCap = LText(
            ar: "عذرًا، بدون حساب المكالمة محدودة بـ %@ ثانية — سجّل لتكمل بلا حدود",
            en: "Sorry — without an account a call is limited to %@ seconds. Sign in to keep talking."
        )

        // MARK: - Controls

        static let callMute = LText(ar: "كتم", en: "Mute")

        static let callUnmute = LText(ar: "إلغاء الكتم", en: "Unmute")

        static let callEnd = LText(ar: "إنهاء المكالمة", en: "End call")

        static let callSpeaker = LText(ar: "مكبّر الصوت", en: "Speaker")

        static let callOn = LText(ar: "مفعّل", en: "On")

        static let callOff = LText(ar: "متوقّف", en: "Off")

        /// New for iOS: the failed screen offers a real second attempt (`audit-ios-voice.md V4`).
        static let callRetry = LText(ar: "إعادة الاتصال", en: "Call again")

        // MARK: - Settings → voice

        static let voiceHeader = LText(ar: "صوت المكالمة", en: "Call voice")

        static let voiceSub = LText(ar: "يُطبَّق على مكالمتك القادمة", en: "applies to your next call")

        /// `%@` is the voice name, always Latin.
        static let voiceChanged = LText(
            ar: "صوت المكالمة: %@ — يُطبَّق على المكالمة القادمة",
            en: "Call voice: %@ — applies to the next call"
        )

        // MARK: - Dictation (app.js 229-235 / 1351-1357)

        static let micLabel = LText(ar: "إدخال صوتي", en: "Voice input")

        static let micHint = LText(
            ar: "إدخال صوتي — اضغط مطوّلًا لاختيار اللهجة",
            en: "Voice input — long-press to pick a dialect"
        )

        static let micListening = LText(ar: "جارٍ الاستماع… تكلّم الآن", en: "Listening… speak now")

        static let micTranscribing = LText(ar: "جارٍ تحويل كلامك…", en: "Transcribing your speech…")

        /// The web says "browser settings"; on iOS the fix lives in the Settings app.
        static let micDenied = LText(
            ar: "اسمح بالوصول إلى المايكروفون من الإعدادات ثم أعد المحاولة.",
            en: "Allow microphone access in Settings, then try again."
        )

        static let micUnsupported = LText(
            ar: "التسجيل الصوتي غير مدعوم على هذا الجهاز.",
            en: "Voice recording is not supported on this device."
        )

        static let micTooShort = LText(
            ar: "التسجيل قصير جدًا — تكلّم ثم اضغط ✓.",
            en: "Recording too short — speak, then press ✓."
        )

        static let micFail = LText(
            ar: "تعذّر تحويل الصوت — حاول مرة أخرى.",
            en: "Couldn't transcribe the audio — please try again."
        )

        static let micEmpty = LText(
            ar: "لم أسمع كلامًا واضحًا — حاول مجددًا.",
            en: "I didn't catch any clear speech — try again."
        )

        static let micCancel = LText(ar: "إلغاء التسجيل", en: "Cancel recording")

        static let micDone = LText(ar: "إيقاف وتحويل", en: "Stop and transcribe")

        static let micRecordingLabel = LText(ar: "جارٍ التسجيل", en: "Recording")

        /// New for iOS: the audio session belongs to a live call, and dictation will not fight it.
        static let micBusyCall = LText(
            ar: "أنهِ المكالمة أولًا ثم أملِ كلامك.",
            en: "End the call first, then dictate."
        )

        /// New for iOS: the server transcription failed, but the phone heard the words live and
        /// they are still sitting in the composer. Said once, quietly, never as an error.
        static let micKeptDevice = LText(
            ar: "تعذّر تحسين النص على الخادم — أبقيت ما سمعه جهازك.",
            en: "Couldn't refine it on the server — kept what your device heard."
        )

        /// New for iOS: the accessibility label of the live words as they arrive in the bar.
        static let micLiveText = LText(ar: "النص المسموع", en: "What you're saying")

        // MARK: - Dialect picker

        static let dialectTitle = LText(ar: "لغة الإملاء", en: "Dictation language")

        static let dialectSub = LText(
            ar: "حين تُملي كلامك نصًّا",
            en: "when you speak instead of type"
        )

        static let dialectChipLabel = LText(ar: "لهجة الإملاء", en: "Dictation dialect")

        // MARK: - Listen (app.js 617-626 / 1718-1727)

        static let listen = LText(ar: "اسمع", en: "Listen")

        static let listenStop = LText(ar: "إيقاف", en: "Stop")

        static let listenBusy = LText(ar: "أنهِ المكالمة أول", en: "End the call first")

        static let listenLocal = LText(
            ar: "انتهت حصة الصوت — يكمّل بصوت الجهاز",
            en: "Voice quota spent — finishing on your device"
        )

        static let listenNoVoice = LText(
            ar: "جهازك ما عنده صوت للقراءة — ثبّت صوتًا من إعدادات النظام",
            en: "This device has no speech voice installed — add one in your system settings"
        )

        static let listenNoVoiceAr = LText(
            ar: "جهازك ما عنده صوت عربي — ثبّته من إعدادات اللغة بالنظام، وبعدها يشتغل",
            en: "This device has no Arabic voice — add one in your system language settings and it will work"
        )

        /// New for iOS: the server answered with something that was not audio at all.
        static let listenFailed = LText(
            ar: "تعذّرت القراءة الصوتية — حاول مرة أخرى.",
            en: "Couldn't read it aloud — please try again."
        )
    }
}
