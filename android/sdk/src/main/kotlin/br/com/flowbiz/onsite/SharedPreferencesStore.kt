package br.com.flowbiz.onsite

import android.content.Context
import android.content.SharedPreferences

internal class SharedPreferencesStore(context: Context, appId: String) : KeyValueStore {

    private val prefs: SharedPreferences = context.applicationContext
        .getSharedPreferences("flowbiz_onsite_$appId", Context.MODE_PRIVATE)

    override fun getString(key: String): String? =
        runCatching { prefs.getString(key, null) }.getOrNull()

    override fun getInt(key: String): Int? =
        runCatching { if (prefs.contains(key)) prefs.getInt(key, 0) else null }.getOrNull()

    override fun getLong(key: String): Long? =
        runCatching { if (prefs.contains(key)) prefs.getLong(key, 0L) else null }.getOrNull()

    override fun getBoolean(key: String): Boolean? =
        runCatching { if (prefs.contains(key)) prefs.getBoolean(key, false) else null }.getOrNull()

    override fun putString(key: String, value: String) {
        runCatching { prefs.edit().putString(key, value).apply() }
    }

    override fun putInt(key: String, value: Int) {
        runCatching { prefs.edit().putInt(key, value).apply() }
    }

    override fun putLong(key: String, value: Long) {
        runCatching { prefs.edit().putLong(key, value).apply() }
    }

    override fun putBoolean(key: String, value: Boolean) {
        runCatching { prefs.edit().putBoolean(key, value).apply() }
    }

    override fun remove(key: String) {
        runCatching { prefs.edit().remove(key).apply() }
    }
}
