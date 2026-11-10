package io.github.hridoyrocks.dak.reactnative

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.github.hridoyrocks.dak.DakOptions

/**
 * The SDK's settings from the app's manifest: `<meta-data>` entries named
 * `dakpush.*` in `<application>`. The Expo plugin writes them; bare React
 * Native apps add them by hand (see the README).
 */
internal class DakPushConfig(
  val appId: String,
  val baseUrl: String,
  /** Show messages that arrive while the app is open, as in the background. */
  val showInForeground: Boolean,
  val options: DakOptions,
) {
  companion object {
    const val APP_ID = "dakpush.app_id"
    const val BASE_URL = "dakpush.base_url"
    const val SHOW_IN_FOREGROUND = "dakpush.show_in_foreground"
    const val SHARE_TIMEZONE_OFFSET = "dakpush.share_timezone_offset"
    const val USE_FID = "dakpush.use_fid"
    const val OPEN_APP_ON_TAP = "dakpush.open_app_on_tap"
    const val DEBUG_LOGS = "dakpush.debug_logs"
    const val IN_APP_MESSAGES = "dakpush.in_app_messages"
    const val SESSION_TIMEOUT = "dakpush.session_timeout"
    const val IN_APP_URL_SCHEMES = "dakpush.in_app_url_schemes"

    /** Null when the app has no App ID and server URL in its manifest. */
    fun read(context: Context): DakPushConfig? {
      val md = metaData(context) ?: return null
      return from(md)
    }

    fun from(md: Bundle): DakPushConfig? {
      val appId = value(md, APP_ID)?.toString()?.trim().orEmpty()
      val baseUrl = value(md, BASE_URL)?.toString()?.trim().orEmpty()
      if (appId.isEmpty() && baseUrl.isEmpty()) return null
      if (appId.isEmpty() || baseUrl.isEmpty()) {
        Log.w(TAG, "DakPush needs both $APP_ID and $BASE_URL in the manifest; it stays off")
        return null
      }
      val defaults = DakOptions()
      val timeout = number(value(md, SESSION_TIMEOUT))
      val schemes = value(md, IN_APP_URL_SCHEMES)?.toString()
        ?.split(',')?.map { it.trim().lowercase() }?.filter { it.isNotEmpty() }?.toSet()
      return DakPushConfig(
        appId = appId,
        baseUrl = baseUrl,
        showInForeground = bool(value(md, SHOW_IN_FOREGROUND)) ?: false,
        options = DakOptions(
          shareTimezoneOffset = bool(value(md, SHARE_TIMEZONE_OFFSET)) ?: defaults.shareTimezoneOffset,
          useFid = bool(value(md, USE_FID)) ?: defaults.useFid,
          openAppOnTap = bool(value(md, OPEN_APP_ON_TAP)) ?: defaults.openAppOnTap,
          debugLogs = bool(value(md, DEBUG_LOGS)) ?: defaults.debugLogs,
          inAppMessages = bool(value(md, IN_APP_MESSAGES)) ?: defaults.inAppMessages,
          sessionTimeoutMillis = timeout?.takeIf { it >= 0 }?.let { (it * 1000).toLong() }
            ?: defaults.sessionTimeoutMillis,
          inAppUrlSchemes = schemes?.takeIf { it.isNotEmpty() } ?: defaults.inAppUrlSchemes,
        ),
      )
    }

    /** A meta-data value: Android stores "true" as a Boolean and "300" as an Int. */
    @Suppress("DEPRECATION")
    private fun value(md: Bundle, key: String): Any? = md.get(key)

    private fun bool(v: Any?): Boolean? = when (v) {
      is Boolean -> v
      is String -> v.trim().lowercase().let { if (it == "true") true else if (it == "false") false else null }
      else -> null
    }

    private fun number(v: Any?): Double? = when (v) {
      is Number -> v.toDouble()
      is String -> v.trim().toDoubleOrNull()
      else -> null
    }

    @Suppress("DEPRECATION")
    private fun metaData(context: Context): Bundle? = try {
      val pm = context.packageManager
      val info = if (Build.VERSION.SDK_INT >= 33) {
        pm.getApplicationInfo(context.packageName, PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong()))
      } else {
        pm.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
      }
      info.metaData
    } catch (e: PackageManager.NameNotFoundException) {
      null
    }
  }
}

internal const val TAG = "DakPushRN"
