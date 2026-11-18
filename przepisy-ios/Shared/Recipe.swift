import Foundation
import SwiftData

enum RecipeStatus: String, Codable {
    case pending      // czeka na przetworzenie
    case processing   // trwa pobieranie / przetwarzanie
    case ready        // gotowy przepis
    case failed       // błąd albo brak przepisu w opisie
}

/// Tekst przepisu w jednym języku (tłumaczenie). Liczby, jednostki i czasy są wspólne – tu tylko słowa.
/// Ten sam format ma wersja webowa (pole `translations` w kopii zapasowej).
struct RecipeText: Codable, Hashable {
    struct IngredientText: Codable, Hashable {
        var group: String = ""
        var name: String = ""
        var note: String = ""
    }
    var title: String = ""
    var summary: String = ""
    var servings: String = ""
    var prepTime: String = ""
    var cookTime: String = ""
    var ingredients: [IngredientText] = []
    var steps: [String] = []
    var tips: [String] = []
    var tags: [String] = []

    enum CodingKeys: String, CodingKey {
        case title, summary, servings, ingredients, steps, tips, tags
        case prepTime = "prep_time", cookTime = "cook_time"
    }

    init(title: String = "", summary: String = "", servings: String = "", prepTime: String = "", cookTime: String = "",
         ingredients: [IngredientText] = [], steps: [String] = [], tips: [String] = [], tags: [String] = []) {
        self.title = title; self.summary = summary; self.servings = servings
        self.prepTime = prepTime; self.cookTime = cookTime
        self.ingredients = ingredients; self.steps = steps; self.tips = tips; self.tags = tags
    }

    // Brakujące pola (np. starsze tłumaczenia bez czasów) nie psują odczytu
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        servings = try c.decodeIfPresent(String.self, forKey: .servings) ?? ""
        prepTime = try c.decodeIfPresent(String.self, forKey: .prepTime) ?? ""
        cookTime = try c.decodeIfPresent(String.self, forKey: .cookTime) ?? ""
        ingredients = try c.decodeIfPresent([IngredientText].self, forKey: .ingredients) ?? []
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        tips = try c.decodeIfPresent([String].self, forKey: .tips) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

/// Przepis gotowy do wyświetlenia w jednym języku.
struct LocalizedRecipe {
    var shownLanguage: String
    var title: String
    var summary: String
    var servings: String
    var prepTime: String
    var cookTime: String
    var ingredients: [Ingredient]
    var steps: [Step]
    var tips: [String]
    var tags: [String]
}

@Model
final class Recipe {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var statusRaw: String = RecipeStatus.pending.rawValue
    var errorMessage: String = ""

    // Przepis (w języku `language`)
    var language: String = "en"          // język, w którym przepis zapisano
    var sourceLanguage: String = ""      // język filmiku (do „Pokaż oryginał”)
    var title: String = ""
    var titleEdited: Bool = false        // nazwa zmieniona ręcznie – ponowne przetworzenie jej nie nadpisze
    var emoji: String = ""
    var summary: String = ""
    var servings: String = ""            // opis z filmiku, np. „blacha 25×35 cm”
    var servingsCount: Int = 1           // na ile porcji był przepis w filmiku
    var prepTime: String = ""
    var cookTime: String = ""
    var ingredients: [Ingredient] = []
    var steps: [Step] = []
    var tips: [String] = []
    var tags: [String] = []
    /// Tłumaczenia tekstu: [kod języka: RecipeText] zapisane jako JSON.
    var translationsData: Data? = nil

    // Użytkownika
    var notes: String = ""
    var favorite: Bool = false
    var portions: Int = 0                // wybrana liczba porcji (0 = jak w filmiku)
    var shoppingPortions: Int = 0        // > 0 = przepis jest na liście zakupów, na tyle porcji
    var checked: [String] = []           // odhaczone składniki ("i3") i kroki ("s1")

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

    // MARK: - Języki

    var translations: [String: RecipeText] {
        get { translationsData.flatMap { try? JSONDecoder().decode([String: RecipeText].self, from: $0) } ?? [:] }
        set { translationsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// Przepis w zapisanym języku.
    var base: LocalizedRecipe {
        LocalizedRecipe(shownLanguage: language, title: title, summary: summary, servings: servings,
                        prepTime: prepTime, cookTime: cookTime, ingredients: ingredients, steps: steps,
                        tips: tips, tags: tags)
    }

    /// Przepis w danym języku: zapisany albo z tłumaczenia; nil, gdy tłumaczenia jeszcze nie ma.
    func text(in lang: String) -> LocalizedRecipe? {
        if lang == language { return base }
        guard let tr = translations[lang] else { return nil }
        var out = base
        out.shownLanguage = lang
        if !tr.title.isEmpty { out.title = tr.title }
        out.summary = tr.summary
        out.servings = tr.servings
        if !tr.prepTime.isEmpty { out.prepTime = tr.prepTime }
        if !tr.cookTime.isEmpty { out.cookTime = tr.cookTime }
        out.tips = tr.tips
        out.tags = tr.tags
        out.ingredients = ingredients.enumerated().map { k, i in
            var i = i
            if k < tr.ingredients.count {
                let t = tr.ingredients[k]
                i.group = t.group
                if !t.name.isEmpty { i.name = t.name }
                i.note = t.note
            }
            return i
        }
        out.steps = steps.enumerated().map { k, s in
            Step(text: k < tr.steps.count && !tr.steps[k].isEmpty ? tr.steps[k] : s.text, minutes: s.minutes)
        }
        return out
    }

    /// Przepis w języku użytkownika – albo w zapisanym języku, jeśli tłumaczenia jeszcze nie ma.
    var localized: LocalizedRecipe { text(in: L.recipeLang) ?? base }

    /// Składniki ze wszystkimi nazwami (zapisaną i z tłumaczeń) – do podpowiadania działu sklepu.
    var ingredientsInAllLanguages: [Ingredient] {
        var out = ingredients
        for lang in translations.keys {
            if let t = text(in: lang) { out += t.ingredients }
        }
        return out
    }

    /// Tekst do tłumaczenia (bez liczb – te się nie zmieniają).
    var translatableText: RecipeText {
        RecipeText(title: title, summary: summary, servings: servings, prepTime: prepTime, cookTime: cookTime,
                   ingredients: ingredients.map { .init(group: $0.group, name: $0.name, note: $0.note) },
                   steps: steps.map(\.text), tips: tips, tags: tags)
    }

    // MARK: - Wyświetlanie

    var displayTitle: String {
        let t = localized.title
        if !t.isEmpty { return t }
        if let provisional = Self.provisionalTitle(from: originalDescription) { return provisional }
        if !author.isEmpty { return L.t("recipe.videoBy", ["author": L.isolate(author)]) }
        return L.t("recipe.new")
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

    /// Liczba porcji do pokazania: wybrana przez użytkownika albo ta z filmiku.
    var displayPortions: Int { portions > 0 ? portions : max(servingsCount, 1) }

    func isChecked(_ key: String) -> Bool { checked.contains(key) }

    func toggleChecked(_ key: String) {
        if let i = checked.firstIndex(of: key) { checked.remove(at: i) } else { checked.append(key) }
    }

    /// Wyszukiwanie we wszystkich językach przepisu.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        var parts = [title, summary, author] + tags + ingredients.map(\.name)
        for tr in translations.values {
            parts += [tr.title, tr.summary] + tr.tags + tr.ingredients.map(\.name)
        }
        let hay = parts.joined(separator: " ")
        // bez względu na wielkość liter, akcenty i szerokość znaków (np. „sol” znajdzie „sól”, ＫＩＭＣＨＩ = kimchi)
        return q.split(separator: " ").allSatisfy { hay.localizedStandardContains(String($0)) }
    }

    /// Tekst przepisu do udostępnienia (Wiadomości, Notatki itd.) – w języku, w którym jest wyświetlany.
    func shareText(_ r: LocalizedRecipe) -> String {
        var out = "\(r.title.isEmpty ? displayTitle : r.title)\n"
        if !r.summary.isEmpty { out += "\(r.summary)\n" }
        let facts = [L.portions(displayPortions),
                     r.prepTime.isEmpty ? "" : L.t("recipe.prep", ["t": r.prepTime]),
                     r.cookTime.isEmpty ? "" : L.t("recipe.cook", ["t": r.cookTime])]
            .filter { !$0.isEmpty }
        out += facts.joined(separator: " · ") + "\n"
        let ui = Locale(identifier: L.lang)
        out += "\n\(L.t("recipe.ingredients").uppercased(with: ui))\n"
        var lastGroup = ""
        for i in r.ingredients {
            if !i.group.isEmpty && i.group != lastGroup { out += "\n\(i.group):\n"; lastGroup = i.group }
            let amount = i.amount(portions: displayPortions)
            out += "• \(i.name)\(amount.isEmpty ? "" : " – \(amount)")\n"
        }
        out += "\n\(L.t("recipe.steps").uppercased(with: ui))\n"
        for (n, s) in r.steps.enumerated() { out += "\(n + 1). \(s.text)\n" }
        if !r.tips.isEmpty {
            out += "\n\(L.t("recipe.tips").uppercased(with: ui))\n"
            for t in r.tips { out += "• \(t)\n" }
        }
        if !sourceURL.isEmpty { out += "\n\(L.t("recipe.source")): \(sourceURL)\n" }
        return out
    }
}
