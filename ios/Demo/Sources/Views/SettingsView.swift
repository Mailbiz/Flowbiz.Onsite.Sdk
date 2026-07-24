import SwiftUI
import FlowbizOnsite

/// Settings/debug panel: opt-out switch, push-token relay, flush, logout,
/// simulated push (SPEC §10.2) and simulated recovery link (SPEC §11).
/// Mirrors the Android demo 1:1.
struct SettingsView: View {

    @EnvironmentObject var store: DemoStore
    /// Demo-local mirror of the opt-out switch (the SDK persists the real state internally).
    @State private var trackingEnabled = true
    @State private var lastPushSummary: String?
    @State private var lastPushRecovery: RecoveryPayload?

    var body: some View {
        Form {
            Section(header: Text("Consentimento (SPEC §12)")) {
                Toggle("Coleta habilitada (setEnabled)", isOn: $trackingEnabled)
                    .onChange(of: trackingEnabled) { enabled in
                        // SPEC §12 opt-out: persisted; disabled = drop events, stop heartbeat, no network.
                        Flowbiz.setEnabled(enabled)
                    }
                Text("Gancho de consentimento LGPD/GDPR; o SDK persiste o estado real — o switch reflete só esta sessão do app.")
                    .font(.footnote)
            }
            Section(header: Text("Push (SPEC §10)")) {
                Button("setPushToken (token fake)") {
                    // SPEC §10.1: emits push.token.sync through the normal queue/dedup pipeline.
                    Flowbiz.setPushToken(DemoStore.fakePushToken)
                }
                Button("removePushToken") {
                    // SPEC §10.1: emits push.token.remove with the stored token, then forgets it.
                    Flowbiz.removePushToken()
                }
                Button("Simular push (SPEC §10.2)") { simulatePush() }
                if let summary = lastPushSummary {
                    Text(summary).font(.system(.footnote, design: .monospaced))
                    if let recovery = lastPushRecovery {
                        Button("Abrir recuperação do push") {
                            store.recovery = DemoStore.RecoveryResult(source: "push deep_link", payload: recovery)
                        }
                    }
                }
            }
            Section(header: Text("Fila e sessão")) {
                Button("flush (drena a fila)") {
                    // SPEC §9: explicit flush is one of the queue retry triggers.
                    Flowbiz.flush()
                }
                Button("logout", role: .destructive) {
                    // SPEC §6: clears identity, rotates session, auto-emits push.token.remove.
                    Flowbiz.logout()
                    store.loggedIn = false
                }
                Button("Simular link de recuperação (SPEC §11)") { simulateRecoveryLink() }
            }
            Section(footer: Text(
                "Identidade anônima: o SDK mantém um anonymous_id persistente e um session_id " +
                "rotativo (SPEC §6); eles viajam no bloco identity de cada evento e não são " +
                "expostos pela API pública — logout() limpa o user_id e os eventos voltam a " +
                "ser anônimos.\n\nRede: com o collectorUrl padrão inalcançável/offline os POSTs " +
                "falham sem quebrar nada — os eventos aguardam na fila JSONL e o backoff " +
                "exponencial reenvia no próximo track/foreground/rede/flush (SPEC §9)."
            )) {
                EmptyView()
            }
        }
        .navigationTitle("Ajustes / Debug")
        .onAppear {
            // SPEC §5 `page.view`: tracked on every screen change.
            Flowbiz.track(.pageView(screenName: "settings"))
        }
    }

    private func simulatePush() {
        // Canned SPEC §10.2 payload — mirrors shared/push-samples/samples.json
        // ("cart_recovery_with_real_mb_recovery_deep_link"): the "flowbiz"
        // marker carrying a JSON-encoded string, exactly what the
        // UNUserNotificationCenter delegate's userInfo would hand over.
        let payload: [AnyHashable: Any] = ["flowbiz": DemoStore.simulatedPushMarker]
        // SPEC §10.3: pure parser; nil would mean "not a Flowbiz push".
        guard let push = Flowbiz.handlePush(payload) else {
            lastPushSummary = "handlePush → nil (não é um push Flowbiz)"
            lastPushRecovery = nil
            return
        }
        // SPEC §10.2: a cart-recovery push carries mb_recovery in deep_link,
        // decoded by the same §11 parser via recoveryPayload.
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
        lastPushRecovery = recovery
    }

    private func simulateRecoveryLink() {
        // Hash from shared/lzstring-vectors/vectors.json ("recovery_hash_basic"):
        // decodes to cart-abc-001 / user-123 / P100 + P200 — no push/link infra needed.
        guard let url = URL(string: "flowbizdemo://recover?mb_recovery=\(DemoStore.recoveryHash)") else { return }
        // SPEC §11: exactly the call the onOpenURL deep-link path uses.
        store.recovery = DemoStore.RecoveryResult(source: url.absoluteString, payload: Flowbiz.handleLink(url))
    }
}
