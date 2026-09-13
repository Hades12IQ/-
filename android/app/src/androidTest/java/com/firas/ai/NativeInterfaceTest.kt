package com.firas.ai

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfDocument
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.firas.ai.data.*
import com.firas.ai.render.MathGlyph
import com.firas.ai.render.MathRasterizer
import com.firas.ai.render.MathScanner
import com.firas.ai.ui.*
import com.firas.ai.ui.glass.*
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Uses the production composables and renderer. Content is an explicit local test fixture. */
@RunWith(AndroidJUnit4::class)
class NativeInterfaceTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun nativeChatModelPickerAndSend() {
        var sent = ""
        val prefs = UiPreferences(context).apply { selectTheme("dark"); selectArabic(true) }
        val thread = ChatThread("fixture-chat", "fixture-owner", product=Product.AI, messages=listOf(
            ChatMessage("u", "user", "اشرح لي فكرة التكامل بخطوات واضحة", "fixture"),
            ChatMessage("a", "assistant", "## نفهمها خطوة بخطوة\nالتكامل يجمع التغيّرات الصغيرة ليعطينا النتيجة الكاملة.\n\n\\[\\int_0^1 x^2\\,dx = \\frac{1}{3}\\]\n\nنرفع الأسّ درجة واحدة، ثم نقسم على الأسّ الجديد.", "fixture")
        ))
        compose.setContent {
            FirasTheme(prefs) {
                val glass = remember { HazeState() }
                CompositionLocalProvider(LocalGlassState provides glass) {
                    Box(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize().background(LocalPalette.current.ground).hazeSource(glass))
                        Column(Modifier.statusBarsPadding()) {
                            FirasGlassHeader("Firas Chat", {}, {}, {})
                            ChatScreen(thread, emptyList(), ChatActions({ text, _, _ -> sent=text }, {}, { _, _ -> }, {}, {}, {}, {}))
                        }
                    }
                }
            }
        }
        compose.onNodeWithTag("composer-input").assertExists()
        compose.waitForIdle()
        // The native text updates when the isolated local WebView finishes its first math batch.
        Thread.sleep(2200)
        compose.waitForIdle()
        capture("android-chat-dark")
        compose.onNodeWithTag("model-picker").performClick()
        compose.onNodeWithText("luma 1", substring=true, ignoreCase=true).assertExists()
        compose.onNodeWithText("omnix 1", substring=true, ignoreCase=true).assertExists()
        capture("android-models")
        compose.onNodeWithText("titan 1", substring=true, ignoreCase=true).performClick()
        compose.onNodeWithTag("composer-input").performTextInput("شكراً، أعطني مثالاً")
        compose.onNodeWithTag("send-message").performClick()
        compose.runOnIdle { assertEquals("شكراً، أعطني مثالاً", sent) }
    }

    @Test fun themeSelectionAndProductCaptures() {
        val prefs = UiPreferences(context).apply { selectTheme("dark"); selectArabic(true) }
        var product by mutableStateOf(Product.CODE)
        compose.setContent {
            FirasTheme(prefs) {
                val glass=remember {HazeState()}
                CompositionLocalProvider(LocalGlassState provides glass) {
                    Box(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize().background(LocalPalette.current.ground).hazeSource(glass))
                        Column(Modifier.statusBarsPadding()) {
                            FirasGlassHeader(product.title, {}, {}, {})
                            ChatScreen(ChatThread("preview-${product.name}","fixture-owner",product=product),emptyList(),ChatActions({_,_,_->},{},{_,_->},{},{},{},{}))
                        }
                    }
                }
            }
        }
        compose.waitForIdle(); capture("android-code")
        compose.runOnIdle { product=Product.AGENT }; compose.waitForIdle(); capture("android-agent")
        compose.runOnIdle { product=Product.BRAIN }; compose.waitForIdle(); capture("android-brain")
        compose.runOnIdle { prefs.selectTheme("light"); product=Product.AI }; compose.waitForIdle(); capture("android-chat-light")
    }

    @Test fun nativePdfViewerCloses() {
        val file=File(context.cacheDir,"viewer-fixture.pdf")
        val pdf=PdfDocument()
        try {
            repeat(2) { index ->
                val page=pdf.startPage(PdfDocument.PageInfo.Builder(595,842,index+1).create())
                val paint=android.graphics.Paint().apply {color=Color.BLACK;textSize=24f}
                page.canvas.drawText("Firas AI - page ${index+1}",44f,70f,paint)
                pdf.finishPage(page)
            }
            file.outputStream().use(pdf::writeTo)
        } finally {pdf.close()}
        var open by mutableStateOf(true)
        val prefs=UiPreferences(context)
        compose.setContent { FirasTheme(prefs) {
            if(open) FilePreview(PreviewFile(file,"viewer-fixture.pdf","application/pdf"),onClose={open=false})
            else Text("Viewer closed")
        } }
        compose.waitUntil(15000) {compose.onAllNodesWithContentDescription("الصفحة 1").fetchSemanticsNodes().isNotEmpty()}
        capture("android-pdf-viewer")
        compose.onNodeWithContentDescription("إغلاق",substring=true).performClick()
        compose.onNodeWithText("Viewer closed").assertExists()
    }

    @Test fun savedPdfAndMediaOpenWithoutInternalPrompts() {
        var openedPdf=false; var openedMedia=false
        val document=NativeDocument("fixture-pdf","integrals.pdf","Integration practice","a".repeat(64),12000,3)
        val media=MediaItem("fixture-image","fixture-owner",MediaKind.IMAGE,"fixture-key","A quiet evening",prompt="INTERNAL_PROMPT_MUST_STAY_HIDDEN",threadId="fixture-files")
        val thread=ChatThread("fixture-files","fixture-owner",messages=listOf(
            ChatMessage("pdf","assistant","```firas-file\n${document.metadata()}\n```","pdf-turn"),
            ChatMessage("image","assistant","```firas-image\n{\"jobId\":\"fixture-image\",\"key\":\"fixture-key\",\"prompt\":\"INTERNAL_PROMPT_MUST_STAY_HIDDEN\"}\n```","image-turn")
        ))
        val prefs=UiPreferences(context).apply {selectTheme("dark");selectArabic(true)}
        compose.setContent { FirasTheme(prefs) { Box(Modifier.fillMaxSize().background(LocalPalette.current.ground)) {
            ChatScreen(thread,emptyList(),ChatActions({_,_,_->},{},{_,_->},{},{},{},{},
                openDocument={openedPdf=true},openMedia={openedMedia=true}),media=listOf(media))
        } } }
        compose.onNodeWithTag("open-native-document").performScrollTo().performClick()
        compose.onNodeWithTag("open-media").performScrollTo().performClick()
        compose.runOnIdle {assertTrue(openedPdf);assertTrue(openedMedia)}
        compose.onNodeWithText("INTERNAL_PROMPT_MUST_STAY_HIDDEN",substring=true).assertDoesNotExist()
        capture("android-file-media-cards")
    }

    @Test fun bundledMathRendersAndReusesGlyphs() = runBlocking {
        lateinit var screenContext: android.content.Context
        compose.setContent { screenContext=LocalContext.current; Box(Modifier.fillMaxSize()) }
        compose.waitForIdle()
        val chemistry=MathScanner.streamingPreview("\\[\\ce{H2O}")
        val alignment=MathScanner.streamingPreview("\\[\\begin{aligned}x &= 1")
        assertTrue(chemistry.endsWith("\\]"))
        assertTrue(alignment.contains("\\end{aligned}"))
        val spans=MathScanner.spans("\\[\\int_0^1 x^2\\,dx=\\frac{1}{3}\\] and \\(\\ce{H2O}\\)")
        assertEquals(2,spans.size)
        val glyphs=mutableMapOf<String,MathGlyph>()
        MathRasterizer.render(screenContext,spans,Color.BLACK,18f,"native-smoke",true) {id,glyph->glyphs[id]=glyph}
        assertEquals("Every accepted formula must render",spans.size,glyphs.size)
        assertTrue(glyphs.values.all {it.bitmap.width>4 && it.bitmap.height>4})
        glyphs.values.forEach {glyph ->
            val pixels=IntArray(glyph.bitmap.width*glyph.bitmap.height)
            glyph.bitmap.getPixels(pixels,0,glyph.bitmap.width,0,0,glyph.bitmap.width,glyph.bitmap.height)
            assertTrue("Rendered math must contain visible ink, not an empty bitmap",pixels.count {Color.alpha(it)>0}>10)
        }
        val second=mutableMapOf<String,MathGlyph>()
        MathRasterizer.render(screenContext,spans,Color.BLACK,18f,"native-smoke",true) {id,glyph->second[id]=glyph}
        assertEquals(glyphs.keys,second.keys)
        glyphs.forEach { (id,glyph) -> assertSame(glyph.bitmap,second[id]!!.bitmap) }
    }

    private fun capture(name:String) {
        compose.waitForIdle()
        // Semantics can update before the next native frame is presented to the screenshot API.
        Thread.sleep(350)
        val image=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        assertNotNull(image)
        val directory=File(context.getExternalFilesDir(null),"evidence").apply {mkdirs()}
        File(directory,"$name.png").outputStream().use {image.compress(Bitmap.CompressFormat.PNG,100,it)}
        image.recycle()
        // Preserve explicit fixture screenshots after Gradle removes the test installation.
        val automation=InstrumentationRegistry.getInstrumentation().uiAutomation
        android.os.ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand("mkdir -p /sdcard/Download/firas-native-evidence")).use {it.readBytes()}
        android.os.ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand("cp ${File(directory,"$name.png").absolutePath} /sdcard/Download/firas-native-evidence/$name.png")).use {it.readBytes()}
    }
}
