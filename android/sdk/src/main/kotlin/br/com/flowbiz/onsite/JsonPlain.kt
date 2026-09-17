package br.com.flowbiz.onsite

import org.json.JSONArray
import org.json.JSONObject

/**
 * org.json tree → plain Kotlin values (`Map`/`List`/scalars, `JSONObject.NULL`
 * → null), for the public maps returned by `handlePush`/`handleLink`.
 */
internal object JsonPlain {

    fun toPlainMap(json: JSONObject): Map<String, Any?> {
        val result = LinkedHashMap<String, Any?>()
        val iterator = json.keys()
        while (iterator.hasNext()) {
            val key = iterator.next() as String
            result[key] = toPlainValue(json.get(key))
        }
        return result
    }

    private fun toPlainValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> toPlainMap(value)
        is JSONArray -> (0 until value.length()).map { toPlainValue(value.get(it)) }
        else -> value
    }
}
