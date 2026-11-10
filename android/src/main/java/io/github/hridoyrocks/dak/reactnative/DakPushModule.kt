package io.github.hridoyrocks.dak.reactnative

import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import io.github.hridoyrocks.dak.Dak
import io.github.hridoyrocks.dak.DakCallback
import io.github.hridoyrocks.dak.DakException
import io.github.hridoyrocks.dak.DakSubscription

/**
 * The TurboModule: each call goes to the DakPush Android SDK. Events come
 * from [DakPushBridge], which listens to the SDK for the whole process.
 */
class DakPushModule(reactContext: ReactApplicationContext) : NativeDakPushSpec(reactContext) {
  private val main = Handler(Looper.getMainLooper())
  private val blocks = HashMap<Int, DakSubscription>()

  private val emitter = DakPushBridge.Emitter { event, payload ->
    val context = reactApplicationContext
    if (!context.hasActiveReactInstance()) return@Emitter
    val value: Any? = when (payload) {
      is Map<*, *> -> {
        @Suppress("UNCHECKED_CAST")
        Arguments.makeNativeMap(payload as Map<String, Any?>)
      }
      else -> payload
    }
    context.emitDeviceEvent(event, value)
  }

  override fun initialize() {
    super.initialize()
    DakPushBridge.attach()
    DakPushBridge.setEmitter(emitter)
  }

  override fun invalidate() {
    DakPushBridge.clearEmitter(emitter)
    synchronized(blocks) {
      blocks.values.forEach { it.remove() }
      blocks.clear()
    }
    super.invalidate()
  }

  // ---- state

  override fun getState(promise: Promise) {
    val config = DakPushBridge.config
    promise.resolve(
      Arguments.makeNativeMap(
        mapOf(
          "started" to Dak.isInitialized,
          "appId" to config?.appId,
          "baseUrl" to config?.baseUrl,
          "sdkVersion" to "android-${Dak.VERSION}",
          "platform" to "android",
        ),
      ),
    )
  }

  override fun getDeviceId(promise: Promise) {
    promise.resolve(if (Dak.isInitialized) Dak.deviceId else null)
  }

  override fun getInitialNotification(promise: Promise) {
    promise.resolve(DakPushBridge.initialNotification?.let { Arguments.makeNativeMap(it) })
  }

  // ---- permission

  override fun requestPermission(provisional: Boolean, promise: Promise) {
    if (!started(promise)) return
    Dak.requestPermission { allowed -> promise.resolve(allowed) }
  }

  override fun hasPermission(promise: Promise) {
    promise.resolve(NotificationManagerCompat.from(reactApplicationContext).areNotificationsEnabled())
  }

  override fun openNotificationSettings() {
    if (Dak.isInitialized) main.post { Dak.openNotificationSettings() }
  }

  // ---- user, tags, subscription

  override fun login(externalId: String, authHash: String?, promise: Promise) {
    if (!started(promise)) return
    call(promise) { Dak.login(externalId, authHash, done(promise)) }
  }

  override fun logout(promise: Promise) {
    if (!started(promise)) return
    call(promise) { Dak.logout(done(promise)) }
  }

  override fun setTags(tags: ReadableMap, promise: Promise) {
    if (!started(promise)) return
    val values = LinkedHashMap<String, Any?>()
    val it = tags.keySetIterator()
    while (it.hasNextKey()) {
      val key = it.nextKey()
      values[key] = if (tags.getType(key) == ReadableType.Null) null else tags.getString(key)
    }
    call(promise) { Dak.setTags(values, done(promise)) }
  }

  override fun setSubscribed(subscribed: Boolean, promise: Promise) {
    if (!started(promise)) return
    call(promise) { Dak.setSubscribed(subscribed, done(promise)) }
  }

  override fun setBadge(count: Double, promise: Promise) {
    // Android launchers count notifications themselves.
    promise.resolve(null)
  }

  override fun flush(promise: Promise) {
    if (!started(promise)) return
    call(promise) { Dak.flush(done(promise)) }
  }

  override fun showNotification(id: String, promise: Promise) {
    if (!started(promise)) return
    val n = DakPushBridge.foregroundNotification(id)
    if (n == null) {
      promise.resolve(false)
      return
    }
    Dak.showNotification(n) { shown -> promise.resolve(shown) }
  }

  // ---- in-app messages

  override fun addTriggers(triggers: ReadableMap) {
    if (!Dak.isInitialized) return
    val values = LinkedHashMap<String, Any>()
    val it = triggers.keySetIterator()
    while (it.hasNextKey()) {
      val key = it.nextKey()
      when (triggers.getType(key)) {
        ReadableType.String -> triggers.getString(key)?.let { values[key] = it }
        ReadableType.Number -> values[key] = triggers.getDouble(key)
        ReadableType.Boolean -> values[key] = triggers.getBoolean(key)
        else -> Unit
      }
    }
    if (values.isNotEmpty()) Dak.addTriggers(values)
  }

  override fun removeTriggers(keys: ReadableArray) {
    if (!Dak.isInitialized) return
    Dak.removeTriggers((0 until keys.size()).mapNotNull { keys.getString(it) })
  }

  override fun clearTriggers() {
    if (Dak.isInitialized) Dak.clearTriggers()
  }

  override fun pauseInApp(paused: Boolean) {
    if (Dak.isInitialized) Dak.pauseInApp(paused)
  }

  override fun isInAppPaused(promise: Promise) {
    promise.resolve(!Dak.isInitialized || Dak.isInAppPaused)
  }

  override fun blockInApp(id: Double) {
    if (!Dak.isInitialized) return
    val block = Dak.blockInApp()
    synchronized(blocks) { blocks.put(id.toInt(), block) }?.remove()
  }

  override fun endInAppBlock(id: Double) {
    synchronized(blocks) { blocks.remove(id.toInt()) }?.remove()
  }

  override fun refreshInApp(promise: Promise) {
    // The Android SDK fetches in-app messages at each session start.
    promise.resolve(null)
  }

  // ---- events

  override fun addListener(eventName: String) {
    DakPushBridge.jsListening(emitter, eventName)
  }

  override fun removeListeners(count: Double) {
    // JS keeps one native listener per event type for the module's life.
  }

  // ---- helpers

  private fun started(promise: Promise): Boolean {
    if (Dak.isInitialized) return true
    promise.reject(
      "not_started",
      "DakPush is not started: add dakpush.app_id and dakpush.base_url to the app's manifest (the Expo plugin does this)",
    )
    return false
  }

  private inline fun call(promise: Promise, block: () -> Unit) {
    try {
      block()
    } catch (e: IllegalArgumentException) {
      promise.reject("invalid", e.message ?: "invalid value", e, info("invalid", null, null))
    } catch (e: IllegalStateException) {
      promise.reject("not_started", e.message ?: "DakPush is not started", e)
    }
  }

  private fun done(promise: Promise) = DakCallback { error: DakException? ->
    if (error == null) {
      promise.resolve(null)
    } else {
      promise.reject(error.code, error.message ?: error.code, error, info(error.code, error.field, error.status))
    }
  }

  private fun info(code: String, field: String?, status: Int?) = Arguments.createMap().apply {
    putString("code", code)
    if (field != null) putString("field", field) else putNull("field")
    if (status != null) putInt("status", status) else putNull("status")
  }

  companion object {
    const val NAME = NativeDakPushSpec.NAME
  }
}
