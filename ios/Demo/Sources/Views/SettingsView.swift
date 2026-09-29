import SwiftUI
import FlowbizOnsite

/// Settings/debug panel: opt-out switch, push-token relay, flush, logout,
/// simulated push and simulated recovery link.
struct SettingsView: View {

    @EnvironmentObject var store: DemoStore
    /// Demo-local mirror of the opt-out switch (the SDK persists the real state internally).
    @State private var trackingEnabled = true
    @State private var lastPushSummary: String?
    @State private var lastPush: FlowbizPush?

    var body: some View {
        Form {
            Section(header: Text("Consentimento")) {
                Toggle("Coleta habilitada (setEnabled)", isOn: $trackingEnabled)
                    .onChange(of: trackingEnabled) { enabled in
                        Flowbiz.setEnabled(enabled)
                    }
                Text("Gancho de consentimento LGPD/GDPR; o SDK persiste o estado real — o switch reflete só esta sessão do app.")
                    .font(.footnote)
            }
            Section(header: Text("Push")) {
                Button("setPushToken (token fake)") {
                    Flowbiz.setPushToken(DemoStore.fakePushToken)
                }
                Button("removePushToken") {
                    Flowbiz.removePushToken()
                }
                Button("Simular push") { simulatePush() }
                if let summary = lastPushSummary {
                    Text(summary).font(.system(.footnote, design: .monospaced))
                    if let push = lastPush {
                        Button("Abrir notificação") {
                            // Opening the notification is the click that captures its UTMs.
                            let opened = Flowbiz.handlePushOpened(push)
                            store.recovery = DemoStore.RecoveryResult(
                                source: "push deep_link: \(push.deepLink?.absoluteString ?? "-")",
                                payload: opened
                            )
                        }
                    }
                }
            }
            Section(header: Text("Fila e sessão")) {
                Button("flush (drena a fila)") {
                    Flowbiz.flush()
                }
                Button("logout", role: .destructive) {
                    Flowbiz.logout()
                    store.loggedIn = false
                }
                Button("Simular link de recuperação") { simulateRecoveryLink() }
            }
            Section(footer: Text(
                "Identidade anônima: o SDK mantém um anonymous_id persistente e um session_id " +
                "rotativo; eles viajam no bloco identity de cada evento e não são " +
                "expostos pela API pública — logout() limpa o user_id e os eventos voltam a " +
                "ser anônimos.\n\nRede: com o collectorUrl padrão inalcançável/offline os POSTs " +
                "falham sem quebrar nada — os eventos aguardam na fila JSONL e o backoff " +
                "exponencial reenvia no próximo track/foreground/rede/flush."
            )) {
                EmptyView()
            }
        }
        .navigationTitle("Ajustes / Debug")
        .onAppear {
            Flowbiz.track(.pageView(path: "/ajustes", title: "Ajustes"))
        }
    }

    private func simulatePush() {
        // The "flowbiz" marker as a JSON-encoded string, exactly what the
        // UNUserNotificationCenter delegate's userInfo would hand over.
        let payload: [AnyHashable: Any] = ["flowbiz": DemoStore.simulatedPushMarker]
        guard let push = Flowbiz.handlePush(payload) else {
            lastPushSummary = "handlePush → nil (não é um push Flowbiz)"
            lastPush = nil
            return
        }
        // A cart-recovery push carries _mb_cr_ in its deep_link.
        let recovery = push.recoveryPayload
        var summary = "FlowbizPush: v=\(push.version) type=\(push.type)\n"
        summary += "title=\(push.title ?? "-")\n"
        summary += "body=\(push.body ?? "-")\n"
        summary += "deepLink=\(push.deepLink?.absoluteString ?? "-")\n"
        summary += "data=\(push.data)\n"
        if let recovery {
            summary += "recoveryPayload: cart \(recovery.cartId), user \(recovery.userId), \(recovery.products.count) item(ns)"
        } else {
            summary += "recoveryPayload=nil"
        }
        lastPushSummary = summary
        lastPush = push
    }

    private func simulateRecoveryLink() {
        guard let url = URL(string: DemoStore.recoveryLink) else { return }
        // Exactly the call the onOpenURL deep-link path makes.
        store.recovery = DemoStore.RecoveryResult(source: url.absoluteString, payload: Flowbiz.handleLink(url))
    }
}
