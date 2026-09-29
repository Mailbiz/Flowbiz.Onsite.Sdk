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
 * Only a fresh launch forwards its intent's link: a recreation or a relaunch
 * from Recents hands back an already handled link, whose old UTMs would be
 * captured again over newer ones.
 */
internal fun isFreshLinkLaunch(restoring: Boolean, intentFlags: Int): Boolean =
    !restoring && (intentFlags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0

/** Plain programmatic Views, no extra dependencies: the point is the SDK call sites, not UX. */
class MainActivity : Activity() {

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val freshLaunch = isFreshLinkLaunch(restoring = savedInstanceState != null, intentFlags = intent.flags)
        if (!(freshLaunch && handleDeepLink(intent))) show(ProductListScreen)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Keep getIntent() on the latest link, not the one that launched us.
        setIntent(intent)
        handleDeepLink(intent)
    }

    private fun handleDeepLink(intent: Intent?): Boolean {
        val uri = intent?.data ?: return false
        // Null: no decodable _mb_cr_ for this tenant. The UTMs are captured
        // either way and ride on the page.view that show() tracks below.
        val payload = Flowbiz.handleLink(uri)
        show(RecoveryScreen(uri.toString(), payload))
        return true
    }

    private fun show(screen: Screen, push: Boolean = true) {
        if (push) current?.let(backStack::addLast)
        current = screen
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
        // Back navigation is a screen change too.
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

    private fun renderProductList(): Unit = content("Bela Moda Store") {
        label(
            "Loja fake de demonstração do Flowbiz Onsite SDK. Offline? Tudo bem: " +
                "os eventos ficam numa fila em disco e são reenviados com backoff " +
                "exponencial. Logs: tag FlowbizOnsite."
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
        Flowbiz.track(Event.ProductView(DemoCatalog.toSdkProduct(product)))
        content(product.name) {
            label("${product.brand} • ${product.category}")
            label("R$ %.2f (de R$ %.2f)".format(product.price, product.priceFrom), bold = true)
            label("SKU: ${product.sku} — ${product.properties}")
            action("Adicionar ao carrinho") {
                DemoCart.add(product)
                // cart.add carries only the added line; cart.sync the whole cart after it.
                Flowbiz.track(Event.AddToCart(listOf(DemoCart.toCartItem(product, 1))))
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
                Flowbiz.track(Event.CartItemUpdate(DemoCart.CART_ID, product.productId, product.sku, qty + 1))
                renderCart()
            }
            action("-1") {
                DemoCart.setQuantity(product.sku, qty - 1)
                // Quantity 0 removes the line store-side.
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
                Flowbiz.track(Event.CartSetCoupon(DemoCart.CART_ID, coupon))
                renderCart()
            }
        }
        val cepInput = input("CEP (ex.: 01310-100)", DemoCart.postalCode)
        action("Calcular frete (CEP)") {
            val cep = cepInput.text.toString().trim()
            if (cep.isNotEmpty()) {
                DemoCart.postalCode = cep
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
            // An empty cart still sends: emptying it is a signal.
            Flowbiz.track(Event.CartSync(DemoCart.toCart()))
            Toast.makeText(this@MainActivity, "cart.sync enfileirado", Toast.LENGTH_SHORT).show()
        }
        action("Finalizar compra") { show(CheckoutScreen(1)) }
    }

    private fun renderCheckout(step: Int) {
        Flowbiz.track(Event.CheckoutStep(Checkout(DemoCart.CART_ID, step, STEP_NAMES.size, STEP_NAMES[step - 1])))
        content("Checkout — etapa $step/${STEP_NAMES.size} (${STEP_NAMES[step - 1]})") {
            label("Total: R$ %.2f — ${DemoCart.itemCount} item(ns)".format(DemoCart.total()))
            if (step < STEP_NAMES.size) {
                action("Próxima etapa") { show(CheckoutScreen(step + 1)) }
            } else {
                action("Concluir pedido (order.complete)") {
                    val orderId = "ord-${System.currentTimeMillis()}"
                    Flowbiz.track(Event.OrderComplete(DemoCart.toOrder(orderId)))
                    DemoCart.clear()
                    dialog("Pedido concluído", "order.complete enfileirado ($orderId).")
                    backStack.clear()
                    show(ProductListScreen, push = false)
                }
            }
            action("Cancelar pedido (order.cancel)") {
                // order.cancel needs at least one of orderId/cartId.
                Flowbiz.track(Event.OrderCancel(cartId = DemoCart.CART_ID))
                show(CartScreen)
            }
        }
    }

    private fun renderLogin(): Unit = content("Login") {
        val user = DemoCatalog.fakeUser
        label("Usuária fake: ${user.name} <${user.email}>")
        label("Após login/sync o SDK grava user_id/email e todos os eventos passam a carregar identity.user_id.")
        action("Entrar (account.login)") {
            Flowbiz.track(Event.AccountLogin(user))
            dialog("account.login", "Evento enfileirado para ${user.userId}.")
        }
        action("Sincronizar conta (account.sync)") {
            Flowbiz.track(Event.AccountSync(user))
        }
        action("Sair (logout)") {
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
                Flowbiz.setEnabled(checked)
            }
        })
        label("Gancho de consentimento LGPD/GDPR; o SDK persiste o estado real — o switch acima reflete só esta sessão do app.")
        divider()
        action("setPushToken (token fake)") {
            Flowbiz.setPushToken(FAKE_PUSH_TOKEN)
        }
        action("removePushToken") {
            Flowbiz.removePushToken()
        }
        action("flush (drena a fila)") {
            Flowbiz.flush()
        }
        action("logout") {
            Flowbiz.logout()
        }
        divider()
        action("Simular push") { simulatePush() }
        action("Simular link de recuperação") { simulateRecoveryLink() }
        divider()
        label(
            "Identidade anônima: o SDK mantém um anonymous_id persistente e um " +
                "session_id rotativo. Eles viajam no bloco identity de cada " +
                "evento e não são expostos pela API pública; logout() limpa o user_id " +
                "e os eventos voltam a ser anônimos."
        )
        label(
            "Rede: com o collectorUrl padrão inalcançável/offline os POSTs falham sem " +
                "quebrar nada — os eventos aguardam na fila JSONL e o backoff " +
                "exponencial reenvia no próximo track/foreground/rede/flush."
        )
    }

    private fun renderRecovery(screen: RecoveryScreen): Unit = content("Recuperação de carrinho") {
        label("Link recebido:\n${screen.source}")
        label("As UTMs do link são capturadas mesmo com retorno null e seguem como context.utm nos eventos seguintes.")
        val payload = screen.payload
        if (payload == null) {
            label("Flowbiz.handleLink devolveu null — o link não carrega um _mb_cr_ decodificável.", bold = true)
        } else {
            label("RecoveryPayload:", bold = true)
            label("cartId: ${payload.cartId}\nuserId: ${payload.userId}")
            payload.products.forEach { product ->
                label("• ${product.quantity}× ${product.productId} / ${product.sku}" +
                    (product.recoveryProperties?.let { " $it" } ?: ""))
            }
            action("Restaurar carrinho") {
                DemoCart.restore(payload)
                Flowbiz.track(Event.CartSync(DemoCart.toCart()))
                show(CartScreen)
            }
        }
        action("Voltar à loja") { show(ProductListScreen) }
    }

    private fun simulatePush() {
        // What FirebaseMessagingService.onMessageReceived hands over: a flat
        // map whose "flowbiz" value is a JSON-encoded string.
        val payload = mapOf("flowbiz" to SIMULATED_PUSH_MARKER)
        val push = Flowbiz.handlePush(payload)
        if (push == null) {
            dialog("handlePush", "null — payload não é do Flowbiz")
            return
        }
        // A cart-recovery push carries _mb_cr_ in its deep_link.
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
        val openRecovery: (Pair<String, () -> Unit>)? = push.deepLink?.let { deepLink ->
            "Abrir notificação" to {
                val opened = Flowbiz.handlePushOpened(push)
                show(RecoveryScreen("push deep_link: $deepLink", opened))
            }
        }
        dialog("Push simulado", message, openRecovery)
    }

    private fun simulateRecoveryLink() {
        // Decodes to cart-abc-001 / user-123 / P100 + P200 — no adb needed.
        val uri = Uri.parse(DEMO_RECOVERY_LINK)
        val payload = Flowbiz.handleLink(uri)
        show(RecoveryScreen(uri.toString(), payload))
    }

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

        /** "basic" vector from shared/recovery-links/vectors.json. */
        const val RECOVERY_HASH =
            "eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19"

        /** A journey cart-recovery link as MessageBuilder writes it: UTMs appended raw, `|` included. */
        const val DEMO_RECOVERY_LINK = "flowbizdemo://recover?_mb_cr_=$RECOVERY_HASH" +
            "&utm_journey=16&utm_journey_channel=email&utm_source=flowbiz&utm_medium=email" +
            "&utm_campaign=jornadas|cart|carrinho-abandonado&utm_journey_type=1"

        /** Marker value from shared/push-samples/samples.json. */
        const val SIMULATED_PUSH_MARKER =
            """{"v":1,"type":"cart_recovery","title":"Sua sacola te espera!","body":"Finalize sua compra...","deep_link":"https://store.com/carrinho?utm_source=flowbiz&_mb_cr_=eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCIsIntcImNvclwiOlwiQXp1bFwiLFwidGFtYW5ob1wiOlwiUFwifSJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19","data":{"campaign_id":"cr-42"}}"""
    }
}
