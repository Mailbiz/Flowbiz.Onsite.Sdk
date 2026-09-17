package br.com.flowbiz.onsite

import org.json.JSONObject
import java.io.File

/**
 * Test doubles and harness for the Slice 4 core ([FlowbizCore] with every
 * seam faked): the tests drive the serial scheduler inline and observe the
 * wire through [FakeHttpSender] bodies.
 */

/** Recorded [ReachabilityMonitor]; tests fire [callback] to simulate network restoration. */
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

/** Fixed-value [DeviceContext] with a mutable timezone offset. */
internal class FakeDeviceContext(
    override val language: String = "pt-BR",
    override val screen: String = "1080x2400",
    var offsetMinutes: Int = -180,
) : DeviceContext {
    override fun timezoneOffsetMinutes(wallMillis: Long): Int = offsetMinutes
}

/**
 * A [FlowbizCore] with every dependency faked. The [FakeTaskScheduler]
 * executes inline, so `core.track(...)` runs the whole pipeline (including
 * the flush drain) synchronously on the test thread.
 */
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
