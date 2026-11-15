import SwiftUI

@main
struct StardustApp: App {
    init() {
        PaperTypography.registerBundledFonts()
        PaperMaterial.prewarm()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
