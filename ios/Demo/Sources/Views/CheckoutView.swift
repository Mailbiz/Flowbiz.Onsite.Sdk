import SwiftUI
import FlowbizOnsite

struct CheckoutView: View {

    @EnvironmentObject var store: DemoStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var step = 1
    @State private var completedOrderId: String?

    private let stepNames = ["identificacao", "entrega", "pagamento"]

    var body: some View {
        Form {
            Section(header: Text("Etapa \(step)/\(stepNames.count) — \(stepNames[step - 1])")) {
                Text("Total: R$ \(store.total, specifier: "%.2f") — \(store.itemCount) item(ns)")
                if let orderId = completedOrderId {
                    Text("Pedido \(orderId) concluído — order.complete enfileirado.")
                        .font(.headline)
                } else if step < stepNames.count {
                    Button("Próxima etapa") {
                        step += 1
                        trackStep()
                    }
                } else {
                    Button("Concluir pedido (order.complete)") {
                        let orderId = "ord-\(Int(Date().timeIntervalSince1970))"
                        Flowbiz.track(.orderComplete(order: store.order(orderId: orderId)))
                        store.clear()
                        completedOrderId = orderId
                    }
                }
                if completedOrderId == nil {
                    Button("Cancelar pedido (order.cancel)", role: .destructive) {
                        Flowbiz.track(.orderCancel(orderId: nil, cartId: DemoStore.cartId))
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationTitle("Checkout")
        .onAppear {
            Flowbiz.track(.pageView(path: "/checkout", title: "Checkout"))
            trackStep()
        }
    }

    private func trackStep() {
        Flowbiz.track(.checkoutStep(checkout: Checkout(
            cartId: DemoStore.cartId,
            step: step,
            totalSteps: stepNames.count,
            stepName: stepNames[step - 1]
        )))
    }
}
