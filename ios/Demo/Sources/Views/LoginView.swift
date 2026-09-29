import SwiftUI
import FlowbizOnsite

/// Login screen with a fake user: `account.login`, `account.sync`, `logout`.
struct LoginView: View {

    @EnvironmentObject var store: DemoStore

    var body: some View {
        Form {
            Section(header: Text("Usuária fake")) {
                Text("\(DemoStore.fakeUser.name ?? "-") <\(DemoStore.fakeUser.email)>")
                Text(store.loggedIn ? "Logada" : "Anônima").font(.footnote)
            }
            Section {
                Button("Entrar (account.login)") {
                    Flowbiz.track(.accountLogin(user: DemoStore.fakeUser))
                    store.loggedIn = true
                }
                Button("Sincronizar conta (account.sync)") {
                    Flowbiz.track(.accountSync(user: DemoStore.fakeUser))
                }
                Button("Sair (logout)", role: .destructive) {
                    Flowbiz.logout()
                    store.loggedIn = false
                }
            }
            Section(footer: Text(
                "Após login/sync o SDK grava user_id/email e todos os eventos passam a " +
                "carregar identity.user_id. logout() limpa a identidade e " +
                "rotaciona a sessão."
            )) {
                EmptyView()
            }
        }
        .navigationTitle("Login")
        .onAppear {
            Flowbiz.track(.pageView(path: "/login", title: "Login"))
        }
    }
}
