import SwiftUI

@main
struct AetherApp: App {
    /// Shared across phone IDE and AR workspace. Anything code-related lives here.
    @StateObject private var session = ProjectSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
