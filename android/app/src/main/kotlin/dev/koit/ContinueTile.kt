package dev.koit.abs_wear

import android.content.Context
import android.content.Intent
import androidx.wear.tiles.TileService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.io.File

/** The "Continue listening" tile's link to Dart: the book a tap asked for, and tile refreshes. */
object ContinueTile {
    const val EXTRA_ITEM = "dev.koit.abs_wear.tile_item"
    const val EXTRA_EPISODE = "dev.koit.abs_wear.tile_episode"

    private var channel: MethodChannel? = null
    private var pending: Map<String, String?>? = null

    fun register(flutterEngine: FlutterEngine, context: Context) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "continue_tile").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> {
                        result.success(pending)
                        pending = null
                    }
                    "refresh" -> {
                        requestUpdate(context)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** Keeps a tile tap's book for Dart and tells a running app; [fresh] is false for a restored activity. */
    fun onLaunch(intent: Intent?, fresh: Boolean) {
        val id = intent?.getStringExtra(EXTRA_ITEM) ?: return
        val episode = intent.getStringExtra(EXTRA_EPISODE)
        intent.removeExtra(EXTRA_ITEM)
        intent.removeExtra(EXTRA_EPISODE)
        if (!fresh || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        pending = mapOf("id" to id, "episodeId" to episode)
        channel?.invokeMethod("open", null)
    }

    fun requestUpdate(context: Context) {
        TileService.getUpdater(context).requestUpdate(ContinueTileService::class.java)
    }

    data class Book(val id: String, val episodeId: String?, val title: String, val author: String)

    /** First book of the cached Continue Listening shelf (JsonCache in Dart), or null when logged out or empty. */
    fun cachedBook(context: Context): Book? = try {
        readCachedBook(context)
    } catch (e: Exception) {
        null
    }

    private fun readCachedBook(context: Context): Book? {
        // Legacy shared_preferences: this file, keys prefixed "flutter.".
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (prefs.getString("flutter.token", null).isNullOrEmpty()) return null
        // The signed-in user's JsonCache key, set by LibraryPage and removed on logout and login.
        val key = prefs.getString("flutter.tileShelf", null)
        if (key.isNullOrEmpty()) return null
        // File name as in JsonCache._fileName.
        val file = File(File(context.filesDir, "json_cache"), key.replace(Regex("[^A-Za-z0-9_-]"), "_") + ".json")
        if (!file.isFile) return null
        val books = JSONArray(file.readText())
        for (i in 0 until books.length()) {
            val book = books.optJSONObject(i) ?: continue
            val id = book.optString("i")
            if (id.isEmpty()) continue
            return Book(
                id = id,
                episodeId = book.optString("e").ifEmpty { null },
                title = book.optString("t"),
                author = book.optString("a"),
            )
        }
        return null
    }
}
