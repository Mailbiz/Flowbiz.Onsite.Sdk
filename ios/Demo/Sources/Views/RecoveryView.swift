import SwiftUI
import FlowbizOnsite

/// Deep-link recovery sheet: renders the parsed `RecoveryPayload` (SPEC §11)
/// — or the nil case — and can restore the cart. Mirrors the Android demo 1:1.
struct RecoveryView: View {

    @EnvironmentObject var store: DemoStore
    @Environment(\.presentationMode) private var presentationMode
    let result: DemoStore.RecoveryResult

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Link recebido")) {
                    Text(result.source).font(.system(.footnote, design: .monospaced))
                }
                if let payload = result.payload {
                    Section(header: Text("RecoveryPayload (SPEC §11)")) {
                        Text("cartId: \(payload.cartId)")
                        Text("userId: \(payload.userId)")
                        ForEach(Array(payload.products.enumerated()), id: \.offset) { _, product in
                            Text("\(product.quantity)× \(product.productId) / \(product.sku)")
                                .font(.footnote)
                        }
                    }
                    Section {
                        Button("Restaurar carrinho") {
                            store.restore(payload)
                            // SPEC §5 `cart.sync`: snapshot after restoring the recovered items.
                            Flowbiz.track(.cartSync(cart: store.cart()))
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                } else {
                    Section {
                        Text("Flowbiz.handleLink devolveu nil — o link não carrega um mb_recovery decodificável (SPEC §11).")
                    }
                }
            }
            .navigationTitle("Recuperação")
            .toolbar {
                Button("Fechar") { presentationMode.wrappedValue.dismiss() }
            }
            .onAppear {
                // SPEC §5 `page.view`: tracked on every screen change.
                Flowbiz.track(.pageView(screenName: "recovery"))
            }
        }
    }
}
