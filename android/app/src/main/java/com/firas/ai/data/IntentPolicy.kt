package com.firas.ai.data

import java.text.Normalizer

/** Fast deterministic routes; questions, translations and code examples never start a media bill. */
object IntentPolicy {
    // Explicit Unicode boundaries keep Android and desktop JVM classification identical.
    // JVM \b can use ASCII \w, which excludes words beginning/ending with letters such as ş/ı.
    private const val WORD_START = "(?<![\\p{L}\\p{M}\\p{N}_])"
    private const val WORD_END = "(?![\\p{L}\\p{M}\\p{N}_])"
    private fun normalized(text: String) = Normalizer.normalize(text.lowercase(), Normalizer.Form.NFKC)
        .replace(Regex("[أإآٱ]"), "ا").replace('ى', 'ي').replace('ة', 'ه').replace(Regex("[\\u064B-\\u065F\\u0670]"), "")
    private val document = Regex("(?i)(?:$WORD_START(?:pdf|docx?|xlsx?|pptx?|csv|markdown|booklet|document|report|brochure|worksheet|handout)$WORD_END|ملف|تقرير|كتيب|ملزمه|مستند|دفتر|وثيقه)")
    private val action = Regex("(?i)(?:$WORD_START(?:make|create|generate|design|draw|produce|compose|render|edit|animate|crea|crear|genera|generar|diseña|fais|crée|cree|génère|genere|dessine|erstelle|erzeuge|zeichne|yap|oluştur|çiz|uret|üret)$WORD_END|اصنع|انش[ئء]|صمم|سوي|سولي|ارسم|اريد|ابغي|حضر|سوّي|درست|بساز|بکش|دروست|بکە|بكه|生成|制作|作成|描いて|만들|그려)")
    private val discussion = Regex("(?i)(?:^\\s*(?:why|how|what|explain|translate|summarize|describe|compare|can you explain|pourquoi|comment|explique|traduis|traduce|explica|erkläre|übersetze|neden|açıkla|çevir)$WORD_END|^\\s*(?:ليش|لماذا|شلون|اشرح|ترجم|وضح|لخص|ما معنى|ما هو|شنو|چرا|ترجمه|توضیح|なぜ|説明|翻訳|解释|翻译|설명|번역))")
    private val negation = Regex("(?i)(?:$WORD_START(?:do not|don't|dont|never|no need to|not asking|ne pas|ne crée|ne cree|no crees|nicht erstellen|nicht generieren)$WORD_END|لا تصنع|لا تنش|لا تسوي|لا اريد|مو اريد|ما اريد|نساز|不要生成|생성하지)")
    private val image = Regex("(?i)(?:$WORD_START(?:image|picture|photo|illustration|logo|poster|portrait|imagen|foto|affiche|bild|resim|görsel)$WORD_END|صوره|صور|رسمه|شعار|بوستر|تصویر|عکس|وێنه|وێنە|画像|图像|图片|이미지|사진)")
    private val video = Regex("(?i)(?:$WORD_START(?:video|clip|movie|animation|film|vídeo)$WORD_END|فيديو|مقطع|ڤیدیۆ|ویدیو|ویدئو|動画|视频|비디오|동영상)")
    private val music = Regex("(?i)(?:$WORD_START(?:song|music|track|chanson|musique|canción|cancion|música|musica|lied|musik|şarkı|sarki|müzik)$WORD_END|اغني|غنيه|موسيقي|لحن|گۆرانی|گۆراني|اهنگ|آهنگ|ترانه|歌曲|音乐|音楽|노래|음악)")
    private val lyricsOnly = Regex("(?i)(?:$WORD_START(?:lyrics only|only lyrics|write (?:the )?lyrics|translate (?:the )?lyrics)$WORD_END|كلمات فقط|فقط الكلمات|اكتب كلمات|ترجم كلمات)")
    fun documentFormat(text: String): String? {
        val value = normalized(text)
        for (format in listOf("pdf", "docx", "xlsx", "pptx", "csv", "html", "md", "txt")) if (Regex("(?i)(?:^|[\\s.])$format(?:$|[\\s.,!?])").containsMatchIn(value)) return if (format == "md") "markdown" else format
        return "pdf".takeIf { document.containsMatchIn(value) && !discussion.containsMatchIn(value) }
    }
    fun wantsDocumentRevision(text: String): Boolean {
        val value = normalized(text)
        return !discussion.containsMatchIn(value) && (Regex("(?i)(?:$WORD_START(?:edit|revise|remove|replace|change|fix|improve|larger|smaller|font|color)$WORD_END|عدل|احذف|شيل|غير|صلح|كبر|صغر|الخط|اللون|شكله|ما عجبني)").containsMatchIn(value))
    }
    fun media(text: String): MediaKind? {
        val value = normalized(text)
        if (document.containsMatchIn(value) || discussion.containsMatchIn(value) || negation.containsMatchIn(value) || lyricsOnly.containsMatchIn(value)) return null
        if (Regex("(?i)$WORD_START(?:code|python|javascript|swift|kotlin|api|function|script)$WORD_END|اكتب كود|داله|كود").containsMatchIn(value)) return null
        if (!action.containsMatchIn(value)) return null
        return when { video.containsMatchIn(value) -> MediaKind.VIDEO; music.containsMatchIn(value) -> MediaKind.MUSIC; image.containsMatchIn(value) -> MediaKind.IMAGE; else -> null }
    }
}
