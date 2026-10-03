package com.bluebubbles.messaging

import android.content.Intent
import com.bluebubbles.messaging.services.filesystem.StickerFolderAccess
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class BubbleActivity : FlutterFragmentActivity() {
    private var stickerFolderAccess: StickerFolderAccess? = null
    private var stickerFolderChannel: MethodChannel? = null
    companion object {
        private val engineLock = Any()
        @Volatile private var _engine: FlutterEngine? = null
        
        fun getEngine(): FlutterEngine? {
            synchronized(engineLock) {
                return _engine
            }
        }
        
        fun setEngine(newEngine: FlutterEngine?) {
            synchronized(engineLock) {
                _engine = newEngine
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        setEngine(flutterEngine)
        super.configureFlutterEngine(flutterEngine)
        stickerFolderAccess?.close()
        stickerFolderAccess = StickerFolderAccess(this)
        stickerFolderChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, StickerFolderAccess.CHANNEL)
        stickerFolderChannel?.setMethodCallHandler { call, result ->
            val access = stickerFolderAccess
            if (access == null) result.error("closed", "Sticker folder browser closed.", null)
            else access.handle(call, result)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Constants.methodChannel).setMethodCallHandler {
                call, result -> MethodCallHandler().methodCallHandler(call, result, this)
        }
    }

    override fun getDartEntrypointFunctionName(): String {
        return "bubble"
    }

    override fun onDestroy() {
        stickerFolderAccess?.close()
        stickerFolderChannel?.setMethodCallHandler(null)
        stickerFolderChannel = null
        stickerFolderAccess = null
        setEngine(null)
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == StickerFolderAccess.REQUEST_CODE) stickerFolderAccess?.onActivityResult(resultCode, data)
    }
}
