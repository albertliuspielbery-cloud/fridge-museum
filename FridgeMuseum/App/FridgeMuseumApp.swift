import SwiftData
import SwiftUI

@main
struct FridgeMuseumApp: App {
    @State private var appModel = AppModel()
    private let container: ModelContainer = ArchiveStore.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .fontDesign(.rounded)
                .tint(Palette.blue)
        }
        .modelContainer(container)
    }
}
