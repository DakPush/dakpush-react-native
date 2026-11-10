package io.github.hridoyrocks.dak.reactnative

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.github.hridoyrocks.dak.Dak
import io.github.hridoyrocks.dak.DakException
import io.github.hridoyrocks.dak.DakInAppClick
import io.github.hridoyrocks.dak.DakNotification

/**
 * The bridge's state for the whole process. It outlives the React Native
 * module, which is made again on every JS reload.
 *
 * It listens to the SDK from the moment the SDK starts (before JS runs), and
 * keeps events until JS listens to their type: taps, in-app clicks,
 * foreground messages and errors (20 of each), and the last device id.
 */
internal object DakPushBridge {
  const val OPENED = "DakPush.opened"
  const val FOREGROUND = "DakPush.foreground"
  const val ERROR = "DakPush.error"
  const val DEVICE_ID = "DakPush.deviceId"
  const val IN_APP_CLICK = "DakPush.inAppClick"
  private val EVENTS = setOf(OPENED, FOREGROUND, ERROR, DEVICE_ID, IN_APP_CLICK)

  const val MAX_HELD = 20

  private val main = Handler(Looper.getMainLooper())

  @Volatile
  var config: DakPushConfig? = null
    private set

  private var attached = false
  private var emitter: Emitter? = null
  private val listening = HashSet<String>()
  private val held = HashMap<String, ArrayDeque<Any>>()
  private var initial: Map<String, Any?>? = null
  private var openedSeen = false

  /** Foreground messages by id, for showNotification. */
  private val recent = object : LinkedHashMap<String, DakNotification>(16, 0.75f, true) {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, DakNotification>?) = size > MAX_HELD
  }

  /** The module's way to send an event to JS. */
  fun interface Emitter {
    fun emit(event: String, payload: Any?)
  }

  /** From the init provider: starts the SDK if the manifest has its settings. */
  fun start(context: Context) {
    val c = DakPushConfig.read(context)
    if (c == null) {
      Log.i(TAG, "DakPush is not set up in the manifest (dakpush.app_id, dakpush.base_url); not starting")
      return
    }
    try {
      Dak.init(context, c.appId, c.baseUrl, c.options)
      config = c
    } catch (e: IllegalArgumentException) {
      Log.e(TAG, "DakPush did not start: ${e.message}")
      return
    }
    attach()
  }

  /**
   * Listens to the SDK once it runs. Also called when the module starts, for
   * apps that call Dak.init themselves in Application.onCreate.
   */
  @Synchronized
  fun attach() {
    if (attached || !Dak.isInitialized) return
    attached = true
    Dak.addOpenedListener { n -> opened(n) }
    Dak.addForegroundListener { n -> foreground(n) }
    Dak.addErrorListener { e -> deliver(ERROR, errorMap(e)) }
    Dak.addDeviceIdListener { id -> deliver(DEVICE_ID, id) }
    Dak.addInAppClickListener { c -> deliver(IN_APP_CLICK, clickMap(c)) }
  }

  @Synchronized
  fun setEmitter(e: Emitter?) {
    emitter = e
    listening.clear()
  }

  @Synchronized
  fun clearEmitter(e: Emitter) {
    if (emitter === e) {
      emitter = null
      listening.clear()
    }
  }

  /** JS listens to [event] now: it gets what was kept for it. */
  fun jsListening(e: Emitter, event: String) {
    if (event !in EVENTS) return
    val kept: List<Any>
    synchronized(this) {
      if (emitter !== e) return
      listening.add(event)
      kept = held.remove(event)?.toList() ?: emptyList()
    }
    for (payload in kept) e.emit(event, payload)
  }

  @get:Synchronized
  val initialNotification: Map<String, Any?>? get() = initial

  @Synchronized
  fun foregroundNotification(id: String): DakNotification? = recent[id]

  private fun opened(n: DakNotification) {
    val map = notificationMap(n)
    synchronized(this) {
      // The first tap of the process that came before JS listened to taps:
      // the one that opened the app.
      if (!openedSeen && OPENED !in listening) initial = map
      openedSeen = true
    }
    deliver(OPENED, map)
  }

  private fun foreground(n: DakNotification) {
    n.id?.let { id -> synchronized(this) { recent[id] = n } }
    if (config?.showInForeground == true && !n.isSilent) {
      main.post { Dak.showNotification(n) }
    }
    deliver(FOREGROUND, notificationMap(n))
  }

  private fun deliver(event: String, payload: Any) {
    val e: Emitter?
    synchronized(this) {
      e = emitter?.takeIf { event in listening }
      if (e == null) {
        val q = held.getOrPut(event) { ArrayDeque() }
        if (event == DEVICE_ID) q.clear()
        q.addLast(payload)
        while (q.size > MAX_HELD) q.removeFirst()
        return
      }
    }
    e?.emit(event, payload)
  }

  fun notificationMap(n: DakNotification): Map<String, Any?> = mapOf(
    "id" to n.id,
    "title" to n.title,
    "body" to n.body,
    "url" to n.url,
    "imageUrl" to n.imageUrl,
    "data" to n.data,
    "buttons" to n.buttons.map { mapOf("id" to it.id, "text" to it.text, "url" to it.url) },
    "actionId" to n.actionId,
    "raw" to n.raw,
  )

  fun clickMap(c: DakInAppClick): Map<String, Any?> = mapOf(
    "messageId" to c.messageId,
    "buttonId" to c.buttonId,
    "actionType" to c.actionType,
    "url" to c.url,
    "tags" to c.tags,
  )

  fun errorMap(e: DakException): Map<String, Any?> = mapOf(
    "message" to (e.message ?: e.code),
    "code" to e.code,
    "field" to e.field,
    "status" to e.status,
  )
}
