package dev.koit.abs_wear

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.support.wearable.authentication.IAuthenticationRequestCallback
import android.support.wearable.authentication.IAuthenticationRequestService
import android.util.Log
import androidx.wear.phone.interactions.authentication.CodeChallenge
import androidx.wear.phone.interactions.authentication.CodeVerifier
import androidx.wear.phone.interactions.authentication.OAuthRequest
import androidx.wear.phone.interactions.authentication.RemoteAuthClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * "Continue on phone" sign-in: opens an OAuth authorization URL on the
 * paired phone through the Wear OS companion's auth service and hands the
 * redirect (with code and state) back to Dart.
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
 * The request is built and checked with [OAuthRequest], but sent by binding
 * the companion's service directly instead of through [RemoteAuthClient]:
 * the client calls the service from its own ServiceConnection and rethrows
 * anything that fails there on the main looper, which would crash the app.
 * The binding, bundle keys and result parsing mirror RemoteAuthClient 1.1.1.
 *
 * A singleton: audio_service's cached engine outlives the activity, and the
 * user may leave the watch app while signing in on the phone. Everything runs
 * on the main thread (channel handlers, ServiceConnection callbacks, and the
 * companion's result, which is posted there from a binder thread).
 */
// The AIDL interfaces are library-restricted; RemoteAuthClient talks to the
// companion through the same ones.
@SuppressLint("RestrictedApi")
object RemoteAuth {
    private const val TAG = "RemoteAuth"

    // From RemoteAuthClient 1.1.1 (ACTION_AUTH, WEARABLE_PACKAGE_NAME,
    // KEY_*, NO_ERROR); its constants for these are not public API.
    private const val ACTION_AUTH = "android.support.wearable.authentication.action.OAUTH"
    private const val COMPANION_PACKAGE = "com.google.android.wearable.app"
    private const val KEY_REQUEST_URL = "requestUrl"
    private const val KEY_PACKAGE_NAME = "packageName"
    private const val KEY_RESPONSE_URL = "responseUrl"
    private const val KEY_ERROR_CODE = "errorCode"
    private const val NO_ERROR = -1

    private val mainHandler = Handler(Looper.getMainLooper())

    private var engine: WeakReference<FlutterEngine>? = null

    /** Bumped whenever an attempt ends, so its late callbacks are ignored. */
    private var attempt = 0
    private var pending: MethodChannel.Result? = null

    /** The current attempt's binding, unbound when the attempt ends. */
    private var connection: ServiceConnection? = null
    private var boundContext: Context? = null

    fun register(flutterEngine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "remote_auth")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "redirectUri" ->
                        result.success(redirectUri(appContext, call.argument<String>("base")))
                    "authorize" -> authorize(
                        appContext,
                        call.argument<String>("url"),
                        call.argument<String>("base"),
                        result,
                    )
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
    private fun redirectUri(context: Context, base: String?): String =
        OAuthRequest.Builder(context)
            .setAuthProviderUrl(Uri.parse("https://example.invalid/auth"))
            .apply { if (base != null) setRedirectUrl(Uri.parse(base)) }
            .setClientId("x")
            .setCodeChallenge(CodeChallenge(CodeVerifier()))
            .build()
            .redirectUrl

    /**
     * [base] replaces Google's relay as the redirect (the package is still
     * appended), e.g. a companion app's own registered address.
     */
    private fun authorize(
        context: Context,
        url: String?,
        base: String?,
        result: MethodChannel.Result,
    ) {
        end { it.error("cancelled", "A newer sign-in started", null) }
        val id = attempt
        // With only the provider URL set, build() appends just redirect_uri
        // (rejecting a different one already in the URL) and checks that the
        // URL carries client_id, response_type=code and an S256 challenge.
        val request = try {
            requireNotNull(url) { "No url" }
            OAuthRequest.Builder(context)
                .setAuthProviderUrl(Uri.parse(url))
                .apply { if (base != null) setRedirectUrl(Uri.parse(base)) }
                .build()
        } catch (e: IllegalArgumentException) {
            result.error("badRequest", e.message, null)
            return
        } catch (e: UnsupportedOperationException) {
            // Uri.getQueryParameter on an opaque URI (e.g. "mailto:...").
            result.error("badRequest", e.message, null)
            return
        }
        // OAuthRequest.toBundle() is internal to the library; same keys.
        val requestBundle = Bundle().apply {
            putParcelable(KEY_REQUEST_URL, request.requestUrl)
            putString(KEY_PACKAGE_NAME, request.packageName)
        }

        val intent = Intent(ACTION_AUTH).setPackage(COMPANION_PACKAGE)
        if (context.packageManager.resolveService(intent, 0) == null) {
            result.error("unsupported", "No Wear OS companion auth service", null)
            return
        }

        val newConnection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                if (id != attempt) return
                if (service == null) {
                    end { it.error("failed", "The companion's auth service gave no binder", null) }
                    return
                }
                send(id, service, requestBundle)
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                if (id != attempt) return
                Log.w(TAG, "The companion's auth service disconnected")
                end { it.error("failed", "The companion's auth service disconnected", null) }
            }

            override fun onBindingDied(name: ComponentName?) {
                if (id != attempt) return
                Log.w(TAG, "The companion's auth service binding died")
                end { it.error("failed", "The companion's auth service stopped", null) }
            }

            override fun onNullBinding(name: ComponentName?) {
                if (id != attempt) return
                Log.w(TAG, "The companion's auth service returned no binder")
                end { it.error("failed", "The companion's auth service gave no binder", null) }
            }
        }
        // Stored before binding, so end() unbinds it whatever happens next.
        pending = result
        connection = newConnection
        boundContext = context
        val bound = try {
            context.bindService(intent, newConnection, Context.BIND_AUTO_CREATE)
        } catch (e: RuntimeException) {
            // SecurityException: not allowed to bind.
            Log.w(TAG, "Could not bind the companion's auth service", e)
            false
        }
        if (!bound && id == attempt) {
            end { it.error("unsupported", "Could not reach the companion's auth service", null) }
        }
    }

    /** Hands the request to the bound service; its answer comes to [deliver]. */
    private fun send(id: Int, binder: IBinder, requestBundle: Bundle) {
        val callback = object : IAuthenticationRequestCallback.Stub() {
            // On a binder thread.
            override fun onResult(data: Bundle?) {
                mainHandler.post { if (id == attempt) deliver(data) }
            }

            // What RemoteAuthClient's callback reports.
            override fun getApiVersion(): Int = IAuthenticationRequestCallback.API_VERSION
        }
        try {
            IAuthenticationRequestService.Stub.asInterface(binder).openUrl(requestBundle, callback)
        } catch (e: Exception) {
            // RemoteException (DeadObjectException), or e.g. a SecurityException
            // or IllegalArgumentException thrown by the companion across Binder.
            Log.w(TAG, "Could not send the sign-in request", e)
            if (id == attempt) end { it.error("failed", e.message ?: e.toString(), null) }
        }
    }

    /** Parses the companion's result as RemoteAuthClient does. */
    private fun deliver(data: Bundle?) {
        val (errorCode, responseUrl) = try {
            val code = data?.getInt(KEY_ERROR_CODE, NO_ERROR) ?: NO_ERROR
            @Suppress("DEPRECATION")
            code to (data?.getParcelable<Uri>(KEY_RESPONSE_URL))
        } catch (e: RuntimeException) {
            // A malformed bundle (BadParcelableException, ClassCastException).
            Log.w(TAG, "Could not read the phone's answer", e)
            end { it.error("failed", "Could not read the phone's answer", null) }
            return
        }
        if (errorCode != NO_ERROR) Log.w(TAG, "Sign-in on the phone failed: $errorCode")
        end {
            when (errorCode) {
                NO_ERROR ->
                    if (responseUrl == null) {
                        it.error("failed", "The phone sent no response URL", null)
                    } else {
                        it.success(responseUrl.toString())
                    }
                RemoteAuthClient.ERROR_UNSUPPORTED ->
                    it.error("unsupported", "Phone sign-in is not supported", null)
                RemoteAuthClient.ERROR_PHONE_UNAVAILABLE ->
                    it.error("phoneUnavailable", "The phone is not connected", null)
                else -> it.error("failed", "Error code $errorCode", errorCode)
            }
        }
    }

    /**
     * Ends the current attempt, if any: unbinds its service and replies once
     * through [reply] (null: don't reply).
     */
    private fun end(reply: ((MethodChannel.Result) -> Unit)?) {
        attempt++
        val result = pending
        pending = null
        val conn = connection
        val context = boundContext
        connection = null
        boundContext = null
        if (conn != null && context != null) {
            try {
                context.unbindService(conn)
            } catch (e: RuntimeException) {
                // IllegalArgumentException: never registered (bind threw).
                Log.w(TAG, "Could not unbind the companion's auth service", e)
            }
        }
        if (result != null) reply?.invoke(result)
    }
}
