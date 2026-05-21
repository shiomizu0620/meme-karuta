package com.example.memekaruta

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Menu
import android.view.MenuItem
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject

class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var wsClient: GameWebSocketClient
    private val mainHandler = Handler(Looper.getMainLooper())
    private var gameState = GameState()

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        webView = findViewById(R.id.webView)
        setupWebView()
        setupWebSocket()
        loadApp()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            cacheMode = WebSettings.LOAD_DEFAULT
            mediaPlaybackRequiresUserGesture = false
            allowContentAccess = true
            allowFileAccess = true
            setSupportZoom(false)
            builtInZoomControls = false
        }

        webView.webChromeClient = WebChromeClient()

        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                super.onReceivedError(view, request, error)
                val code = error.errorCode
                val desc = error.description
                mainHandler.post {
                    showErrorDialog("ページの読み込みに失敗しました\n(${code}: ${desc})")
                }
            }

            override fun onPageFinished(view: WebView, url: String) {
                super.onPageFinished(view, url)
                injectNativeBridge()
            }
        }

        webView.addJavascriptInterface(NativeBridge(), "AndroidBridge")
    }

    private fun setupWebSocket() {
        val realtimeUrl = getRealtimeUrl()
        wsClient = GameWebSocketClient(realtimeUrl, object : GameWebSocketClient.Listener {
            override fun onOpen() {
                mainHandler.post { notifyWebView("wsOpen", "{}") }
            }

            override fun onMessage(json: String) {
                mainHandler.post {
                    notifyWebView("wsMessage", json)
                    handleServerMessage(json)
                }
            }

            override fun onClose(code: Int, reason: String) {
                mainHandler.post {
                    val payload = JSONObject().apply {
                        put("code", code)
                        put("reason", reason)
                    }.toString()
                    notifyWebView("wsClose", payload)
                }
            }

            override fun onError(message: String) {
                mainHandler.post {
                    val payload = JSONObject().apply { put("message", message) }.toString()
                    notifyWebView("wsError", payload)
                }
            }
        })
    }

    private fun loadApp() {
        val frontendUrl = getFrontendUrl()
        webView.loadUrl(frontendUrl)
    }

    private fun injectNativeBridge() {
        val script = """
            (function() {
              if (window.__nativeBridgeInjected) return;
              window.__nativeBridgeInjected = true;
              window.nativeWsSend = function(json) {
                AndroidBridge.sendWebSocketMessage(json);
              };
              window.nativeWsConnect = function() {
                AndroidBridge.connectWebSocket();
              };
              window.nativeWsDisconnect = function() {
                AndroidBridge.disconnectWebSocket();
              };
              window.dispatchEvent(new CustomEvent('nativeBridgeReady'));
            })();
        """.trimIndent()
        webView.evaluateJavascript(script, null)
    }

    private fun notifyWebView(event: String, jsonPayload: String) {
        val escaped = jsonPayload.replace("\\", "\\\\").replace("'", "\\'")
        val script = "window.dispatchEvent(new CustomEvent('$event', { detail: JSON.parse('$escaped') }));"
        webView.evaluateJavascript(script, null)
    }

    private fun handleServerMessage(json: String) {
        runCatching {
            val obj = JSONObject(json)
            when (obj.getString("type")) {
                "game_started" -> {
                    gameState.status = GameState.Status.PLAYING
                    gameState.players = parseStringArray(obj.getJSONArray("players"))
                }
                "game_over" -> {
                    gameState.status = GameState.Status.FINISHED
                    val scoresObj = obj.getJSONObject("scores")
                    gameState.scores = scoresObj.keys().asSequence()
                        .associateWith { scoresObj.getInt(it) }
                }
                "room_created", "room_joined" -> {
                    gameState.roomId = obj.optString("room_id")
                    gameState.status = GameState.Status.WAITING
                }
                "card_taken" -> {
                    val cardId = obj.getInt("card_id")
                    gameState.takenCardIds.add(cardId)
                }
            }
        }
    }

    private fun parseStringArray(arr: org.json.JSONArray): List<String> =
        (0 until arr.length()).map { arr.getString(it) }

    private fun showErrorDialog(message: String) {
        AlertDialog.Builder(this)
            .setTitle("接続エラー")
            .setMessage(message)
            .setPositiveButton("再読み込み") { _, _ -> loadApp() }
            .setNegativeButton("キャンセル", null)
            .show()
    }

    private fun getFrontendUrl(): String =
        getSharedPreferences("karuta_prefs", Context.MODE_PRIVATE)
            .getString("frontend_url", DEFAULT_FRONTEND_URL) ?: DEFAULT_FRONTEND_URL

    private fun getRealtimeUrl(): String =
        getSharedPreferences("karuta_prefs", Context.MODE_PRIVATE)
            .getString("realtime_url", DEFAULT_REALTIME_URL) ?: DEFAULT_REALTIME_URL

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.main_menu, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        return when (item.itemId) {
            R.id.action_reload -> { webView.reload(); true }
            R.id.action_settings -> {
                startActivity(Intent(this, SettingsActivity::class.java))
                true
            }
            R.id.action_debug -> {
                Toast.makeText(this, "State: ${gameState.status} | Room: ${gameState.roomId}", Toast.LENGTH_LONG).show()
                true
            }
            else -> super.onOptionsItemSelected(item)
        }
    }

    override fun onBackPressed() {
        if (webView.canGoBack()) {
            webView.goBack()
        } else {
            super.onBackPressed()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        wsClient.disconnect()
        webView.destroy()
    }

    inner class NativeBridge {
        @JavascriptInterface
        fun connectWebSocket() {
            wsClient.connect()
        }

        @JavascriptInterface
        fun disconnectWebSocket() {
            wsClient.disconnect()
        }

        @JavascriptInterface
        fun sendWebSocketMessage(json: String) {
            if (!wsClient.send(json)) {
                mainHandler.post {
                    Toast.makeText(applicationContext, "メッセージの送信に失敗しました", Toast.LENGTH_SHORT).show()
                }
            }
        }

        @JavascriptInterface
        fun getGameStateJson(): String = gameState.toJson()

        @JavascriptInterface
        fun vibrate(durationMs: Int) {
            runCatching {
                val vibrator = getSystemService(VIBRATOR_SERVICE) as android.os.Vibrator
                @Suppress("DEPRECATION")
                vibrator.vibrate(durationMs.toLong().coerceIn(10, 500))
            }
        }

        @JavascriptInterface
        fun showToast(message: String) {
            mainHandler.post {
                Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
            }
        }
    }

    companion object {
        private const val DEFAULT_FRONTEND_URL = "http://10.0.2.2:5173"
        private const val DEFAULT_REALTIME_URL  = "ws://10.0.2.2:4000/ws"
    }
}

class SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val prefs = getSharedPreferences("karuta_prefs", Context.MODE_PRIVATE)

        val frontendUrl = prefs.getString("frontend_url", "http://10.0.2.2:5173") ?: ""
        val realtimeUrl = prefs.getString("realtime_url", "ws://10.0.2.2:4000/ws") ?: ""

        val layout = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(48, 48, 48, 48)
        }

        val frontendLabel = android.widget.TextView(this).apply { text = "フロントエンドURL" }
        val frontendInput = android.widget.EditText(this).apply { setText(frontendUrl) }

        val realtimeLabel = android.widget.TextView(this).apply { text = "リアルタイムサーバーURL (ws://)" }
        val realtimeInput = android.widget.EditText(this).apply { setText(realtimeUrl) }

        val saveButton = android.widget.Button(this).apply {
            text = "保存"
            setOnClickListener {
                prefs.edit().apply {
                    putString("frontend_url", frontendInput.text.toString().trim())
                    putString("realtime_url", realtimeInput.text.toString().trim())
                    apply()
                }
                Toast.makeText(applicationContext, "保存しました", Toast.LENGTH_SHORT).show()
                finish()
            }
        }

        layout.addView(frontendLabel)
        layout.addView(frontendInput)
        layout.addView(realtimeLabel)
        layout.addView(realtimeInput)
        layout.addView(saveButton)
        setContentView(layout)
        title = "接続設定"
    }
}
