package dev.koit.abs_wear

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.wear.phone.interactions.authentication.CodeChallenge
import androidx.wear.phone.interactions.authentication.CodeVerifier
import androidx.wear.phone.interactions.authentication.OAuthRequest
import androidx.wear.phone.interactions.authentication.OAuthResponse
import androidx.wear.phone.interactions.authentication.RemoteAuthClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * "Continue on phone" sign-in: opens an OAuth authorization URL on the
 * paired phone through the Wear OS companion ([RemoteAuthClient]) and hands
 * the redirect (with code and state) back to Dart.
 *
 * Channel `remote_auth`:
 * - `redirectUri` -> the redirect URL the companion requires for this app
 *   (https://wear.googleapis.com/3p_auth/<package>, or the -cn host).
 * - `authorize {url}` -> the response URL. `url` is complete: client_id,
 *   redirect_uri, response_type=code and the S256 code challenge are already
 *   in it. Errors: unsupported, phoneUnavailable, badRequest, cancelled
 *   (cancel, or a newer authorize), failed.
 * - `cancel` -> null; ends the pending authorize with `cancelled`.
 *
 * A singleton: audio_service's cached engine outlives the activity, and the
 * user may leave the watch app while signing in on the phone. Everything runs
 * on the main thread (channel handlers and the client's callbacks).
 */
object RemoteAuth {
    private const val TAG = "RemoteAuth"

    private var engine: WeakReference<FlutterEngine>? = null

    /** Bumped whenever an attempt ends, so its late callbacks are ignored. */
    private var attempt = 0
    private var client: RemoteAuthClient? = null
    private var pending: MethodChannel.Result? = null

    fun register(flutterEngine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "remote_auth")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "redirectUri" -> result.success(redirectUri(appContext))
                    "authorize" -> authorize(appContext, call.argument<String>("url"), result)
                    "cancel" -> {
                        end { it.error("cancelled", "Sign-in on the phone was cancelled", null) }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // Once per engine. Its Dart side is gone, so nothing is left to reply to.
        if (engine?.get() !== flutterEngine) {
            engine = WeakReference(flutterEngine)
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() = end(null)

                override fun onEngineWillDestroy() = end(null)
            })
        }
    }

    /**
     * Taken from the library rather than hard-coded, so it follows the
     * China-build host and any future change.
     */
    private fun redirectUri(context: Context): String =
        OAuthRequest.Builder(context)
            .setAuthProviderUrl(Uri.parse("https://example.invalid/auth"))
            .setClientId("x")
            .setCodeChallenge(CodeChallenge(CodeVerifier()))
            .build()
            .redirectUrl

    private fun authorize(context: Context, url: String?, result: MethodChannel.Result) {
        end { it.error("cancelled", "A newer sign-in started", null) }
        val id = attempt
        // With only the provider URL set, build() appends just redirect_uri
        // (rejecting a different one already in the URL) and checks that the
        // URL carries client_id, response_type=code and an S256 challenge.
        val request = try {
            requireNotNull(url) { "No url" }
            OAuthRequest.Builder(context).setAuthProviderUrl(Uri.parse(url)).build()
        } catch (e: IllegalArgumentException) {
            result.error("badRequest", e.message, null)
            return
        } catch (e: UnsupportedOperationException) {
            // Uri.getQueryParameter on an opaque URI (e.g. "mailto:...").
            result.error("badRequest", e.message, null)
            return
        }
        val newClient = RemoteAuthClient.create(context)
        client = newClient
        pending = result
        try {
            newClient.sendAuthorizationRequest(
                request,
                context.mainExecutor,
                object : RemoteAuthClient.Callback() {
                    override fun onAuthorizationResponse(
                        request: OAuthRequest,
                        response: OAuthResponse,
                    ) {
                        if (id != attempt) return
                        val responseUrl = response.responseUrl
                        end {
                            if (responseUrl == null) {
                                it.error("failed", "The phone sent no response URL", null)
                            } else {
                                it.success(responseUrl.toString())
                            }
                        }
                    }

                    override fun onAuthorizationError(request: OAuthRequest, errorCode: Int) {
                        if (id != attempt) return
                        Log.w(TAG, "Sign-in on the phone failed: $errorCode")
                        end {
                            when (errorCode) {
                                RemoteAuthClient.ERROR_UNSUPPORTED ->
                                    it.error("unsupported", "Phone sign-in is not supported", null)
                                RemoteAuthClient.ERROR_PHONE_UNAVAILABLE ->
                                    it.error("phoneUnavailable", "The phone is not connected", null)
                                else -> it.error("failed", "Error code $errorCode", errorCode)
                            }
                        }
                    }
                },
            )
        } catch (e: RuntimeException) {
            // E.g. the companion's auth service could not be bound.
            Log.w(TAG, "Could not send the sign-in request", e)
            if (id == attempt) end { it.error("failed", e.message, null) }
        }
    }

    /**
     * Ends the current attempt, if any: closes its client and replies once
     * through [reply] (null: don't reply).
     */
    private fun end(reply: ((MethodChannel.Result) -> Unit)?) {
        attempt++
        val result = pending
        pending = null
        client?.let {
            client = null
            try {
                it.close()
            } catch (e: RuntimeException) {
                Log.w(TAG, "Could not close the auth client", e)
            }
        }
        if (result != null) reply?.invoke(result)
    }
}
