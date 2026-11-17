import Foundation

/// Składnik. Ilość jest zapisana na 1 porcję – wystarczy pomnożyć przez liczbę porcji.
struct Ingredient: Codable, Hashable {
    var group: String = ""
    var name: String = ""
    var unit: String = ""
    var note: String = ""        // np. „do smaku”, „opcjonalnie”
    var category: String = "Inne"
    var perPortion: Double = 0   // 0 = bez ilości liczbowej

    func amount(portions: Int) -> String {
        [Kitchen.formatAmount(perPortion * Double(portions), unit: unit), note]
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
    /// Działy sklepu – w tej kolejności pokazuje je lista zakupów. Ta sama lista jest w schemacie dla Claude.
    static let categories = [
        "Warzywa i owoce", "Mięso i ryby", "Nabiał i jajka", "Pieczywo", "Makarony, ryż i kasze",
        "Mąka i pieczenie", "Przyprawy i sosy", "Konserwy i słoiki", "Mrożonki", "Napoje", "Inne",
    ]

    // Odmiana jednostek: [1, 2-4, 5+, ułamek]
    private static let forms: [String: [String]] = [
        "łyżka": ["łyżka", "łyżki", "łyżek", "łyżki"],
        "łyżeczka": ["łyżeczka", "łyżeczki", "łyżeczek", "łyżeczki"],
        "szklanka": ["szklanka", "szklanki", "szklanek", "szklanki"],
        "ząbek": ["ząbek", "ząbki", "ząbków", "ząbka"],
        "szczypta": ["szczypta", "szczypty", "szczypt", "szczypty"],
        "pęczek": ["pęczek", "pęczki", "pęczków", "pęczka"],
        "opakowanie": ["opakowanie", "opakowania", "opakowań", "opakowania"],
        "plaster": ["plaster", "plastry", "plastrów", "plastra"],
        "puszka": ["puszka", "puszki", "puszek", "puszki"],
        "garść": ["garść", "garście", "garści", "garści"],
        "kostka": ["kostka", "kostki", "kostek", "kostki"],
        "słoik": ["słoik", "słoiki", "słoików", "słoika"],
    ]

    /// Polska odmiana liczebnika: 1 porcja, 2 porcje, 5 porcji.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if n == 1 { return one }
        let d = n % 10, t = n % 100
        return (2...4).contains(d) && !(12...14).contains(t) ? few : many
    }

    static func portionsLabel(_ n: Int) -> String {
        "\(n) \(plural(n, "porcja", "porcje", "porcji"))"
    }

    private static func unitForm(_ unit: String, _ n: Double) -> String {
        guard let f = forms[unit] else { return unit }
        if n != n.rounded() { return f[3] }
        let i = Int(n)
        if i == 1 { return f[0] }
        return plural(i, f[0], f[1], f[2])
    }

    private static func decimal(_ n: Double, digits: Int = 1) -> String {
        let p = pow(10, Double(digits))
        let r = (n * p).rounded() / p
        var s = r == r.rounded() ? String(Int(r)) : String(r)
        s = s.replacingOccurrences(of: ".", with: ",")
        return s
    }

    /// Ładnie zaokrąglona ilość z jednostką, np. (1250, "g") → "1,25 kg", (1.5, "łyżka") → "1½ łyżki".
    static func formatAmount(_ value: Double, unit rawUnit: String) -> String {
        guard value > 0 else { return "" }
        let unit = rawUnit.trimmingCharacters(in: .whitespaces)

        if unit == "g" || unit == "ml" {
            if value >= 1000 { return "\(decimal(value / 1000, digits: 2)) \(unit == "g" ? "kg" : "l")" }
            let rounded = value >= 100 ? (value / 5).rounded() * 5 : value >= 10 ? value.rounded() : (value * 10).rounded() / 10
            return "\(decimal(rounded)) \(unit)"
        }

        // Sztuki, łyżki itp. – do ćwiartek, z ułamkami ¼ ½ ¾
        let text: String
        let n: Double
        if value < 0.125 {
            n = (value * 100).rounded() / 100
            text = decimal(n, digits: 2)
        } else {
            n = (value * 4).rounded() / 4
            let whole = Int(n.rounded(.down))
            let frac = ["", "¼", "½", "¾"][Int(((n - Double(whole)) * 4).rounded()) % 4]
            text = whole > 0 ? "\(whole)\(frac)" : frac
        }
        return unit.isEmpty ? text : "\(text) \(unitForm(unit, n))"
    }

    /// Czas minutnika jako tekst, np. 90 → "1:30", 3700 → "1:01:40".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%ld:%02ld:%02ld", h, m, s) : String(format: "%ld:%02ld", m, s)
    }

    static func minutesLabel(_ minutes: Double) -> String {
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let h = Int(minutes) / 60, m = Int(minutes.rounded()) % 60
        return m > 0 ? "\(h) h \(m) min" : "\(h) h"
    }

    // MARK: - Lista zakupów

    struct ShoppingItem: Identifiable {
        var key: String
        var name: String
        var amount: String
        var recipes: [String]
        var isExtra: Bool
        var id: String { key }
    }

    struct ShoppingGroup: Identifiable {
        var category: String
        var items: [ShoppingItem]
        var id: String { category }
    }

    private static func normName(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func extraKey(_ text: String) -> String { "extra|\(normName(text))" }

    /// Sumuje te same składniki (nazwa + jednostka) z wielu przepisów i grupuje je według działów sklepu.
    static func shoppingList(_ entries: [(title: String, ingredients: [Ingredient], portions: Int)],
                             extras: [String]) -> [ShoppingGroup] {
        struct Acc {
            var name: String, unit: String, qty: Double, notes: [String], category: String, recipes: [String], extra: Bool
        }
        var order: [String] = []
        var acc: [String: Acc] = [:]

        for entry in entries {
            for i in entry.ingredients where !i.name.isEmpty {
                let hasQty = i.perPortion > 0
                let key = "\(normName(i.name))|\(hasQty ? i.unit : "-")"
                var a = acc[key] ?? Acc(name: i.name, unit: i.unit, qty: 0, notes: [],
                                        category: categories.contains(i.category) ? i.category : "Inne",
                                        recipes: [], extra: false)
                if hasQty { a.qty += i.perPortion * Double(entry.portions) }
                else if !i.note.isEmpty && !a.notes.contains(i.note) { a.notes.append(i.note) }
                if !a.recipes.contains(entry.title) { a.recipes.append(entry.title) }
                if acc[key] == nil { order.append(key) }
                acc[key] = a
            }
        }
        for text in extras {
            let key = extraKey(text)
            if acc[key] == nil { order.append(key) }
            acc[key] = Acc(name: text, unit: "", qty: 0, notes: [], category: "Inne", recipes: [], extra: true)
        }

        return categories.compactMap { category in
            let items = order.compactMap { key -> ShoppingItem? in
                guard let a = acc[key], a.category == category else { return nil }
                let amount = ([formatAmount(a.qty, unit: a.unit)] + a.notes).filter { !$0.isEmpty }.joined(separator: ", ")
                return ShoppingItem(key: key, name: a.name, amount: amount, recipes: a.recipes, isExtra: a.extra)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            return items.isEmpty ? nil : ShoppingGroup(category: category, items: items)
        }
    }

    static func shoppingText(_ groups: [ShoppingGroup], checked: Set<String>) -> String {
        let body = groups.compactMap { g -> String? in
            let items = g.items.filter { !checked.contains($0.key) }
            guard !items.isEmpty else { return nil }
            return "\(g.category):\n" + items.map { "• \($0.name)\($0.amount.isEmpty ? "" : " – \($0.amount)")" }.joined(separator: "\n")
        }
        return "Lista zakupów\n\n" + body.joined(separator: "\n\n")
    }
}
