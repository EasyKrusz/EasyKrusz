import Foundation
import SwiftData

struct Ingredient: Codable, Hashable {
    var group: String
    var name: String
    var amount: String
}

enum RecipeStatus: String, Codable {
    case pending      // czeka na przetworzenie
    case processing   // trwa pobieranie / przetwarzanie
    case ready        // gotowy przepis
    case failed       // błąd albo brak przepisu w opisie
}

@Model
final class Recipe {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var statusRaw: String = RecipeStatus.pending.rawValue
    var errorMessage: String = ""

    // Przepis
    var title: String = ""
    var titleEdited: Bool = false   // nazwa zmieniona ręcznie – ponowne przetworzenie jej nie nadpisze
    var emoji: String = ""
    var summary: String = ""
    var servings: String = ""
    var prepTime: String = ""
    var cookTime: String = ""
    var ingredients: [Ingredient] = []
    var steps: [String] = []
    var tips: [String] = []
    var tags: [String] = []

    // Użytkownika
    var notes: String = ""
    var favorite: Bool = false
    var checked: [String] = []   // odhaczone składniki ("i3") i kroki ("s1")

    // Źródło
    var sourceURL: String = ""
    var author: String = ""
    var thumbnailURL: String = ""
    var originalDescription: String = ""
    var transcript: String = ""
    /// Przepisu nie było w opisie ani w napisach – aplikacja spróbuje rozpoznać mowę z filmiku.
    var needsSpeech: Bool = false
    /// Miniaturka zapisana na telefonie (linki TikToka wygasają po kilku dniach).
    @Attribute(.externalStorage) var thumbnailData: Data? = nil

    init(sourceURL: String = "", notes: String = "") {
        self.sourceURL = sourceURL
        self.notes = notes
    }

    var status: RecipeStatus {
        get { RecipeStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue; updatedAt = Date() }
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let provisional = Self.provisionalTitle(from: originalDescription) { return provisional }
        if !author.isEmpty { return "Filmik @\(author)" }
        return "Nowy przepis"
    }

    /// Tymczasowa nazwa, zanim Claude nada właściwą: pierwsze zdanie opisu bez hashtagów i emoji.
    static func provisionalTitle(from description: String) -> String? {
        let firstLine = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let withoutTags = firstLine.replacingOccurrences(of: #"[#@]\S+"#, with: "", options: .regularExpression)
        let withoutEmoji = String(withoutTags.unicodeScalars.filter { scalar in
            !scalar.properties.isEmojiPresentation && scalar.value != 0xFE0F && scalar.value != 0x200D
        })
        let cleaned = withoutEmoji.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard cleaned.count >= 3 else { return nil }
        return cleaned.count > 50 ? String(cleaned.prefix(50)) + "…" : cleaned
    }

    func isChecked(_ key: String) -> Bool { checked.contains(key) }

    func toggleChecked(_ key: String) {
        if let i = checked.firstIndex(of: key) { checked.remove(at: i) } else { checked.append(key) }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        let hay = ([title, summary, author] + tags + ingredients.map(\.name))
            .joined(separator: " ")
            .lowercased()
        return q.split(separator: " ").allSatisfy { hay.contains($0) }
    }

    /// Tekst przepisu do udostępnienia (Wiadomości, Notatki itd.)
    var shareText: String {
        var out = "\(displayTitle)\n"
        if !summary.isEmpty { out += "\(summary)\n" }
        let facts = [servings, prepTime.isEmpty ? "" : "przygotowanie: \(prepTime)", cookTime.isEmpty ? "" : "gotowanie: \(cookTime)"]
            .filter { !$0.isEmpty }
        if !facts.isEmpty { out += facts.joined(separator: " · ") + "\n" }
        out += "\nSKŁADNIKI\n"
        var lastGroup = ""
        for i in ingredients {
            if !i.group.isEmpty && i.group != lastGroup { out += "\n\(i.group):\n"; lastGroup = i.group }
            out += "• \(i.name)\(i.amount.isEmpty ? "" : " – \(i.amount)")\n"
        }
        out += "\nPRZYGOTOWANIE\n"
        for (n, s) in steps.enumerated() { out += "\(n + 1). \(s)\n" }
        if !tips.isEmpty {
            out += "\nWSKAZÓWKI\n"
            for t in tips { out += "• \(t)\n" }
        }
        if !sourceURL.isEmpty { out += "\nŹródło: \(sourceURL)\n" }
        return out
    }
}
