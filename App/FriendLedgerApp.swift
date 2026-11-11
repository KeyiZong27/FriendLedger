import SwiftUI

@main
struct FriendLedgerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LedgerStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
