package com.firas.ai.ui

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.firas.ai.data.FirasModelTier
import com.firas.ai.ui.glass.LocalGlassState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import kotlinx.coroutines.launch

internal enum class ComposerSheet { MODELS, ADD }

/** Native modal behavior supplies drag, Back, outside dismissal, focus isolation and motion scaling. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ComposerMenuSheet(
    page: ComposerSheet,
    tier: FirasModelTier,
    thinking: Boolean,
    onThinking: (Boolean) -> Unit,
    onModel: (FirasModelTier) -> Unit,
    onDismiss: () -> Unit,
    onModels: () -> Unit,
    onPhotos: () -> Unit,
    onFiles: () -> Unit,
    onCamera: (() -> Unit)?,
    onVoice: () -> Unit,
) {
    val p = LocalPalette.current
    val ar = LocalArabic.current
    val haptics = LocalHapticFeedback.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    fun closeThen(action: () -> Unit = {}) {
        scope.launch { sheetState.hide(); onDismiss(); action() }
    }
    val height = (LocalConfiguration.current.screenHeightDp * .88f).dp
    val shape = RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp)
    val haze = LocalGlassState.current
    val glass = if (haze == null) Modifier else Modifier.hazeEffect(haze, HazeStyle(
        backgroundColor = p.ground, tint = HazeTint(Color.Transparent), blurRadius = 28.dp, noiseFactor = 0f))
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState,
        sheetMaxWidth = 520.dp, shape = shape, containerColor = Color.Transparent, contentColor = p.ink,
        tonalElevation = 0.dp, scrimColor = Color.Black.copy(alpha = if (p.light) .18f else .32f),
        dragHandle = null, contentWindowInsets = { WindowInsets(0, 0, 0, 0) }) {
        Column(Modifier.fillMaxWidth().heightIn(max = height).clip(shape).then(glass)
            .background(Brush.verticalGradient(listOf(p.surface.copy(alpha = .91f), p.surface.copy(alpha = .98f))))
            .border(.75.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = if (p.light) .75f else .24f), p.border)), shape)
            .testTag(if (page == ComposerSheet.MODELS) "models-sheet" else "add-sheet")) {
            Box(Modifier.fillMaxWidth().height(24.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.size(34.dp, 4.dp).clip(CircleShape).background(p.secondary.copy(alpha = .36f)))
            }
            Box(Modifier.fillMaxWidth().heightIn(min = 50.dp).padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
                Text(if (page == ComposerSheet.MODELS) { if (ar) "النموذج" else "Model" } else { if (ar) "إضافة" else "Add to chat" },
                    style = MaterialTheme.typography.titleMedium.copy(fontSize = 20.sp),
                    modifier = Modifier.padding(horizontal = 62.dp))
                TextButton(onClick = { closeThen() }, modifier = Modifier.align(Alignment.CenterEnd).heightIn(min = 48.dp).testTag("close-composer-sheet")) {
                    Text(if (ar) "تم" else "Done", color = p.accent, style = MaterialTheme.typography.labelLarge)
                }
            }
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp).padding(top = 10.dp, bottom = 24.dp).navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(18.dp)) {
                if (page == ComposerSheet.MODELS) {
                    ComposerGroup {
                        FirasModelTier.entries.forEachIndexed { index, option ->
                            if (index > 0) ComposerDivider()
                            ModelChoice(option, tier == option) {
                                haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                closeThen { onModel(option) }
                            }
                        }
                    }
                    if (tier.supportsThinking) ComposerGroup { ThinkingChoice(thinking, onThinking) }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        GroupLabel(if (ar) "إرفاق" else "ATTACH")
                        ComposerGroup {
                            if (onCamera != null) {
                                ComposerAction(Icons.Outlined.PhotoCamera, if (ar) "الكاميرا" else "Camera",
                                    if (ar) "التقط صورة وأرفقها" else "Take a photo", "attach-camera") { closeThen(onCamera) }
                                ComposerDivider()
                            }
                            ComposerAction(Icons.Outlined.PhotoLibrary, if (ar) "الصور" else "Photos",
                                if (ar) "اختر من مكتبة الصور" else "Choose from your library", "attach-photos") { closeThen(onPhotos) }
                            ComposerDivider()
                            ComposerAction(Icons.Outlined.FolderOpen, if (ar) "الملفات" else "Files",
                                if (ar) "أرفق مستنداً من جهازك" else "Attach a document", "attach-files") { closeThen(onFiles) }
                        }
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        GroupLabel(if (ar) "الأدوات" else "TOOLS")
                        ComposerGroup {
                            if (tier.supportsThinking) { ThinkingChoice(thinking, onThinking); ComposerDivider() }
                            ComposerAction(Icons.Outlined.Tune, if (ar) "اختيار النموذج" else "Choose model",
                                tier.label, "add-choose-model", onModels)
                            ComposerDivider()
                            ComposerAction(Icons.Outlined.GraphicEq, if (ar) "محادثة صوتية" else "Voice conversation",
                                if (ar) "تحدّث مع فراس" else "Talk with Firas", "add-voice") { closeThen(onVoice) }
                        }
                    }
                }
            }
        }
    }
}

@Composable private fun ComposerGroup(content: @Composable ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp))
        .background(p.ground.copy(alpha = if (p.light) .8f else .68f))
        .border(.5.dp, p.border.copy(alpha = .65f), RoundedCornerShape(22.dp)), content = content)
}

@Composable private fun ComposerDivider() {
    HorizontalDivider(Modifier.padding(start = 62.dp, end = 16.dp), thickness = .5.dp, color = LocalPalette.current.border)
}

@Composable private fun GroupLabel(label: String) {
    Text(label, Modifier.padding(horizontal = 14.dp), color = LocalPalette.current.secondary,
        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold))
}

@Composable private fun ModelChoice(tier: FirasModelTier, selected: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    val ar = LocalArabic.current
    val subtitle = when (tier) {
        FirasModelTier.LUMA -> if (ar) "سريع للأسئلة اليومية" else "Quick answers for every day"
        FirasModelTier.NOVA -> if (ar) "متوازن وذكي" else "A balanced everyday choice"
        FirasModelTier.TITAN -> if (ar) "للبرمجة والمهام المعقّدة" else "For coding and complex tasks"
        FirasModelTier.ATLAS -> if (ar) "للتحليل والتفكير المتعمّق" else "For in-depth analysis and reasoning"
        FirasModelTier.OMNIX -> if (ar) "ينفّذ المهام بأدواته ويتابعها" else "Works through tasks with its tools"
    }
    Row(Modifier.fillMaxWidth().selectable(selected, role = Role.RadioButton, onClick = onClick)
        .background(if (selected) p.accent.copy(alpha = .09f) else Color.Transparent)
        .heightIn(min = 76.dp).padding(horizontal = 16.dp, vertical = 13.dp).testTag("model-${tier.wire}"),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        ModelSymbol(tier, Modifier.size(28.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(tier.label, style = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.SansSerif,
                fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold), color = p.ink)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = p.secondary)
        }
        Icon(if (selected) Icons.Filled.CheckCircle else Icons.Outlined.RadioButtonUnchecked, null,
            Modifier.size(22.dp), tint = if (selected) p.accent else p.secondary.copy(alpha = .38f))
    }
}

@Composable internal fun ModelSymbol(tier: FirasModelTier, modifier: Modifier = Modifier) {
    val ink = LocalPalette.current.accent
    when (tier) {
        FirasModelTier.LUMA -> Icon(Icons.Filled.Bolt, null, modifier, tint = ink)
        FirasModelTier.TITAN -> Icon(Icons.Filled.Star, null, modifier, tint = ink)
        FirasModelTier.OMNIX -> Icon(Icons.Filled.AutoAwesome, null, modifier, tint = ink)
        else -> Canvas(modifier) {
            val sx = size.width / 24f; val sy = size.height / 24f
            val points = if (tier == FirasModelTier.NOVA) listOf(2f to 14f, 7f to 6f, 14f to 10f, 22f to 5f,
                22f to 13f, 16f to 19f, 9f to 14f, 2f to 18f)
            else listOf(3f to 7f, 8f to 12f, 12f to 3f, 16f to 12f, 21f to 7f, 19f to 20f, 5f to 20f)
            drawPath(Path().apply { points.forEachIndexed { i, pt -> if (i == 0) moveTo(pt.first*sx, pt.second*sy) else lineTo(pt.first*sx, pt.second*sy) }; close() }, ink)
        }
    }
}

@Composable private fun ThinkingChoice(checked: Boolean, onChange: (Boolean) -> Unit) {
    val p = LocalPalette.current
    val ar = LocalArabic.current
    val haptics = LocalHapticFeedback.current
    Row(Modifier.fillMaxWidth().toggleable(checked, role = Role.Switch) {
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove); onChange(it)
    }.heightIn(min = 78.dp).padding(horizontal = 16.dp, vertical = 12.dp).testTag("thinking-toggle"),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(Icons.Outlined.AutoAwesome, null, Modifier.size(28.dp), tint = p.accent)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(if (ar) "تفكير أعمق" else "Deeper thinking", style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold), color = p.ink)
            Text(if (ar) "وقت إضافي للمسائل المعقّدة" else "More time for complex questions", style = MaterialTheme.typography.bodySmall, color = p.secondary)
        }
        Switch(checked = checked, onCheckedChange = null, colors = SwitchDefaults.colors(
            checkedThumbColor = if (p.light) Color.White else p.ink, checkedTrackColor = p.accent,
            uncheckedThumbColor = p.ink, uncheckedTrackColor = p.secondary.copy(alpha = .22f), uncheckedBorderColor = Color.Transparent))
    }
}

@Composable private fun ComposerAction(icon: ImageVector, title: String, subtitle: String, tag: String, onClick: () -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).heightIn(min = 74.dp)
        .padding(horizontal = 16.dp, vertical = 12.dp).testTag(tag), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(icon, null, Modifier.size(28.dp), tint = p.accent)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold), color = p.ink)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = p.secondary)
        }
        Icon(Icons.Outlined.ChevronRight, null, Modifier.size(19.dp), tint = p.secondary.copy(alpha = .55f))
    }
}
