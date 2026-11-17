import Foundation

/// Wynik przetwarzania opisu przez Claude (zgodny ze schematem JSON poniżej).
struct ParsedRecipe: Decodable {
    struct ParsedIngredient: Decodable {
        var group: String
        var name: String
        var quantity: Double      // na cały przepis (servings_count porcji)
        var unit: String
        var note: String
        var category: String
    }

    var is_recipe: Bool
    var title: String
    var emoji: String
    var summary: String
    var servings: String
    var servings_count: Int
    var prep_time: String
    var cook_time: String
    var ingredients: [ParsedIngredient]
    var steps: [Step]
    var tips: [String]
    var tags: [String]

    /// Ilości na 1 porcję – potem wystarczy je pomnożyć przez wybraną liczbę porcji.
    var perPortionIngredients: [Ingredient] {
        let count = Double(max(servings_count, 1))
        return ingredients.map { i in
            Ingredient(group: i.group, name: i.name,
                       unit: i.quantity > 0 ? i.unit : "",
                       note: i.note,
                       category: Kitchen.categories.contains(i.category) ? i.category : "Inne",
                       perPortion: i.quantity > 0 ? i.quantity / count : 0)
        }
    }
}

enum ClaudeError: LocalizedError {
    case missingKey
    case http(Int, String)
    case refusal
    case truncated
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Brak klucza API Anthropic. Dodaj go w Ustawieniach aplikacji."
        case .http(401, _): return "Nieprawidłowy klucz API Anthropic – sprawdź go w Ustawieniach."
        case .http(429, _): return "Za dużo zapytań do Claude – spróbuj za chwilę."
        case .http(let code, let msg): return "Błąd Claude API (\(code)): \(msg)"
        case .refusal: return "Model odmówił przetworzenia tego opisu."
        case .truncated: return "Odpowiedź modelu została ucięta – spróbuj ponownie."
        case .badResponse: return "Nieoczekiwana odpowiedź Claude API."
        }
    }
}

/// Wywołanie Claude API przez HTTP (dla Swifta nie ma oficjalnego SDK).
enum ClaudeService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let system = """
    Jesteś asystentem kulinarnym. Dostajesz opis (caption) filmiku z TikToka, czasem automatyczną transkrypcję tego, co mówi autor, i ewentualnie notatki użytkownika.
    Twoim zadaniem jest zamienić go w czytelny, kompletny przepis po polsku.

    Zasady:
    - Korzystaj ze wszystkich źródeł naraz. Transkrypcja pochodzi z automatycznego rozpoznawania mowy: popraw oczywiste przekłamania (np. podobnie brzmiące nazwy składników) i pomiń wtrącenia niezwiązane z gotowaniem.
    - Nazwa przepisu ma mówić, co to za danie (np. "Kremowe spaghetti z cukinią"), a nie powtarzać chwytliwy tytuł filmiku.
    - Pisz po polsku, nawet jeśli opis jest w innym języku (przetłumacz).
    - Usuń hashtagi, emoji, wzmianki (@), wezwania do obserwowania i inne śmieci z opisu.
    - Kroki przygotowania mają być konkretne i w kolejności wykonywania; jeden krok = jedna czynność lub krótka grupa czynności.
    - Zachowaj ilości z opisu, podając je jako liczby w polu quantity (np. "pół szklanki" → 0.5 + "szklanka", "1,5 kg" → 1500 + "g"). Zamień skróty typu "tbsp" na "łyżka", "tsp" na "łyżeczka", "cup" na "szklanka". Ilości mają odpowiadać servings_count porcjom – nie dziel ich sam.
    - Jeśli czegoś brakuje (np. kroków, a są tylko składniki), uzupełnij rozsądnie na podstawie wiedzy kulinarnej i zaznacz to w "tips" zdaniem zaczynającym się od "Uzupełnione:".
    - Nie wymyślaj czasu przygotowania, jeśli nie da się go sensownie oszacować - zostaw pusty tekst.
    - Jeśli ani opis, ani transkrypcja, ani notatki nie zawierają przepisu ani nazwy dania, ustaw is_recipe na false, a w summary krótko napisz, czego brakuje.
    """

    private static let schema: [String: Any] = {
        func str(_ d: String? = nil) -> [String: Any] {
            var s: [String: Any] = ["type": "string"]
            if let d { s["description"] = d }
            return s
        }
        func num(_ type: String, _ d: String) -> [String: Any] {
            ["type": type, "description": d]
        }
        func array(of items: [String: Any], _ d: String? = nil) -> [String: Any] {
            var a: [String: Any] = ["type": "array", "items": items]
            if let d { a["description"] = d }
            return a
        }
        func object(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "required": Array(props.keys).sorted(), "properties": props]
        }
        var category = str("Dział sklepu, w którym kupuje się ten składnik.")
        category["enum"] = Kitchen.categories
        let ingredient = object([
            "group": str("Sekcja, np. 'Ciasto', 'Sos'. Pusty, jeśli przepis nie ma sekcji."),
            "name": str("Nazwa składnika w mianowniku, np. 'cebula', 'mąka pszenna'."),
            "quantity": num("number", "Ilość na CAŁY przepis (na servings_count porcji), jako liczba. 0, jeśli nie da się jej podać (np. 'do smaku')."),
            "unit": str("Jedna z: g, ml, łyżka, łyżeczka, szklanka, szt., ząbek, szczypta, pęczek, opakowanie, plaster, puszka, garść, kostka, słoik. Kilogramy i litry przelicz na g i ml. Pusty, gdy quantity = 0."),
            "note": str("Dopisek, np. 'do smaku', 'opcjonalnie', 'pokrojona w kostkę'. Zwykle pusty."),
            "category": category,
        ])
        let step = object([
            "text": str(),
            "minutes": num("number", "Ile minut trwa czekanie w tym kroku (pieczenie, gotowanie, odpoczynek ciasta) – do minutnika. Dla zakresu podaj dolną granicę. 0, jeśli krok nie wymaga odmierzania czasu."),
        ])
        let isRecipe: [String: Any] = [
            "type": "boolean",
            "description": "Czy w opisie w ogóle jest przepis (lub dość informacji, by go odtworzyć).",
        ]
        return object([
            "is_recipe": isRecipe,
            "title": str("Krótka, naturalna nazwa dania po polsku (2-6 słów), bez emoji, cudzysłowów i nazwy autora."),
            "emoji": str("Jedno emoji najlepiej pasujące do dania, np. 🍝."),
            "summary": str("1-2 zdania o daniu."),
            "servings": str("Np. '4 porcje' albo 'blacha 25×35 cm (12 kawałków)'."),
            "servings_count": num("integer", "Na ile porcji są podane ilości składników. Jeśli nie podano, oszacuj (np. 400 g makaronu ≈ 4 porcje); dla ciast – liczba kawałków."),
            "prep_time": str("Np. '15 min'. Pusty, jeśli nieznane."),
            "cook_time": str("Np. '25 min'. Pusty, jeśli nieznane."),
            "ingredients": array(of: ingredient),
            "steps": array(of: step),
            "tips": array(of: str()),
            "tags": array(of: str(), "3-6 krótkich tagów, małymi literami."),
        ])
    }()

    static func buildRecipe(description: String, transcript: String, notes: String, author: String) async throws -> ParsedRecipe {
        guard let key = APIKeyStore.apiKey else { throw ClaudeError.missingKey }

        var parts: [String] = []
        if !author.isEmpty { parts.append("Autor filmiku: @\(author)") }
        parts.append("Opis filmiku:\n\"\"\"\n\(description.isEmpty ? "(brak)" : description)\n\"\"\"")
        if !transcript.isEmpty {
            parts.append("Transkrypcja mowy z filmiku (automatyczna, może zawierać błędy):\n\"\"\"\n\(transcript)\n\"\"\"")
        }
        if !notes.isEmpty { parts.append("Notatki użytkownika (np. przepisane z filmiku):\n\"\"\"\n\(notes)\n\"\"\"") }

        let format: [String: Any] = ["type": "json_schema", "schema": schema]
        let outputConfig: [String: Any] = ["effort": "low", "format": format]
        let messages: [[String: String]] = [["role": "user", "content": parts.joined(separator: "\n\n")]]
        let body: [String: Any] = [
            "model": AppConfig.model,
            "max_tokens": 16000,
            "system": system,
            "fallbacks": "default",
            "output_config": outputConfig,
            "messages": messages,
        ]

        var req = URLRequest(url: endpoint, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            throw ClaudeError.http(status, msg)
        }

        switch json["stop_reason"] as? String {
        case "refusal": throw ClaudeError.refusal
        case "max_tokens": throw ClaudeError.truncated
        default: break
        }

        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let parsed = try? JSONDecoder().decode(ParsedRecipe.self, from: Data(text.utf8)) else {
            throw ClaudeError.badResponse
        }
        return parsed
    }
}
