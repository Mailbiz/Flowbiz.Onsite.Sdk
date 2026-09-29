package br.com.flowbiz.onsite.demo

import android.app.Application
import br.com.flowbiz.onsite.Flowbiz
import br.com.flowbiz.onsite.FlowbizConfig

/**
 * Fake-store demo over the production wiring. Failed POSTs are harmless: the
 * events wait in the durable queue and retry with backoff. Logcat tag
 * `FlowbizOnsite`.
 */
class DemoApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        // Initialize once, from Application.onCreate.
        Flowbiz.initialize(
            this,
            FlowbizConfig(
                appId = "77777",
                baseUri = "https://www.belamodastore.com.br",
                collectorUrl = BuildConfig.COLLECTOR_URL,
                debug = true,
                recoveryUrl = "https://www.belamodastore.com.br/carrinho",
            ),
        )
    }
}
