import Foundation
import SwiftData
import SwiftUI

/// Ustawienia wspólne dla aplikacji i rozszerzenia „Udostępnij” (wartości z Info.plist).
enum AppConfig {
    static let appGroup: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "group.pl.easykrusz.przepisy"

    static let keychainGroup: String? =
        Bundle.main.object(forInfoDictionaryKey: "KeychainGroup") as? String

    static let model = "claude-sonnet-5-5"
}

extension Color {
    /// Kolor marki aplikacji (pomidorowy).
    static let brand = Color(red: 0.91, green: 0.33, blue: 0.24)
}

/// Baza przepisów w kontenerze App Group, żeby rozszerzenie „Udostępnij” i aplikacja widziały te same dane.
enum SharedStore {
    static let container: ModelContainer = {
        let schema = Schema([Recipe.self])
        let config = ModelConfiguration(
            "Przepisy",
            schema: schema,
            groupContainer: .identifier(AppConfig.appGroup),
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not open the recipe database: \(error)")
        }
    }()

    static func newContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = true
        return context
    }

    // Znacznik „rozszerzenie coś zmieniło” – aplikacja sprawdza go po powrocie na pierwszy plan.
    private static let defaults = UserDefaults(suiteName: AppConfig.appGroup)
    private static let changeKey = "externalChange"

    static var lastExternalChange: Double {
        defaults?.double(forKey: changeKey) ?? 0
    }

    static func markExternalChange() {
        defaults?.set(Date().timeIntervalSince1970, forKey: changeKey)
    }
}
