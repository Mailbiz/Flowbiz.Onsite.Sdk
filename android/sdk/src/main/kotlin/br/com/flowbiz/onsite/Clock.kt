package br.com.flowbiz.onsite

internal interface Clock {
    fun monotonicMillis(): Long
    fun wallMillis(): Long
}
