import SwiftUI

@main
struct RecipistaApp: App {
    init() {
        AdMobBootstrap.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
