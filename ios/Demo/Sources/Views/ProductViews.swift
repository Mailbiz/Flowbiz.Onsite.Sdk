import SwiftUI
import FlowbizOnsite

/// Product list — the store's home screen.
struct ProductListView: View {

    @EnvironmentObject var store: DemoStore

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Produtos")) {
                    ForEach(store.catalog) { product in
                        NavigationLink(destination: ProductDetailView(product: product)) {
                            VStack(alignment: .leading) {
                                Text(product.name).font(.headline)
                                Text("\(product.brand) — R$ \(product.price, specifier: "%.2f")")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink("Carrinho (\(store.itemCount))", destination: CartView())
                    NavigationLink("Login", destination: LoginView())
                    NavigationLink("Ajustes / Debug", destination: SettingsView())
                }
                Section(footer: Text(
                    "Loja fake de demonstração do Flowbiz Onsite SDK. Offline? Tudo bem: " +
                    "os eventos ficam numa fila em disco e são reenviados com backoff " +
                    "exponencial. Logs: os_log categoria FlowbizOnsite."
                )) {
                    EmptyView()
                }
            }
            .navigationTitle("Bela Moda Store")
            .onAppear {
                Flowbiz.track(.pageView(path: "/", title: "Produtos"))
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Product detail — tracks `product.view` on open, `cart.add` on add.
struct ProductDetailView: View {

    @EnvironmentObject var store: DemoStore
    let product: DemoProduct

    var body: some View {
        Form {
            Section {
                Text(product.name).font(.headline)
                Text("\(product.brand) • \(product.category)")
                Text("R$ \(product.price, specifier: "%.2f") (de R$ \(product.priceFrom, specifier: "%.2f"))")
                    .font(.headline)
                Text("SKU: \(product.sku)").font(.footnote)
            }
            Section {
                Button("Adicionar ao carrinho") {
                    store.add(product)
                    // cart.add carries only the added line, cart.sync the whole cart.
                    Flowbiz.track(.addToCart(products: [store.cartItem(product, quantity: 1)]))
                    Flowbiz.track(.cartSync(cart: store.cart()))
                }
                NavigationLink("Ir para o carrinho (\(store.itemCount))", destination: CartView())
            }
        }
        .navigationTitle(product.name)
        .onAppear {
            Flowbiz.track(.pageView(path: product.url, title: product.name))
            Flowbiz.track(.productView(product: store.sdkProduct(product)))
        }
    }
}
