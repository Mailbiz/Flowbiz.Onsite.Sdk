import SwiftUI
import UIKit
import FlowbizOnsite

// SwiftUI calls onOpenURL for a cold-launch link only after the first screen's onAppear (and its
// PageView); forwarding it here first lets that page view carry the link's UTMs.
final class DemoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        options.urlContexts.forEach { Flowbiz.handleLink($0.url) }
        options.userActivities.forEach { Flowbiz.handleLink($0.webpageURL) }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

@main
struct FlowbizDemoApp: App {

    @UIApplicationDelegateAdaptor(DemoAppDelegate.self) private var appDelegate
    @StateObject private var store = DemoStore()

    init() {
        // Initialize once, at launch.
        #if DEBUG
        let collectorUrl = "https://collector.stg.mbzlabs.me"
        #else
        let collectorUrl = "https://collector.mailbiz.one"
        #endif
        Flowbiz.initialize(FlowbizConfig(
            appId: "77777",
            baseUri: "https://www.belamodastore.com.br",
            collectorUrl: collectorUrl,
            debug: true,
            recoveryUrl: "https://www.belamodastore.com.br/carrinho"
        ))
    }

    var body: some Scene {
        WindowGroup {
            ProductListView()
                .environmentObject(store)
                .onOpenURL { url in
                    // Forward every incoming link, recovery or not: handleLink also captures its UTMs.
                    store.recovery = DemoStore.RecoveryResult(
                        source: url.absoluteString,
                        payload: Flowbiz.handleLink(url)
                    )
                }
                .sheet(item: $store.recovery) { result in
                    RecoveryView(result: result)
                        .environmentObject(store)
                }
        }
    }
}
