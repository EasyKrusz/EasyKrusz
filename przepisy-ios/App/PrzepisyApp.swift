import SwiftUI
import SwiftData

@main
struct PrzepisyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var context = SharedStore.newContext()
    @State private var seenExternalChange = SharedStore.lastExternalChange
    @State private var viewID = UUID()

    var body: some Scene {
        WindowGroup {
            RecipeListView()
                .id(viewID)
                .modelContext(context)
                .tint(Color.brand)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            // Rozszerzenie „Udostępnij” dodało coś do bazy – bierzemy świeży kontekst, żeby to zobaczyć.
            let latest = SharedStore.lastExternalChange
            if latest != seenExternalChange {
                seenExternalChange = latest
                context = SharedStore.newContext()
                viewID = UUID()
            }
            // Dokończ wpisy, których rozszerzenie nie zdążyło przetworzyć.
            let current = context
            Task { await RecipeImporter.processPending(in: current) }
        }
    }
}
