package com.firas.ai.ui

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.style.TextDirection
import com.firas.ai.R

data class FirasPalette(val id: String, val nameAr: String, val nameEn: String,
    val ground: Color, val surface: Color, val ink: Color, val secondary: Color,
    val accent: Color, val bubble: Color, val border: Color, val light: Boolean = false)

private fun color(hex: Long) = Color(0xFF000000 or hex)

/** Same subdued hue mix as FirasPalette.leaning in the iOS design system. */
private fun bubble(base: Long, accent: Long, light: Boolean = false): Color {
    val ground = color(base)
    val source = color(accent)
    val high = maxOf(source.red, source.green, source.blue)
    val low = minOf(source.red, source.green, source.blue)
    val delta = high - low
    if (delta <= .02f) return ground
    var sector = when (high) {
        source.red -> (source.green - source.blue) / delta
        source.green -> 2f + (source.blue - source.red) / delta
        else -> 4f + (source.red - source.green) / delta
    }
    if (sector < 0f) sector += 6f
    val value = if (light) .62f else .55f
    val chroma = value * if (light) .45f else .50f
    val intermediate = chroma * (1f - kotlin.math.abs(sector % 2f - 1f))
    val offset = value - chroma
    val rgb = when (sector.toInt() % 6) {
        0 -> Triple(chroma, intermediate, 0f)
        1 -> Triple(intermediate, chroma, 0f)
        2 -> Triple(0f, chroma, intermediate)
        3 -> Triple(0f, intermediate, chroma)
        4 -> Triple(intermediate, 0f, chroma)
        else -> Triple(chroma, 0f, intermediate)
    }
    val amount = if (light) .16f else .18f
    return Color(ground.red + (rgb.first + offset - ground.red) * amount,
        ground.green + (rgb.second + offset - ground.green) * amount,
        ground.blue + (rgb.third + offset - ground.blue) * amount)
}
val palettes = listOf(
    FirasPalette("dark", "ليلي", "Dark", color(0x262624), color(0x30302E), color(0xECEAE3), color(0xA6A39A), color(0x7E9B93), bubble(0x3A3A37, 0x7E9B93), color(0x363532)),
    FirasPalette("light", "نهاري", "Light", color(0xFAF9F5), Color.White, color(0x1A1A18), color(0x5C5B54), color(0x35695E), bubble(0xEEECE3, 0x35695E, true), color(0xE9E7DE), true),
    FirasPalette("black", "أسود", "Black", Color.Black, color(0x161616), color(0xF2F2F0), color(0xABABA6), color(0x83A099), bubble(0x1E1E1D, 0x83A099), color(0x202020)),
    FirasPalette("midnight", "نيلي", "Midnight", color(0x0F1522), color(0x182133), color(0xE6ECF5), color(0x9FACC2), color(0x8899A9), bubble(0x29354A, 0x8899A9), color(0x202B3E)),
    FirasPalette("graphite", "كربوني", "Graphite", color(0x171719), color(0x202023), color(0xECECEE), color(0xA5A5AA), color(0x82969E), bubble(0x2B2B2F, 0x82969E), color(0x282829)),
    FirasPalette("amber", "عنبري", "Amber", color(0x1B1713), color(0x241F19), color(0xF0E7D8), color(0xB3A793), color(0xB0A08B), bubble(0x342D25, 0xB0A08B), color(0x2E2822))
)
val LocalPalette = staticCompositionLocalOf { palettes.first() }
val LocalArabic = staticCompositionLocalOf { true }
@Composable fun tr(ar: String, en: String): String = if (LocalArabic.current) ar else en

class UiPreferences(context: Context) {
    private val store = context.getSharedPreferences("native-interface", Context.MODE_PRIVATE)
    var theme by mutableStateOf(store.getString("theme", "dark") ?: "dark"); private set
    var arabic by mutableStateOf(store.getBoolean("arabic", true)); private set
    fun selectTheme(id: String) { if (palettes.any { it.id == id }) { theme = id; store.edit().putString("theme", id).apply() } }
    fun selectArabic(value: Boolean) { arabic = value; store.edit().putBoolean("arabic", value).apply() }
}

@Composable fun FirasTheme(preferences: UiPreferences, content: @Composable () -> Unit) {
    val p = palettes.firstOrNull { it.id == preferences.theme } ?: palettes.first()
    val colors = if (p.light) lightColorScheme() else darkColorScheme()
    val font = if (preferences.arabic) FontFamily(Font(R.font.notosansarabic)) else FontFamily.SansSerif
    val typography = Typography(
        bodyLarge = androidx.compose.ui.text.TextStyle(fontFamily = font, fontSize = 17.sp, lineHeight = if (preferences.arabic) 31.sp else 28.sp,
            textDirection = if (preferences.arabic) TextDirection.ContentOrRtl else TextDirection.ContentOrLtr),
        bodyMedium = androidx.compose.ui.text.TextStyle(fontFamily = font, fontSize = 15.sp, lineHeight = 24.sp),
        bodySmall = androidx.compose.ui.text.TextStyle(fontFamily = font, fontSize = 13.sp, lineHeight = 20.sp),
        titleLarge = androidx.compose.ui.text.TextStyle(fontFamily = font, fontSize = 24.sp, fontWeight = FontWeight.SemiBold),
        titleMedium = androidx.compose.ui.text.TextStyle(fontFamily = font, fontSize = 18.sp, fontWeight = FontWeight.SemiBold),
        labelLarge = androidx.compose.ui.text.TextStyle(fontFamily = font, fontSize = 14.sp, fontWeight = FontWeight.Medium),
        labelMedium = androidx.compose.ui.text.TextStyle(fontFamily = font, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    )
    CompositionLocalProvider(LocalPalette provides p, LocalArabic provides preferences.arabic, LocalContentColor provides p.ink,
        LocalLayoutDirection provides LayoutDirection.Ltr) {
        MaterialTheme(colorScheme = colors.copy(primary = p.accent, onPrimary = if (p.light) Color.White else p.ground,
            background = p.ground, onBackground = p.ink, surface = p.surface, onSurface = p.ink,
            surfaceVariant = p.surface, onSurfaceVariant = p.secondary, outline = p.border, secondary = p.accent,
            secondaryContainer = p.bubble, onSecondaryContainer = p.ink), typography = typography, content = content)
    }
}

@Composable fun FirasMark(modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Canvas(modifier.size(width = 26.dp, height = 36.dp)) {
        val x = size.width / 32f; val y = size.height / 44f
        drawRect(p.accent, Offset.Zero, Size(6.5f*x, 44f*y))
        drawPath(Path().apply { moveTo(6.5f*x,0f); lineTo(32f*x,0f); lineTo(27f*x,8.5f*y); lineTo(6.5f*x,8.5f*y); close() }, p.accent)
        drawPath(Path().apply { moveTo(6.5f*x,17f*y); lineTo(24f*x,17f*y); lineTo(19.5f*x,25.5f*y); lineTo(6.5f*x,25.5f*y); close() }, p.accent.copy(alpha=.68f))
    }
}
