import SwiftUI
import FlowbizOnsite

/// Cart screen: quantity updates, coupon, postal code, explicit sync and
/// the checkout entry point. Mirrors the Android demo 1:1.
struct CartView: View {

    @EnvironmentObject var store: DemoStore
    @State private var couponText = ""
    @State private var cepText = ""

    var body: some View {
        Form {
            Section(header: Text("Itens")) {
                if store.lines.isEmpty {
                    Text("Carrinho vazio.")
                }
                ForEach(store.lines) { line in
                    Stepper(
                        "\(line.product.name) — \(line.quantity)× R$ \(line.product.price, specifier: "%.2f")",
                        value: Binding(
                            get: { line.quantity },
                            set: { newValue in
                                store.setQuantity(sku: line.product.sku, quantity: newValue)
                                // SPEC §5 `cart.item.update`: quantity change for one line (0 removes it store-side).
                                Flowbiz.track(.cartItemUpdate(
                                    cartId: DemoStore.cartId,
                                    productId: line.product.productId,
                                    sku: line.product.sku,
                                    quantity: newValue
                                ))
                            }
                        ),
                        in: 0...99
                    )
                }
            }
            Section(header: Text("Cupom e frete")) {
                TextField("Cupom (ex.: BEMVINDA10)", text: $couponText)
                Button("Aplicar cupom") {
                    let coupon = couponText.trimmingCharacters(in: .whitespaces)
                    guard !coupon.isEmpty else { return }
                    store.coupon = coupon
                    // SPEC §5 `cart.setcoupon`.
                    Flowbiz.track(.cartSetCoupon(cartId: DemoStore.cartId, coupon: coupon))
                }
                TextField("CEP (ex.: 01310-100)", text: $cepText)
                Button("Calcular frete (CEP)") {
                    let cep = cepText.trimmingCharacters(in: .whitespaces)
                    guard !cep.isEmpty else { return }
                    store.postalCode = cep
                    // SPEC §5 `cart.setpostalcode`.
                    Flowbiz.track(.cartSetPostalCode(cartId: DemoStore.cartId, postalCode: cep))
                }
            }
            Section(header: Text("Totais")) {
                Text("Subtotal: R$ \(store.subtotal, specifier: "%.2f")")
                Text("Desconto: R$ \(store.discounts, specifier: "%.2f")")
                Text("Frete: R$ \(store.freight, specifier: "%.2f")")
                Text("Total: R$ \(store.total, specifier: "%.2f")").font(.headline)
            }
            Section {
                Button("Sincronizar carrinho (cart.sync)") {
                    // SPEC §5 `cart.sync` — an empty cart still sends (SPEC §7: emptying is signal).
                    Flowbiz.track(.cartSync(cart: store.cart()))
                }
                NavigationLink("Finalizar compra", destination: CheckoutView())
            }
        }
        .navigationTitle("Carrinho")
        .onAppear {
            couponText = store.coupon ?? ""
            cepText = store.postalCode ?? ""
            // SPEC §5 `page.view`: tracked on every screen change.
            Flowbiz.track(.pageView(path: "/carrinho", title: "Carrinho"))
        }
    }
}
