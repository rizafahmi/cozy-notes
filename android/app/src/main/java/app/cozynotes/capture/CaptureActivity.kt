package app.cozynotes.capture

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.ViewModelProvider
import androidx.core.content.IntentCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

class CaptureActivity : ComponentActivity() {
    private lateinit var worker: CaptureWorker
    private lateinit var text: EditText
    private lateinit var note: EditText
    private lateinit var folder: TextView
    private lateinit var attachmentsLabel: TextView
    private lateinit var status: TextView
    private lateinit var save: Button
    private lateinit var choose: Button
    private lateinit var fresh: Button
    private val attachments = mutableListOf<Uri>()
    private val preferences by lazy { getSharedPreferences("capture", MODE_PRIVATE) }
    private val brown = Color.rgb(76, 56, 43)
    private var root: Uri? = null
    private val folderPicker = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        handleFolderResult(result.resultCode, result.data)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        worker = ViewModelProvider(this)[CaptureWorker::class.java]
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (worker.busy) status.text = "Saving capture… Please wait before leaving."
                else {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                }
            }
        })
        root = preferences.getString("vault", null)?.let(Uri::parse)
        buildView()
        if (savedInstanceState != null) {
            text.setText(savedInstanceState.getString("text", ""))
            note.setText(savedInstanceState.getString("note", ""))
            savedInstanceState.getStringArrayList("attachments")?.mapTo(attachments, Uri::parse)
            if (savedInstanceState.getBoolean("saved", false) && worker.result == null) {
                status.text = "Your previous capture was saved. Start a new capture below."
                save.visibility = View.GONE
                fresh.visibility = View.VISIBLE
            } else if (savedInstanceState.getBoolean("saving", false) && !worker.busy && worker.result == null) {
                status.text = "Android interrupted the previous save. Check Inbox for the capture before retrying. Any .pending file is incomplete."
            }
        } else {
            receiveShare(intent)
        }
        render()
    }

    override fun onStart() {
        super.onStart()
        worker.listener = { render() }
        render()
    }

    override fun onStop() {
        worker.listener = null
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("text", text.text.toString())
        outState.putString("note", note.text.toString())
        outState.putStringArrayList("attachments", ArrayList(attachments.map(Uri::toString)))
        outState.putBoolean("saving", worker.busy)
        outState.putBoolean("saved", worker.result != null || save.visibility == View.GONE)
        super.onSaveInstanceState(outState)
    }

    private fun buildView() {
        val scroll = ScrollView(this).apply { isFillViewport = true; setBackgroundColor(Color.rgb(247, 241, 232)) }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(28), dp(24), dp(28))
        }
        scroll.addView(layout)
        // Target 35 draws edge-to-edge; keep controls clear of system bars and the keyboard.
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        fun label(value: String, size: Float = 16f): TextView = TextView(this).apply {
            this.text = value
            textSize = size
            setTextColor(brown)
            setPadding(0, dp(8), 0, dp(8))
            layout.addView(this)
        }
        label("Cozy Notes", 32f).setTypeface(Typeface.create("serif", Typeface.NORMAL))
        label("A quiet place to keep a thought.")
        folder = label("")
        choose = Button(this).apply {
            this.text = "Choose vault folder"
            setOnClickListener { chooseFolder() }
            layout.addView(this)
        }
        label("Text or link")
        text = EditText(this).apply {
            id = 1001
            hint = "What's worth keeping?"
            minLines = 5
            gravity = android.view.Gravity.TOP or android.view.Gravity.START
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            setTextColor(brown)
            background = fieldBackground()
            setPadding(dp(14), dp(12), dp(14), dp(12))
            layout.addView(this, LinearLayout.LayoutParams(-1, -2))
        }
        label("Optional note")
        note = EditText(this).apply {
            id = 1002
            hint = "Add a little context…"
            minLines = 2
            gravity = android.view.Gravity.TOP or android.view.Gravity.START
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            setTextColor(brown)
            background = fieldBackground()
            setPadding(dp(14), dp(12), dp(14), dp(12))
            layout.addView(this, LinearLayout.LayoutParams(-1, -2))
        }
        attachmentsLabel = label("")
        save = Button(this).apply {
            this.text = "Save to Inbox"
            setOnClickListener { saveCapture() }
            layout.addView(this)
        }
        status = label("")
        status.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        fresh = Button(this).apply {
            this.text = "New capture"
            visibility = View.GONE
            setOnClickListener {
                this@CaptureActivity.text.setText("")
                note.setText("")
                attachments.clear()
                status.text = ""
                save.visibility = View.VISIBLE
                worker.reset()
                render()
                this@CaptureActivity.text.requestFocus()
            }
            layout.addView(this)
        }
        label("Files stay in your chosen folder. Sync that folder with Syncthing separately. Cozy Notes needs no account or network access.", 13f)
        setContentView(scroll)
    }

    private fun receiveShare(source: Intent) {
        if (source.action != Intent.ACTION_SEND && source.action != Intent.ACTION_SEND_MULTIPLE) return
        val sharedText = source.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty()
        val subject = source.getStringExtra(Intent.EXTRA_SUBJECT).orEmpty()
        val sharedTexts = mutableListOf<String>()
        if (sharedText.isNotBlank()) sharedTexts.add(sharedText)
        val incoming = mutableListOf<Uri>()
        if (source.action == Intent.ACTION_SEND_MULTIPLE) {
            IntentCompat.getParcelableArrayListExtra(source, Intent.EXTRA_STREAM, Uri::class.java)?.let(incoming::addAll)
        } else {
            IntentCompat.getParcelableExtra(source, Intent.EXTRA_STREAM, Uri::class.java)?.let(incoming::add)
        }
        // Some senders expose URI grants only in ClipData, not EXTRA_STREAM.
        source.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                val item = clip.getItemAt(index)
                item.uri?.let { uri ->
                    if (uri.scheme == "http" || uri.scheme == "https") sharedTexts.add(uri.toString())
                    else incoming.add(uri)
                }
                item.text?.toString()?.takeIf(String::isNotBlank)?.let(sharedTexts::add)
            }
        }
        text.setText(sharedTexts.distinct().joinToString("\n\n").ifBlank { subject })
        attachments.addAll(incoming.filter { it.scheme == "content" }.distinct())
        if (incoming.any { it.scheme != "content" }) status.text = "A shared attachment used an unsupported URI. Share it from a file provider instead."
    }

    private fun chooseFolder() {
        val picker = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            root?.let { putExtra(DocumentsContract.EXTRA_INITIAL_URI, it) }
        }
        try {
            folderPicker.launch(picker)
        } catch (_: android.content.ActivityNotFoundException) {
            status.text = "This device has no system folder picker. Enable its Files/Documents app and try again."
        }
    }

    private fun handleFolderResult(resultCode: Int, data: Intent?) {
        if (resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        val grants = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        if (grants and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0) {
            status.text = "That folder was not writable. Please select a writable vault folder."
            return
        }
        try {
            contentResolver.takePersistableUriPermission(uri, grants)
            val previous = root
            preferences.edit().putString("vault", uri.toString()).apply()
            root = uri
            if (previous != null && previous != uri) {
                try { contentResolver.releasePersistableUriPermission(previous, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) } catch (_: SecurityException) { }
            }
            status.text = "Vault selected. This preference stays on this device."
            render()
        } catch (_: SecurityException) {
            status.text = "This provider cannot keep writable folder access. Choose a local folder that supports persisted access."
        }
    }

    private fun hasPermission(uri: Uri): Boolean = contentResolver.persistedUriPermissions.any {
        it.uri == uri && it.isReadPermission && it.isWritePermission
    }

    private fun saveCapture() {
        val selected = root
        if (selected == null || !hasPermission(selected)) {
            status.text = "Choose the vault folder again to grant writable access. Your input is kept."
            chooseFolder()
            return
        }
        val combined = listOf(text.text.toString(), note.text.toString()).filter(String::isNotBlank).joinToString("\n\n")
        if (combined.isBlank() && attachments.isEmpty()) {
            status.text = "Add text, a link, or share an attachment first."
            return
        }
        worker.start(CaptureRequest(selected, combined, attachments.toList()))
    }

    private fun render() {
        val selected = root
        folder.text = when {
            selected == null -> "No vault selected yet."
            !hasPermission(selected) -> "Folder access expired. Choose the vault again."
            else -> "Vault: ${Uri.decode(DocumentsContract.getTreeDocumentId(selected))}"
        }
        attachmentsLabel.text = if (attachments.isEmpty()) "Share images or files to Cozy Notes from another app to attach them." else "${attachments.size} attachment${if (attachments.size == 1) "" else "s"} · originals will be preserved"
        val done = worker.result != null || save.visibility == View.GONE
        save.isEnabled = !worker.busy && !done
        choose.isEnabled = !worker.busy
        text.isEnabled = !worker.busy && !done
        note.isEnabled = !worker.busy && !done
        if (worker.busy) status.text = "Saving capture… Keep this app open until the save finishes."
        worker.failure?.let { status.text = "$it\nYour input has been kept. Check folder access, then retry." }
        worker.result?.let {
            status.text = "Saved to ${it.path}"
            save.visibility = View.GONE
        }
        fresh.visibility = if (done) View.VISIBLE else View.GONE
    }


    private fun fieldBackground() = GradientDrawable().apply {
        setColor(Color.rgb(255, 252, 247))
        cornerRadius = dp(12).toFloat()
        setStroke(dp(1), Color.rgb(218, 202, 185))
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
