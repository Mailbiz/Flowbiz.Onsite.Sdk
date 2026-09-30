package br.com.flowbiz.onsite.demo

import android.app.Application
import br.com.flowbiz.onsite.Flowbiz
import br.com.flowbiz.onsite.FlowbizConfig

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
