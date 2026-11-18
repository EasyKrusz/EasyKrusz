import Foundation

/// Składnik. Ilość jest zapisana na 1 porcję – wystarczy pomnożyć przez liczbę porcji.
/// `unit` i `category` to stałe kody (np. "tbsp", "produce"), wspólne dla wszystkich języków.
struct Ingredient: Codable, Hashable {
    var group: String = ""
    var name: String = ""
    var unit: String = ""
    var note: String = ""        // np. „do smaku”, „opcjonalnie”
    var category: String = "other"
    var perPortion: Double = 0   // 0 = bez ilości liczbowej

    func amount(portions: Int, lang: String = L.lang) -> String {
        [Kitchen.formatAmount(perPortion * Double(portions), unit: unit, lang: lang), note]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// Krok przygotowania; `minutes` > 0 = czas do odmierzenia minutnikiem.
struct Step: Codable, Hashable {
    var text: String = ""
    var minutes: Double = 0
}

/// Wspólna logika kuchenna (taka sama jak w wersji webowej: public/kitchen.js).
enum Kitchen {
    /// Działy sklepu (kody) – w tej kolejności pokazuje je lista zakupów. Ta sama lista jest w schemacie dla Claude.
    static let categories = [
        "produce", "meat_fish", "dairy_eggs", "bakery", "pasta_grains", "baking",
        "spices_sauces", "canned", "frozen", "drinks", "other",
    ]

    private static let categoryLabels: [String: [String: String]] = [
        "produce": ["pl": "Warzywa i owoce", "de": "Obst & Gemüse", "en": "Fruit & vegetables"],
        "meat_fish": ["pl": "Mięso i ryby", "de": "Fleisch & Fisch", "en": "Meat & fish"],
        "dairy_eggs": ["pl": "Nabiał i jajka", "de": "Milchprodukte & Eier", "en": "Dairy & eggs"],
        "bakery": ["pl": "Pieczywo", "de": "Brot & Backwaren", "en": "Bakery"],
        "pasta_grains": ["pl": "Makarony, ryż i kasze", "de": "Nudeln, Reis & Getreide", "en": "Pasta, rice & grains"],
        "baking": ["pl": "Mąka i pieczenie", "de": "Mehl & Backzutaten", "en": "Baking"],
        "spices_sauces": ["pl": "Przyprawy i sosy", "de": "Gewürze & Soßen", "en": "Spices & sauces"],
        "canned": ["pl": "Konserwy i słoiki", "de": "Konserven & Gläser", "en": "Canned & jarred"],
        "frozen": ["pl": "Mrożonki", "de": "Tiefkühl", "en": "Frozen"],
        "drinks": ["pl": "Napoje", "de": "Getränke", "en": "Drinks"],
        "other": ["pl": "Inne", "de": "Sonstiges", "en": "Other"],
    ]

    /// Kody jednostek. Formy: pl [1, 2-4, 5+, ułamek], de/en [1 i mniej, więcej].
    static let units: [String: [String: [String]]] = [
        "g": ["pl": ["g"], "de": ["g"], "en": ["g"]],
        "ml": ["pl": ["ml"], "de": ["ml"], "en": ["ml"]],
        "tbsp": ["pl": ["łyżka", "łyżki", "łyżek", "łyżki"], "de": ["EL"], "en": ["tbsp"]],
        "tsp": ["pl": ["łyżeczka", "łyżeczki", "łyżeczek", "łyżeczki"], "de": ["TL"], "en": ["tsp"]],
        "cup": ["pl": ["szklanka", "szklanki", "szklanek", "szklanki"], "de": ["Tasse", "Tassen"], "en": ["cup", "cups"]],
        "pc": ["pl": ["szt."], "de": ["Stk."], "en": [""]],
        "clove": ["pl": ["ząbek", "ząbki", "ząbków", "ząbka"], "de": ["Zehe", "Zehen"], "en": ["clove", "cloves"]],
        "pinch": ["pl": ["szczypta", "szczypty", "szczypt", "szczypty"], "de": ["Prise", "Prisen"], "en": ["pinch", "pinches"]],
        "bunch": ["pl": ["pęczek", "pęczki", "pęczków", "pęczka"], "de": ["Bund"], "en": ["bunch", "bunches"]],
        "pack": ["pl": ["opakowanie", "opakowania", "opakowań", "opakowania"], "de": ["Packung", "Packungen"], "en": ["pack", "packs"]],
        "slice": ["pl": ["plaster", "plastry", "plastrów", "plastra"], "de": ["Scheibe", "Scheiben"], "en": ["slice", "slices"]],
        "can": ["pl": ["puszka", "puszki", "puszek", "puszki"], "de": ["Dose", "Dosen"], "en": ["can", "cans"]],
        "handful": ["pl": ["garść", "garście", "garści", "garści"], "de": ["Handvoll"], "en": ["handful", "handfuls"]],
        "cube": ["pl": ["kostka", "kostki", "kostek", "kostki"], "de": ["Würfel"], "en": ["cube", "cubes"]],
        "jar": ["pl": ["słoik", "słoiki", "słoików", "słoika"], "de": ["Glas", "Gläser"], "en": ["jar", "jars"]],
    ]

    // Plik kopii z wersji webowej sprzed wielojęzyczności może mieć polskie słowa zamiast kodów
    private static let legacyUnits: [String: String] = [
        "łyżka": "tbsp", "łyżeczka": "tsp", "szklanka": "cup", "szt.": "pc", "szt": "pc", "ząbek": "clove",
        "szczypta": "pinch", "pęczek": "bunch", "opakowanie": "pack", "plaster": "slice", "puszka": "can",
        "garść": "handful", "kostka": "cube", "słoik": "jar",
    ]

    static func unitCode(_ u: String) -> String {
        let t = u.trimmingCharacters(in: .whitespaces)
        return units[t] != nil ? t : legacyUnits[t] ?? t
    }

    static func categoryCode(_ c: String) -> String {
        if categoryLabels[c] != nil { return c }
        return categoryLabels.first { $0.value["pl"] == c }?.key ?? "other"
    }

    static func categoryLabel(_ code: String, lang: String = L.lang) -> String {
        let labels = categoryLabels[categoryCode(code)] ?? categoryLabels["other"]!
        return labels[lang] ?? labels["en"]!
    }

    private static func unitForm(_ unit: String, _ n: Double, lang: String) -> String {
        guard let byLang = units[unit] else { return unit }   // nieznana jednostka – pokazujemy, jak przyszła
        let f = byLang[L.supported.contains(lang) ? lang : "en"]!
        if f.count == 1 { return f[0] }
        if lang == "pl" {
            if n != n.rounded() { return f[3] }
            let i = Int(n)
            if i == 1 { return f[0] }
            let d = i % 10, t = i % 100
            return (2...4).contains(d) && !(12...14).contains(t) ? f[1] : f[2]
        }
        return n <= 1 ? f[0] : f[1]
    }

    private static func decimal(_ n: Double, digits: Int, lang: String) -> String {
        let p = pow(10, Double(digits))
        let r = (n * p).rounded() / p
        let s = r == r.rounded() ? String(Int(r)) : String(r)
        return lang == "en" ? s : s.replacingOccurrences(of: ".", with: ",")
    }

    /// Ładnie zaokrąglona ilość z jednostką, np. (1250, "g", "pl") → "1,25 kg", (1.5, "tbsp", "pl") → "1½ łyżki".
    static func formatAmount(_ value: Double, unit rawUnit: String, lang: String = L.lang) -> String {
        guard value > 0 else { return "" }
        let unit = unitCode(rawUnit)

        if unit == "g" || unit == "ml" {
            if value >= 1000 { return "\(decimal(value / 1000, digits: 2, lang: lang)) \(unit == "g" ? "kg" : "l")" }
            let rounded = value >= 100 ? (value / 5).rounded() * 5 : value >= 10 ? value.rounded() : (value * 10).rounded() / 10
            return "\(decimal(rounded, digits: 1, lang: lang)) \(unit)"
        }

        // Sztuki, łyżki itp. – do ćwiartek, z ułamkami ¼ ½ ¾
        let text: String
        let n: Double
        if value < 0.125 {
            n = (value * 100).rounded() / 100
            text = decimal(n, digits: 2, lang: lang)
        } else {
            n = (value * 4).rounded() / 4
            let whole = Int(n.rounded(.down))
            let frac = ["", "¼", "½", "¾"][Int(((n - Double(whole)) * 4).rounded()) % 4]
            text = whole > 0 ? "\(whole)\(frac)" : frac
        }
        let label = unit.isEmpty ? "" : unitForm(unit, n, lang: lang)
        return label.isEmpty ? text : "\(text) \(label)"
    }

    /// Czas minutnika jako tekst, np. 90 → "1:30", 3700 → "1:01:40".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%ld:%02ld:%02ld", h, m, s) : String(format: "%ld:%02ld", m, s)
    }

    static func minutesLabel(_ minutes: Double) -> String {
        if minutes < 60 { return L.t("time.min", ["n": "\(Int(minutes.rounded()))"]) }
        let h = Int(minutes) / 60, m = Int(minutes.rounded()) % 60
        return m > 0 ? L.t("time.hmin", ["h": "\(h)", "m": "\(m)"]) : L.t("time.h", ["h": "\(h)"])
    }

    // MARK: - Lista zakupów

    /// Pozycja dopisana ręcznie (np. sól, której zabrakło w domu).
    struct ExtraItem: Codable, Hashable, Identifiable {
        var id = UUID().uuidString
        var name: String
        var amount: String = ""
        var category: String = "other"
    }

    /// Ręczna zmiana pozycji wyliczonej z przepisów.
    struct ItemOverride: Codable, Hashable {
        var name: String?
        var amount: String?
        var removed = false
        var isEmpty: Bool { name == nil && amount == nil && !removed }
    }

    struct ShoppingItem: Identifiable {
        var key: String
        var name: String
        var amount: String
        var category: String
        var recipes: [String]
        var extraID: String?          // ustawione dla pozycji dopisanych ręcznie
        var edited = false
        var originalName = ""
        var originalAmount = ""
        var id: String { key }
        var isExtra: Bool { extraID != nil }
    }

    struct ShoppingGroup: Identifiable {
        var category: String
        var label: String
        var items: [ShoppingItem]
        var id: String { category }
    }

    static func normName(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func extraKey(_ id: String) -> String { "extra|\(id)" }

    /// Dział sklepu dla nazwy wpisanej ręcznie – podpowiedź na podstawie składników z zapisanych przepisów.
    static func guessCategory(_ name: String, from ingredients: [Ingredient]) -> String {
        let n = normName(name)
        guard !n.isEmpty else { return "other" }
        return ingredients.first { normName($0.name) == n }.map { categoryCode($0.category) } ?? "other"
    }

    /// Lista zakupów z przepisów i własnych pozycji. Te same składniki (nazwa + jednostka) są sumowane,
    /// ręczne zmiany (`overrides`) nakładane, a usunięte pozycje zwracane osobno, żeby dało się je przywrócić.
    static func shoppingList(_ entries: [(title: String, ingredients: [Ingredient], portions: Int)],
                             extras: [ExtraItem],
                             overrides: [String: ItemOverride],
                             lang: String = L.lang) -> (groups: [ShoppingGroup], removed: [ShoppingItem]) {
        struct Acc {
            var name: String, unit: String, qty: Double, notes: [String], category: String, recipes: [String]
        }
        var order: [String] = []
        var acc: [String: Acc] = [:]

        for entry in entries {
            for i in entry.ingredients where !i.name.isEmpty {
                let hasQty = i.perPortion > 0
                let unit = unitCode(i.unit)
                let key = "\(normName(i.name))|\(hasQty ? unit : "-")"
                var a = acc[key] ?? Acc(name: i.name, unit: unit, qty: 0, notes: [],
                                        category: categoryCode(i.category), recipes: [])
                if hasQty { a.qty += i.perPortion * Double(entry.portions) }
                else if !i.note.isEmpty && !a.notes.contains(i.note) { a.notes.append(i.note) }
                if !a.recipes.contains(entry.title) { a.recipes.append(entry.title) }
                if acc[key] == nil { order.append(key) }
                acc[key] = a
            }
        }

        var items: [ShoppingItem] = []
        var removed: [ShoppingItem] = []
        for key in order {
            guard let a = acc[key] else { continue }
            let amount = ([formatAmount(a.qty, unit: a.unit, lang: lang)] + a.notes).filter { !$0.isEmpty }.joined(separator: ", ")
            let o = overrides[key] ?? ItemOverride()
            let item = ShoppingItem(key: key, name: o.name ?? a.name, amount: o.amount ?? amount,
                                    category: a.category, recipes: a.recipes, extraID: nil,
                                    edited: o.name != nil || o.amount != nil,
                                    originalName: a.name, originalAmount: amount)
            if o.removed { removed.append(item) } else { items.append(item) }
        }
        for e in extras where !e.name.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(ShoppingItem(key: extraKey(e.id), name: e.name, amount: e.amount,
                                      category: categoryCode(e.category), recipes: [], extraID: e.id))
        }

        let locale = Locale(identifier: lang)
        let groups = categories.compactMap { category -> ShoppingGroup? in
            let inGroup = items.filter { $0.category == category }
                .sorted { $0.name.compare($1.name, locale: locale) == .orderedAscending }
            return inGroup.isEmpty ? nil : ShoppingGroup(category: category, label: categoryLabel(category, lang: lang), items: inGroup)
        }
        return (groups, removed)
    }

    static func shoppingText(_ groups: [ShoppingGroup], checked: Set<String>) -> String {
        let body = groups.compactMap { g -> String? in
            let items = g.items.filter { !checked.contains($0.key) }
            guard !items.isEmpty else { return nil }
            return "\(g.label):\n" + items.map { "• \($0.name)\($0.amount.isEmpty ? "" : " – \($0.amount)")" }.joined(separator: "\n")
        }
        return L.t("shop.title") + "\n\n" + body.joined(separator: "\n\n")
    }
}
