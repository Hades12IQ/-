#if DEBUG
import Foundation

enum MediaIntentChecks {
    static func failures() -> [String] {
        let cases: [(String, String, Bool, RequestKind)] = [
            ("iraqi-song", "سويلي اغنيه حزينة عن امي", false, .music),
            ("iraqi-image", "اريد صوره لقطة بالليل", false, .image),
            ("arabic-polite-video", "ممكن تصنع لي فيديو لمدينة بغداد؟", false, .video),
            ("arabic-edit", "عدّل هالصورة وخلي الالوان دافئة", true, .imageEdit),
            ("arabic-photo-video", "حول هالصورة لفيديو", true, .video),
            ("kurdish-image", "وێنەیەک دروست بکە", false, .image),
            ("kurdish-song", "گۆرانییەک دروست بکە", false, .music),
            ("persian-image", "یک تصویر از کوه بساز", false, .image),
            ("persian-song", "یک آهنگ غمگین بساز", false, .music),
            ("turkish-image", "Bana bir resim oluştur", false, .image),
            ("turkish-song", "Hüzünlü bir şarkı bestele", false, .music),
            ("english-song", "Please compose a sad song about home", false, .music),
            ("english-music-video", "Create a music video about Baghdad", false, .video),
            ("english-draw", "Draw a cat in a garden", false, .image),
            ("french-image", "Peux-tu créer une image de montagne ?", false, .image),
            ("french-song", "Crée une chanson triste", false, .music),
            ("french-edit", "Modifie cette image", true, .imageEdit),
            ("french-photo-video", "Transforme cette image en vidéo", true, .video),
            ("spanish-image", "Crea una imagen de un gato", false, .image),
            ("spanish-video", "Genera un vídeo del océano", false, .video),
            ("german-image", "Erstelle ein Bild von einer Katze", false, .image),
            ("german-song", "Komponiere ein trauriges Lied", false, .music),
            ("chinese-image", "请生成一张猫的图片", false, .image),
            ("chinese-song", "请制作一首歌", false, .music),
            ("japanese-image", "猫の画像を作ってください", false, .image),
            ("japanese-song", "悲しい歌を作ってください", false, .music),
            ("korean-song", "슬픈 노래를 만들어 줘", false, .music),
            ("hindi-image", "एक तस्वीर बनाओ", false, .image),
            ("urdu-song", "ایک گانا بناؤ", false, .music),
            ("indonesian-video", "Buatkan video tentang laut", false, .video),
            ("iraqi-negation", "لا تسويلي اغنية", false, .chat),
            ("english-negation", "Don't create an image", false, .chat),
            ("english-curly-negation", "Don’t create an image", false, .chat),
            ("kurdish-negation", "وێنەیەک دروست مەکە", false, .chat),
            ("turkish-negation", "Resim oluşturma", false, .chat),
            ("french-negation", "Ne crée pas de chanson", false, .chat),
            ("german-negation", "Erstelle kein Bild", false, .chat),
            ("chinese-negation", "请不要生成图片", false, .chat),
            ("negative-then-request", "لا تصنع صورة؛ اصنع أغنية", false, .music),
            ("translate-quoted-command", "Translate 'create an image' into French", false, .chat),
            ("arabic-explain", "اشرح شلون اصنع فيديو", false, .chat),
            ("english-how-to", "How do I create an image?", false, .chat),
            ("french-how-to", "Comment créer une image ?", false, .chat),
            ("japanese-how-to", "画像を生成する方法を教えて", false, .chat),
            ("arabic-lyrics-only", "اكتب كلمات اغنية عن الشتاء", false, .chat),
            ("english-lyrics-only", "Write lyrics for a song about home", false, .chat),
            ("song-description", "اكتبلي وصف اغنية عن الشتاء", false, .chat),
            ("math-graph", "Draw y = x^2", false, .chat),
            ("lyrics-to-audio", "Turn these lyrics into a song", false, .music),
            ("chinese-article", "写一篇关于歌曲的文章", false, .chat),
            ("software-about-images", "Build a website that generates images", false, .code),
            ("software-about-songs", "سوي لي موقع يعرض الاغاني", false, .code),
            ("spanish-pdf", "Crea un PDF sobre imágenes", false, .file(format: "pdf", explicitPages: nil)),
            ("pdf-with-photo", "Create a PDF containing this image", true, .file(format: "pdf", explicitPages: nil)),
            ("powerpoint-about-songs", "اعمل لي بوربوينت عن الاغاني العراقية", false, .file(format: "pptx", explicitPages: nil)),
            ("designed-file-with-pictures", "صمملي ملف عن الرياضيات وبيه صور", false, .file(format: "pdf", explicitPages: nil)),
            ("designed-report-with-pictures", "سوي تقرير احترافي مع صور", false, .file(format: "pdf", explicitPages: nil)),
            ("photos-to-document", "حوّل الصور المرفقة إلى ملف", true, .file(format: "pdf", explicitPages: nil)),
            ("photos-as-document", "سوي الصور المرفقة كملف", true, .file(format: "pdf", explicitPages: nil)),
            ("document-edit-from-screenshot", "عدل نفس الملف احذف الجزء المحدد بالصورة", true, .file(format: "pdf", explicitPages: nil)),
            ("designed-booklet", "create a beautifully designed booklet with photos", false, .file(format: "pdf", explicitPages: nil)),
            ("pdf-edit-from-screenshot", "revise this PDF using the attached screenshot", true, .file(format: "pdf", explicitPages: nil)),
            ("long-video-brief", "Create a video of the sea. " + String(repeating: "Gentle waves and warm morning light. ", count: 45), false, .video)
        ]
        var failures: [String] = []
        for (name, prompt, hasImages, expected) in cases {
            let actual = RequestClassifier.classify(prompt, hasImages: hasImages, lang: .arabic)
            if actual != expected { failures.append("media-intent-" + name) }
        }
        if !RequestClassifier.refersToPreviousImage("Modifie cette image") {
            failures.append("media-intent-multilingual-photo-followup")
        }
        if RequestClassifier.classify("Translate this image", hasImages: true, lang: .english) == .imageEdit {
            failures.append("media-intent-translation-must-not-edit")
        }
        let revisions: [(String, String, Bool, String?)] = [
            ("screenshot-remove", "احذف الجزء المحدد بالصورة", true, "pdf"),
            ("same-document-edit", "عدل نفس الملف وخلي الصورة أصغر", true, "pdf"),
            ("replace-paragraph", "Replace the second paragraph with this text", true, "pdf"),
            ("recolor-heading", "Change the heading color to blue", true, "pdf"),
            ("iraqi-small-font-command", "الخط صغير بالملف، كبره", true, "pdf"),
            ("iraqi-small-font-feedback", "الخط صغير بالملف", true, "pdf"),
            ("iraqi-color-feedback", "هذا اللون ما عجبني بالملف", true, "pdf"),
            ("iraqi-appearance-feedback", "الملف شكله سيء", true, "pdf"),
            ("font-feedback-document", "The font is too small in this document", true, "pdf"),
            ("screenshot-font-feedback", "الخط بالصورة المرفقة مو واضح", true, "pdf"),
            ("feedback-why-question", "ليش الخط صغير بالملف؟", true, nil),
            ("feedback-explain-question", "اشرح لي ليش هذا اللون بالملف ما عجبني", true, nil),
            ("feedback-without-source", "الملف شكله سيء", false, nil),
            ("unrelated-color-feedback", "هذا اللون ما عجبني", true, nil),
            ("negated-font-change", "Don't change the font in this document", true, nil),
            ("no-source", "احذف الجزء المحدد بالصورة", false, nil),
            ("unrelated-image", "Create a new image and add a red border", true, nil),
            ("direct-photo-edit", "Edit this image", true, nil),
            ("translated-edit", "Translate 'remove the second paragraph' into French", true, nil),
            ("negated-document-edit", "Don't create a PDF; remove the background from this photo", true, nil)
        ]
        for (name, prompt, hasDocument, expected) in revisions {
            if RequestClassifier.documentRevisionFormat(prompt, hasPreviousDocument: hasDocument) != expected {
                failures.append("document-revision-" + name)
            }
        }
        // Server history deliberately omits intent. A terse edit must still inherit the actual
        // source file format, including metadata that omits format like the web's normal fence.
        let persistedRevision = [
            ChatMessage.user("Create a DOCX file", cid: "docx-source-question", lang: .english),
            ChatMessage(id: "docx-source-answer", role: .assistant,
                content: "```firas-file\n{\"filename\":\"source.docx\"}\n```\nFirst paragraph.\n\nSecond paragraph."),
            ChatMessage.user("Remove the second paragraph", cid: "docx-edit-question", lang: .english),
            ChatMessage(id: "docx-edit-answer", role: .assistant,
                content: "```firas-file\n{\"filename\":\"revised.docx\"}\n```\nFirst paragraph.")
        ]
        if RequestClassifier.documentFormat(forAssistantAt: 3, in: persistedRevision) != "docx" {
            failures.append("document-revision-retains-format-after-reload")
        }
        return failures
    }
}
#endif
