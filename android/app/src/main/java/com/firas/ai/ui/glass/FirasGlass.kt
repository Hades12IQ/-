package com.firas.ai.ui.glass

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.firas.ai.ui.LocalArabic
import com.firas.ai.ui.LocalPalette
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect

/** Only content behind floating controls is a Haze source; a glass surface never captures itself. */
val LocalGlassState = staticCompositionLocalOf<HazeState?> { null }

@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(24.dp),
    elevated: Boolean = true,
    content: @Composable BoxScope.() -> Unit,
) {
    val p = LocalPalette.current
    val state = LocalGlassState.current
    val style = remember(p) {
        HazeStyle(
            backgroundColor = p.surface,
            tint = HazeTint(p.surface.copy(alpha = if (p.light) .64f else .58f)),
            blurRadius = 24.dp,
            noiseFactor = if (p.id == "black") 0f else .025f,
        )
    }
    val edge = remember(p) { Brush.verticalGradient(listOf(
        Color.White.copy(alpha = if (p.light) .64f else .19f),
        p.border.copy(alpha = .5f),
        Color.White.copy(alpha = if (p.light) .32f else .065f),
    )) }
    val effect = if (state != null) Modifier.hazeEffect(state = state, style = style)
        else Modifier.background(p.surface.copy(alpha = .96f))
    Box(
        modifier.shadow(if (elevated) 12.dp else 0.dp, shape, clip = false,
            ambientColor = Color.Black.copy(alpha = .12f), spotColor = Color.Black.copy(alpha = .18f))
            .clip(shape).then(effect).border(1.dp, edge, shape),
        content = content,
    )
}

/** Fixed-LTR chrome matches RootView/AppShell on iOS, independent of the message language. */
@Composable
fun FirasGlassHeader(
    title: String,
    onMenu: () -> Unit,
    onNew: (() -> Unit)? = null,
    onTemporary: (() -> Unit)? = null,
    onTitle: (() -> Unit)? = null,
) {
    val p = LocalPalette.current
    val ar = LocalArabic.current
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Box(Modifier.fillMaxWidth().height(72.dp).padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
            GlassSurface(Modifier.align(Alignment.CenterStart), shape = CircleShape, elevated = false) {
                IconButton(onClick = onMenu, modifier = Modifier.size(48.dp)) {
                    Icon(Icons.Outlined.Menu, if (ar) "فتح القائمة" else "Open sidebar", tint = p.ink)
                }
            }
            // Equal side reservations keep the title genuinely centered when action counts differ.
            GlassSurface(Modifier.padding(horizontal = 104.dp).widthIn(max = 240.dp),
                shape = RoundedCornerShape(50), elevated = false) {
                if (onTitle != null) TextButton(onClick = onTitle, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)) {
                    Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, color = p.ink)
                    Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.padding(start = 4.dp).size(18.dp), tint = p.secondary)
                } else Text(title, Modifier.padding(horizontal = 16.dp, vertical = 11.dp),
                    style = MaterialTheme.typography.labelLarge, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, color = p.ink)
            }
            if (onNew != null || onTemporary != null) {
                GlassSurface(Modifier.align(Alignment.CenterEnd), shape = RoundedCornerShape(50), elevated = false) {
                    Row {
                        if (onNew != null) IconButton(onClick = onNew, modifier = Modifier.size(48.dp)) {
                            Icon(Icons.Outlined.Edit, if (ar) "محادثة جديدة" else "New conversation", tint = p.ink)
                        }
                        if (onTemporary != null) IconButton(onClick = onTemporary, modifier = Modifier.size(48.dp)) {
                            Icon(Icons.Outlined.TimerOff, if (ar) "محادثة مؤقتة" else "Temporary conversation", tint = p.ink)
                        }
                    }
                }
            }
        }
    }
}
