import SwiftUI
import FlowbizOnsite

/// Deep-link recovery sheet: renders the parsed `RecoveryPayload` — or the
/// nil case — and can restore the cart.
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
                    Section(header: Text("RecoveryPayload")) {
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
                            Flowbiz.track(.cartSync(cart: store.cart()))
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                } else {
                    Section {
                        Text("Flowbiz.handleLink devolveu nil — o link não carrega um _mb_cr_ decodificável.")
                    }
                }
                Section(footer: Text(
                    "UTMs: handleLink e handlePushOpened capturam as UTMs de todo link recebido, com ou sem _mb_cr_; " +
                    "elas seguem como context.utm em todos os eventos seguintes."
                )) {
                    EmptyView()
                }
            }
            .navigationTitle("Recuperação")
            .toolbar {
                Button("Fechar") { presentationMode.wrappedValue.dismiss() }
            }
            .onAppear {
                Flowbiz.track(.pageView(path: "/carrinho/recuperar", title: "Recuperação"))
            }
        }
    }
}
