package dev.androidsync

import android.content.pm.ActivityInfo
import android.hardware.Camera
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CameraFront
import androidx.compose.material.icons.outlined.Cameraswitch
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.FlashOff
import androidx.compose.material.icons.outlined.FlashOn
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.journeyapps.barcodescanner.CaptureManager
import com.journeyapps.barcodescanner.DecoratedBarcodeView
import com.journeyapps.barcodescanner.ScanOptions
import com.journeyapps.barcodescanner.Size
import com.journeyapps.barcodescanner.camera.CameraSettings

fun androidSyncScanOptions() = ScanOptions()
    .setCaptureActivity(QrScannerActivity::class.java)
    .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
    .setPrompt("")
    .setBeepEnabled(false)
    .setOrientationLocked(true)

class QrScannerActivity : ComponentActivity() {
    private lateinit var scanner: DecoratedBarcodeView
    private lateinit var capture: CaptureManager
    private var torchOn by mutableStateOf(false)
    private var usingFrontCamera by mutableStateOf(false)
    private var backCameraId = 0
    private var frontCameraId: Int? = null

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        discoverCameras()
        scanner = DecoratedBarcodeView(this).apply {
            viewFinder.setLaserVisibility(false)
            viewFinder.setMaskColor(android.graphics.Color.argb(150,0,0,0))
            statusView.visibility = View.GONE
        }
        capture = CaptureManager(this,scanner).apply {
            initializeFromIntent(intent,savedInstanceState)
            setShowMissingCameraPermissionDialog(true,"Camera access is required to scan a Mac pairing invitation.")
            decode()
        }
        setContent {
            val state by engine().state.collectAsState()
            AndroidSyncTheme {
                CompositionLocalProvider(LocalStreamMode provides state.streamModeEnabled) {
                QrScannerScreen(
                    scanner = scanner,
                    torchOn = torchOn,
                    canSwitchCamera = frontCameraId != null && frontCameraId != backCameraId,
                    usingFrontCamera = usingFrontCamera,
                    close = { finish() },
                    toggleTorch = ::toggleTorch,
                    switchCamera = ::switchCamera
                )
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun discoverCameras() {
        var first = 0
        var foundBack: Int? = null
        var foundFront: Int? = null
        runCatching {
            for (id in 0 until Camera.getNumberOfCameras()) {
                if (id == 0) first = id
                val info = Camera.CameraInfo()
                Camera.getCameraInfo(id,info)
                if (info.facing == Camera.CameraInfo.CAMERA_FACING_BACK && foundBack == null) foundBack = id
                if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT && foundFront == null) foundFront = id
            }
        }
        backCameraId = foundBack ?: first
        frontCameraId = foundFront
    }

    private fun toggleTorch() {
        if (usingFrontCamera) return
        torchOn = !torchOn
        runCatching { if (torchOn) scanner.setTorchOn() else scanner.setTorchOff() }
            .onFailure { torchOn = false }
    }

    private fun switchCamera() {
        val nextId = if (usingFrontCamera) backCameraId else frontCameraId ?: return
        torchOn = false
        runCatching { scanner.setTorchOff() }
        scanner.pauseAndWait()
        scanner.cameraSettings = CameraSettings().apply { requestedCameraId = nextId }
        usingFrontCamera = nextId == frontCameraId
        scanner.resume()
        capture.decode()
    }

    override fun onResume() { super.onResume(); capture.onResume() }
    override fun onPause() { capture.onPause(); super.onPause() }
    override fun onDestroy() { capture.onDestroy(); super.onDestroy() }
    override fun onSaveInstanceState(outState: Bundle) { super.onSaveInstanceState(outState); capture.onSaveInstanceState(outState) }
    override fun onRequestPermissionsResult(requestCode: Int,permissions: Array<String>,grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        capture.onRequestPermissionsResult(requestCode,permissions,grantResults)
    }
    override fun onKeyDown(keyCode: Int,event: KeyEvent): Boolean = if (scanner.onKeyDown(keyCode,event)) true else super.onKeyDown(keyCode,event)
}

@Composable
private fun QrScannerScreen(
    scanner: DecoratedBarcodeView,
    torchOn: Boolean,
    canSwitchCamera: Boolean,
    usingFrontCamera: Boolean,
    close: () -> Unit,
    toggleTorch: () -> Unit,
    switchCamera: () -> Unit
) {
    val density = LocalDensity.current
    LaunchedEffect(scanner,density) {
        val frame = with(density) { 272.dp.roundToPx() }
        scanner.barcodeView.framingRectSize = Size(frame,frame)
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        StreamSensitive(Modifier.fillMaxSize(), strongBlur = true) {
            AndroidView(factory = { scanner },modifier = Modifier.fillMaxSize())
        }
        Surface(
            modifier = Modifier.fillMaxWidth().align(Alignment.TopCenter),
            color = Color(0xE6001729)
        ) {
            Row(Modifier.fillMaxWidth().statusBarsPadding().height(64.dp).padding(horizontal = 8.dp),verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = close) { Icon(Icons.Outlined.Close,"Close scanner",tint = Color.White) }
                Icon(Icons.Outlined.QrCodeScanner,null,tint = Color(0xFF1FB6A6),modifier = Modifier.padding(start = 6.dp).size(25.dp))
                Text("Scan pairing QR code",modifier = Modifier.padding(start = 10.dp),color = Color.White,style = MaterialTheme.typography.titleMedium,fontWeight = FontWeight.Bold)
            }
        }
        Column(Modifier.align(Alignment.Center).padding(horizontal = 24.dp),horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                Modifier.size(272.dp)
                    .border(3.dp,Color(0xFF3B82F6),RoundedCornerShape(22.dp))
            )
            Text(
                "Place the QR code inside the frame",
                modifier = Modifier.padding(top = 18.dp).background(Color(0xD9001729),RoundedCornerShape(12.dp)).padding(horizontal = 14.dp,vertical = 9.dp),
                color = Color.White,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                textAlign = TextAlign.Center
            )
        }
        Surface(
            modifier = Modifier.fillMaxWidth().align(Alignment.BottomCenter),
            color = Color(0xE6001729)
        ) {
            Row(
                Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp,vertical = 18.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp,Alignment.CenterHorizontally)
            ) {
                ScannerControl(
                    label = if (torchOn) "Flash on" else "Flash",
                    icon = if (torchOn) Icons.Outlined.FlashOn else Icons.Outlined.FlashOff,
                    selected = torchOn,
                    enabled = !usingFrontCamera,
                    action = toggleTorch
                )
                ScannerControl(
                    label = if (usingFrontCamera) "Front camera" else "Switch camera",
                    icon = if (usingFrontCamera) Icons.Outlined.CameraFront else Icons.Outlined.Cameraswitch,
                    selected = usingFrontCamera,
                    enabled = canSwitchCamera,
                    action = switchCamera
                )
            }
        }
    }
}

@Composable
private fun RowScope.ScannerControl(label: String,icon: androidx.compose.ui.graphics.vector.ImageVector,selected: Boolean,enabled: Boolean,action: () -> Unit) {
    OutlinedButton(
        onClick = action,
        enabled = enabled,
        modifier = Modifier.weight(1f).height(52.dp),
        shape = RoundedCornerShape(13.dp),
        border = BorderStroke(1.dp,if (selected) Color(0xFF1FB6A6) else Color(0xFF3B82F6)),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.White,containerColor = if (selected) Color(0xB31FB6A6) else Color(0xB30C273B),disabledContentColor = Color.White.copy(alpha = .4f),disabledContainerColor = Color(0x800C273B))
    ) {
        Icon(icon,null,modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(7.dp))
        Text(label,maxLines = 1)
    }
}
