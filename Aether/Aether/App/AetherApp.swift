import SwiftUI

@main
struct AetherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
