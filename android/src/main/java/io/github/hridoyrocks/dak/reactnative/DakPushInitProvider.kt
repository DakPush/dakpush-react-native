package io.github.hridoyrocks.dak.reactnative

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri

/**
 * Starts the SDK when the app's process starts, like `Dak.init` in
 * `Application.onCreate` in a native app. Holds no data.
 */
class DakPushInitProvider : ContentProvider() {
  override fun onCreate(): Boolean {
    context?.let { DakPushBridge.start(it) }
    return true
  }

  override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null

  override fun getType(uri: Uri): String? = null

  override fun insert(uri: Uri, values: ContentValues?): Uri? = null

  override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

  override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
