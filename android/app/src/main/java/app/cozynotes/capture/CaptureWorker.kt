package app.cozynotes.capture

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

/** Retains exactly one application-context I/O job across Activity recreation. */
class CaptureWorker(application: Application) : AndroidViewModel(application) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    internal var busy = false
        private set
    internal var result: CaptureResult? = null
        private set
    internal var failure: String? = null
        private set
    internal var listener: (() -> Unit)? = null


    internal fun start(request: CaptureRequest) {
        if (busy || result != null) return
        val app = getApplication<Application>()
        busy = true
        failure = null
        listener?.invoke()
        executor.execute {
            val outcome = runCatching { VaultWriter(app).capture(request) }
            main.post {
                busy = false
                result = outcome.getOrNull()
                failure = outcome.exceptionOrNull()?.let {
                    if (it is SecurityException) "Folder or attachment access was revoked. Choose the vault again; if needed, share the attachment again."
                    else it.message ?: "Capture failed. Your input has been kept; please try again."
                }
                listener?.invoke()
            }
        }
    }

    internal fun reset() {
        if (busy) return
        result = null
        failure = null
        listener?.invoke()
    }


    override fun onCleared() {
        // shutdown lets an already accepted capture finish, even when the Activity closes.
        listener = null
        executor.shutdown()
        super.onCleared()
    }
}
