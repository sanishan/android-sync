package dev.androidsync

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.RowScope
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

val SyncPagePadding = 12.dp
val SyncItemSpacing = 10.dp
val SyncCardShape = RoundedCornerShape(14.dp)
val LocalStreamMode = compositionLocalOf { false }

@Composable
fun StreamSensitive(modifier: Modifier = Modifier, strongBlur: Boolean = false, content: @Composable () -> Unit) {
    val enabled = LocalStreamMode.current
    val hoverSource = remember { MutableInteractionSource() }
    val tapSource = remember { MutableInteractionSource() }
    val hovered by hoverSource.collectIsHoveredAsState()
    var revealed by remember { mutableStateOf(false) }
    LaunchedEffect(enabled) { if (!enabled) revealed = false }
    val hidden = enabled && !hovered && !revealed
    Box(
        modifier
            .hoverable(hoverSource, enabled = enabled)
            .clickable(tapSource, indication = null, enabled = enabled) { revealed = !revealed }
    ) {
        Box(Modifier.blur(if (hidden) (if (strongBlur) 18.dp else 8.dp) else 0.dp)) { content() }
    }
}

@Composable
fun SyncCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Card(
        modifier = modifier,
        shape = SyncCardShape,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        content = content
    )
}

@Composable
fun SyncOutlinedButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    colors: ButtonColors = ButtonDefaults.outlinedButtonColors(),
    content: @Composable RowScope.() -> Unit
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        colors = colors,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary),
        content = content
    )
}
