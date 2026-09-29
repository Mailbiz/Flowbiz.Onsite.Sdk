package br.com.flowbiz.onsite

import org.json.JSONObject
import java.io.File

internal class FakeReachability : ReachabilityMonitor {
    var started = false
    var callback: Runnable? = null

    override fun start(onNetworkAvailable: Runnable) {
        started = true
        callback = onNetworkAvailable
    }

    override fun stop() {
        started = false
        callback = null
    }
}

internal class FakeDeviceContext(
    override val language: String = "pt-BR",
    override val screen: String = "1080x2400",
    var offsetMinutes: Int = -180,
) : DeviceContext {
    override fun timezoneOffsetMinutes(wallMillis: Long): Int = offsetMinutes
}

/** [FlowbizCore] over fakes; the inline scheduler runs `track` and its flush synchronously. */
internal class CoreHarness(
    queueDir: File,
    val config: FlowbizConfig = FlowbizConfig(appId = "77777", baseUri = "https://store.com"),
    val store: FakeKeyValueStore = FakeKeyValueStore(),
    val clock: FakeClock = FakeClock(),
    val sender: FakeHttpSender = FakeHttpSender(),
    val scheduler: FakeTaskScheduler = FakeTaskScheduler(),
    val device: FakeDeviceContext = FakeDeviceContext(),
    val reachability: FakeReachability = FakeReachability(),
) {
    val queue = EventQueue(File(queueDir, "queue.jsonl"))
    val core = FlowbizCore(
        config = config,
        store = store,
        queueFactory = { queue },
        sender = sender,
        scheduler = scheduler,
        clock = clock,
        deviceContext = device,
        reachability = reachability,
    )

    /** Entries of every sent body, in send order (flush batches flattened). */
    fun sentEntries(): List<JSONObject> = sender.bodies.flatMap { body ->
        val data = JSONObject(body).getJSONArray("data")
        (0 until data.length()).map { data.getJSONObject(it) }
    }

    fun lastEntry(): JSONObject = sentEntries().last()
}
