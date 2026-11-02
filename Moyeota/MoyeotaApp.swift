import SwiftUI

@main
struct MoyeotaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainActivity()
        }
    }
}
