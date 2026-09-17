package br.com.flowbiz.onsite.demo

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.text.InputType
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import br.com.flowbiz.onsite.Checkout
import br.com.flowbiz.onsite.Event
import br.com.flowbiz.onsite.Flowbiz
import br.com.flowbiz.onsite.RecoveryPayload

/**
 * Single-activity fake store (SPEC §14): product list → product detail →
 * cart → checkout, plus login, a settings/debug panel and a deep-link
 * recovery screen. Plain programmatic Views — no extra dependencies; the
 * goal is clarity of the SDK call sites, not UX.
 *
 * Every `Flowbiz.*` call site carries a one-line comment naming the SPEC
 * section it demonstrates.
 */
class MainActivity : Activity() {

    // ---- Screen model -----------------------------------------------------

    private sealed interface Screen {
        val path: String
        val title: String
    }

    private object ProductListScreen : Screen {
        override val path = "/"
        override val title = "Produtos"
    }

    private class ProductDetailScreen(val product: DemoProduct) : Screen {
        override val path = product.url
        override val title = product.name
    }

    private object CartScreen : Screen {
        override val path = "/carrinho"
        override val title = "Carrinho"
    }

    private class CheckoutScreen(val step: Int) : Screen {
        override val path = "/checkout"
        override val title = "Checkout"
    }

    private object LoginScreen : Screen {
        override val path = "/login"
        override val title = "Login"
    }

    private object SettingsScreen : Screen {
        override val path = "/ajustes"
        override val title = "Ajustes"
    }

    private class RecoveryScreen(val source: String, val payload: RecoveryPayload?) : Screen {
        override val path = "/carrinho/recuperar"
        override val title = "Recuperação"
    }

    private val backStack = ArrayDeque<Screen>()
    private var current: Screen? = null

    /** Demo-local mirror of the opt-out switch (the SDK persists the real state internally). */
    private var trackingEnabled = true

    // ---- Lifecycle & deep links ------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!handleDeepLink(intent)) show(ProductListScreen)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    /** SPEC §11 receiving side: forward any incoming link, branch on the return value. */
    private fun handleDeepLink(intent: Intent?): Boolean {
        val uri = intent?.data ?: return false
        // SPEC §11: pure decoder — null means "no decodable _mb_cr_ param".
        val payload = Flowbiz.handleLink(uri)
        show(RecoveryScreen(uri.toString(), payload))
        return true
    }

    // ---- Navigation -------------------------------------------------------

    private fun show(screen: Screen, push: Boolean = true) {
        if (push) current?.let(backStack::addLast)
        current = screen
        // SPEC §5 `page.view`: tracked on every screen change (SPEC §14).
        Flowbiz.track(Event.PageView(path = screen.path, title = screen.title))
        render(screen)
    }

    @Deprecated("Deprecated in android.app.Activity")
    override fun onBackPressed() {
        val previous = backStack.removeLastOrNull()
        if (previous == null) {
            @Suppress("DEPRECATION")
            super.onBackPressed()
            return
        }
        current = previous
        // SPEC §5 `page.view`: back navigation is a screen change too.
        Flowbiz.track(Event.PageView(path = previous.path, title = previous.title))
        render(previous)
    }

    private fun render(screen: Screen) {
        when (screen) {
            is ProductListScreen -> renderProductList()
            is ProductDetailScreen -> renderProductDetail(screen.product)
            is CartScreen -> renderCart()
            is CheckoutScreen -> renderCheckout(screen.step)
            is LoginScreen -> renderLogin()
            is SettingsScreen -> renderSettings()
            is RecoveryScreen -> renderRecovery(screen)
        }
    }

    // ---- Screens ----------------------------------------------------------

    private fun renderProductList(): Unit = content("Bela Moda Store") {
        label(
            "Loja fake de demonstração do Flowbiz Onsite SDK. Offline? Tudo bem: " +
                "os eventos ficam numa fila em disco e são reenviados com backoff " +
                "exponencial (SPEC §9). Logs: tag FlowbizOnsite."
        )
        DemoCatalog.products.forEach { product ->
            label("${product.name}\n${product.brand} — R$ %.2f".format(product.price), bold = true)
            action("Ver produto") { show(ProductDetailScreen(product)) }
        }
        divider()
        action("Carrinho (${DemoCart.itemCount})") { show(CartScreen) }
        action("Login") { show(LoginScreen) }
        action("Ajustes / Debug") { show(SettingsScreen) }
    }

    private fun renderProductDetail(product: DemoProduct) {
        // SPEC §5 `product.view`: tracked when the product screen opens.
        Flowbiz.track(Event.ProductView(DemoCatalog.toSdkProduct(product)))
        content(product.name) {
            label("${product.brand} • ${product.category}")
            label("R$ %.2f (de R$ %.2f)".format(product.price, product.priceFrom), bold = true)
            label("SKU: ${product.sku} — ${product.properties}")
            action("Adicionar ao carrinho") {
                DemoCart.add(product)
                // SPEC §5 `cart.add`: only the line that was added.
                Flowbiz.track(Event.AddToCart(listOf(DemoCart.toCartItem(product, 1))))
                // SPEC §5 `cart.sync`: full cart snapshot after the change.
                Flowbiz.track(Event.CartSync(DemoCart.toCart()))
                Toast.makeText(this@MainActivity, "cart.add + cart.sync enfileirados", Toast.LENGTH_SHORT).show()
            }
            action("Ir para o carrinho (${DemoCart.itemCount})") { show(CartScreen) }
        }
    }

    private fun renderCart(): Unit = content("Carrinho") {
        if (DemoCart.lines.isEmpty()) label("Carrinho vazio.")
        DemoCart.lines.forEach { (product, qty) ->
            label("${product.name}\n$qty × R$ %.2f".format(product.price), bold = true)
            action("+1") {
                DemoCart.setQuantity(product.sku, qty + 1)
                // SPEC §5 `cart.item.update`: quantity change for one line.
                Flowbiz.track(Event.CartItemUpdate(DemoCart.CART_ID, product.productId, product.sku, qty + 1))
                renderCart()
            }
            action("-1") {
                DemoCart.setQuantity(product.sku, qty - 1)
                // SPEC §5 `cart.item.update`: quantity 0 removes the line store-side.
                Flowbiz.track(Event.CartItemUpdate(DemoCart.CART_ID, product.productId, product.sku, qty - 1))
                renderCart()
            }
        }
        divider()
        val couponInput = input("Cupom (ex.: BEMVINDA10)", DemoCart.coupon)
        action("Aplicar cupom") {
            val coupon = couponInput.text.toString().trim()
            if (coupon.isNotEmpty()) {
                DemoCart.coupon = coupon
                // SPEC §5 `cart.setcoupon`.
                Flowbiz.track(Event.CartSetCoupon(DemoCart.CART_ID, coupon))
                renderCart()
            }
        }
        val cepInput = input("CEP (ex.: 01310-100)", DemoCart.postalCode)
        action("Calcular frete (CEP)") {
            val cep = cepInput.text.toString().trim()
            if (cep.isNotEmpty()) {
                DemoCart.postalCode = cep
                // SPEC §5 `cart.setpostalcode`.
                Flowbiz.track(Event.CartSetPostalCode(DemoCart.CART_ID, cep))
                renderCart()
            }
        }
        divider()
        label(
            "Subtotal: R$ %.2f\nDesconto: R$ %.2f\nFrete: R$ %.2f\nTotal: R$ %.2f"
                .format(DemoCart.subtotal(), DemoCart.discounts(), DemoCart.freight(), DemoCart.total()),
            bold = true,
        )
        action("Sincronizar carrinho (cart.sync)") {
            // SPEC §5 `cart.sync` — an empty cart still sends (SPEC §7: emptying is signal).
            Flowbiz.track(Event.CartSync(DemoCart.toCart()))
            Toast.makeText(this@MainActivity, "cart.sync enfileirado", Toast.LENGTH_SHORT).show()
        }
        action("Finalizar compra") { show(CheckoutScreen(1)) }
    }

    private fun renderCheckout(step: Int) {
        // SPEC §5 `checkout.step`: one event per step of the funnel.
        Flowbiz.track(Event.CheckoutStep(Checkout(DemoCart.CART_ID, step, STEP_NAMES.size, STEP_NAMES[step - 1])))
        content("Checkout — etapa $step/${STEP_NAMES.size} (${STEP_NAMES[step - 1]})") {
            label("Total: R$ %.2f — ${DemoCart.itemCount} item(ns)".format(DemoCart.total()))
            if (step < STEP_NAMES.size) {
                action("Próxima etapa") { show(CheckoutScreen(step + 1)) }
            } else {
                action("Concluir pedido (order.complete)") {
                    val orderId = "ord-${System.currentTimeMillis()}"
                    // SPEC §5 `order.complete`: full order incl. payment/delivery methods.
                    Flowbiz.track(Event.OrderComplete(DemoCart.toOrder(orderId)))
                    DemoCart.clear()
                    dialog("Pedido concluído", "order.complete enfileirado ($orderId).")
                    backStack.clear()
                    show(ProductListScreen, push = false)
                }
            }
            action("Cancelar pedido (order.cancel)") {
                // SPEC §5 `order.cancel`: at least one of orderId/cartId.
                Flowbiz.track(Event.OrderCancel(cartId = DemoCart.CART_ID))
                show(CartScreen)
            }
        }
    }

    private fun renderLogin(): Unit = content("Login") {
        val user = DemoCatalog.fakeUser
        label("Usuária fake: ${user.name} <${user.email}>")
        label("Após login/sync o SDK grava user_id/email e todos os eventos passam a carregar identity.user_id (SPEC §5/§6).")
        action("Entrar (account.login)") {
            // SPEC §5 `account.login`: also stores user_id/email for the identity block.
            Flowbiz.track(Event.AccountLogin(user))
            dialog("account.login", "Evento enfileirado para ${user.userId}.")
        }
        action("Sincronizar conta (account.sync)") {
            // SPEC §5 `account.sync`: same payload, distinct wire event.
            Flowbiz.track(Event.AccountSync(user))
        }
        action("Sair (logout)") {
            // SPEC §6: clears identity, rotates session, auto-emits push.token.remove (§10.1).
            Flowbiz.logout()
            dialog("logout", "Identidade limpa; sessão rotacionada; push.token.remove automático se havia token.")
        }
    }

    private fun renderSettings(): Unit = content("Ajustes / Debug") {
        addView(Switch(this@MainActivity).apply {
            text = "Coleta habilitada (setEnabled)"
            isChecked = trackingEnabled
            setOnCheckedChangeListener { _, checked ->
                trackingEnabled = checked
                // SPEC §12 opt-out: persisted; disabled = drop events, stop heartbeat, no network.
                Flowbiz.setEnabled(checked)
            }
        })
        label("Gancho de consentimento LGPD/GDPR; o SDK persiste o estado real — o switch acima reflete só esta sessão do app.")
        divider()
        action("setPushToken (token fake)") {
            // SPEC §10.1: emits push.token.sync through the normal queue/dedup pipeline.
            Flowbiz.setPushToken(FAKE_PUSH_TOKEN)
        }
        action("removePushToken") {
            // SPEC §10.1: emits push.token.remove with the stored token, then forgets it.
            Flowbiz.removePushToken()
        }
        action("flush (drena a fila)") {
            // SPEC §9: explicit flush is one of the queue retry triggers.
            Flowbiz.flush()
        }
        action("logout") {
            // SPEC §6: clears identity, rotates session, auto-emits push.token.remove.
            Flowbiz.logout()
        }
        divider()
        action("Simular push (SPEC §10.2)") { simulatePush() }
        action("Simular link de recuperação (SPEC §11)") { simulateRecoveryLink() }
        divider()
        label(
            "Identidade anônima: o SDK mantém um anonymous_id persistente e um " +
                "session_id rotativo (SPEC §6). Eles viajam no bloco identity de cada " +
                "evento e não são expostos pela API pública; logout() limpa o user_id " +
                "e os eventos voltam a ser anônimos."
        )
        label(
            "Rede: com o collectorUrl padrão inalcançável/offline os POSTs falham sem " +
                "quebrar nada — os eventos aguardam na fila JSONL e o backoff " +
                "exponencial reenvia no próximo track/foreground/rede/flush (SPEC §9)."
        )
    }

    private fun renderRecovery(screen: RecoveryScreen): Unit = content("Recuperação de carrinho") {
        label("Link recebido:\n${screen.source}")
        val payload = screen.payload
        if (payload == null) {
            label("Flowbiz.handleLink devolveu null — o link não carrega um _mb_cr_ decodificável (SPEC §11).", bold = true)
        } else {
            label("RecoveryPayload (SPEC §11):", bold = true)
            label("cartId: ${payload.cartId}\nuserId: ${payload.userId}")
            payload.products.forEach { product ->
                label("• ${product.quantity}× ${product.productId} / ${product.sku}" +
                    (product.recoveryProperties?.let { " $it" } ?: ""))
            }
            action("Restaurar carrinho") {
                DemoCart.restore(payload)
                // SPEC §5 `cart.sync`: snapshot after restoring the recovered items.
                Flowbiz.track(Event.CartSync(DemoCart.toCart()))
                show(CartScreen)
            }
        }
        action("Voltar à loja") { show(ProductListScreen) }
    }

    // ---- Debug actions ----------------------------------------------------

    private fun simulatePush() {
        // Canned SPEC §10.2 payload — mirrors shared/push-samples/samples.json
        // ("cart_recovery_with_real_mb_cr_deep_link"): flat map with the
        // "flowbiz" marker carrying a JSON-encoded string, exactly what
        // FirebaseMessagingService.onMessageReceived would hand over.
        val payload = mapOf("flowbiz" to SIMULATED_PUSH_MARKER)
        // SPEC §10.3: pure parser; null would mean "not a Flowbiz push".
        val push = Flowbiz.handlePush(payload)
        if (push == null) {
            dialog("handlePush", "null — payload não é do Flowbiz")
            return
        }
        // SPEC §10.2: a cart-recovery push carries _mb_cr_ in deep_link,
        // decoded by the same §11 parser via recoveryPayload.
        val recovery = push.recoveryPayload
        val message = buildString {
            appendLine("FlowbizPush:")
            appendLine("v=${push.version} type=${push.type}")
            appendLine("title=${push.title}")
            appendLine("body=${push.body}")
            appendLine("deepLink=${push.deepLink}")
            appendLine("data=${push.data}")
            appendLine()
            append(
                if (recovery == null) "recoveryPayload=null"
                else "recoveryPayload: cart ${recovery.cartId}, user ${recovery.userId}, ${recovery.products.size} item(ns)"
            )
        }
        val openRecovery: (Pair<String, () -> Unit>)? = recovery?.let {
            "Abrir recuperação" to { show(RecoveryScreen("push deep_link: ${push.deepLink}", it)) }
        }
        dialog("Push simulado (SPEC §10)", message, openRecovery)
    }

    private fun simulateRecoveryLink() {
        // Hash from shared/recovery-links/vectors.json ("basic"):
        // decodes to cart-abc-001 / user-123 / P100 + P200 — no adb needed.
        val uri = Uri.parse(DEMO_LINK_PREFIX + RECOVERY_HASH)
        // SPEC §11: exactly the call the OS deep-link path (onNewIntent) uses.
        val payload = Flowbiz.handleLink(uri)
        show(RecoveryScreen(uri.toString(), payload))
    }

    // ---- Tiny programmatic-UI helpers ------------------------------------

    private fun content(title: String, build: LinearLayout.() -> Unit) {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(32))
        }
        column.label(title, size = 22f, bold = true)
        column.build()
        setContentView(ScrollView(this).apply { addView(column) })
    }

    private fun LinearLayout.label(text: String, size: Float = 14f, bold: Boolean = false): TextView {
        val view = TextView(context).apply {
            this.text = text
            textSize = size
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(4), 0, dp(4))
        }
        addView(view)
        return view
    }

    private fun LinearLayout.action(text: String, onClick: () -> Unit) {
        addView(Button(context).apply {
            this.text = text
            isAllCaps = false
            setOnClickListener { onClick() }
        })
    }

    private fun LinearLayout.input(hint: String, preset: String? = null): EditText {
        val view = EditText(context).apply {
            this.hint = hint
            inputType = InputType.TYPE_CLASS_TEXT
            preset?.let(::setText)
        }
        addView(view)
        return view
    }

    private fun LinearLayout.divider() {
        addView(TextView(context).apply { setPadding(0, dp(8), 0, dp(8)) })
    }

    private fun dialog(title: String, message: String, extra: Pair<String, () -> Unit>? = null) {
        val builder = AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton("OK", null)
        extra?.let { (text, run) -> builder.setNeutralButton(text) { _, _ -> run() } }
        builder.show()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private companion object {
        val STEP_NAMES = listOf("identificacao", "entrega", "pagamento")

        const val FAKE_PUSH_TOKEN = "fake-fcm-token-0123456789abcdef"

        /** Custom demo scheme (see AndroidManifest intent filter). */
        const val DEMO_LINK_PREFIX = "flowbizdemo://recover?utm_source=flowbiz&_mb_cr_="

        /** "basic" vector from shared/recovery-links/vectors.json. */
        const val RECOVERY_HASH =
            "eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19"

        /** SPEC §10.2 marker value from shared/push-samples/samples.json. */
        const val SIMULATED_PUSH_MARKER =
            """{"v":1,"type":"cart_recovery","title":"Sua sacola te espera!","body":"Finalize sua compra...","deep_link":"https://store.com/carrinho?utm_source=flowbiz&_mb_cr_=eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCIsIntcImNvclwiOlwiQXp1bFwiLFwidGFtYW5ob1wiOlwiUFwifSJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19","data":{"campaign_id":"cr-42"}}"""
    }
}
