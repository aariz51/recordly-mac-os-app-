import SwiftUI

@main
struct ReclipApp: App {
    var body: some Scene {
        WindowGroup("Reclip") {
            ContentView()
                .frame(minWidth: 460, minHeight: 360)
        }
        .windowResizability(.contentSize)
    }
}
