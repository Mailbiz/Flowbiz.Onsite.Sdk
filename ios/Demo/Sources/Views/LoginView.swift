import SwiftUI
import FlowbizOnsite

/// Login screen with a fake user: `account.login`, `account.sync`, `logout`.
/// Mirrors the Android demo 1:1.
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
                    // SPEC §5 `account.login`: also stores user_id/email for the identity block.
                    Flowbiz.track(.accountLogin(user: DemoStore.fakeUser))
                    store.loggedIn = true
                }
                Button("Sincronizar conta (account.sync)") {
                    // SPEC §5 `account.sync`: same payload, distinct wire event.
                    Flowbiz.track(.accountSync(user: DemoStore.fakeUser))
                }
                Button("Sair (logout)", role: .destructive) {
                    // SPEC §6: clears identity, rotates session, auto-emits push.token.remove (§10.1).
                    Flowbiz.logout()
                    store.loggedIn = false
                }
            }
            Section(footer: Text(
                "Após login/sync o SDK grava user_id/email e todos os eventos passam a " +
                "carregar identity.user_id (SPEC §5/§6). logout() limpa a identidade e " +
                "rotaciona a sessão."
            )) {
                EmptyView()
            }
        }
        .navigationTitle("Login")
        .onAppear {
            // SPEC §5 `page.view`: tracked on every screen change.
            Flowbiz.track(.pageView(path: "/login", title: "Login"))
        }
    }
}
