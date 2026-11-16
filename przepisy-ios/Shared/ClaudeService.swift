import Foundation

/// Wynik przetwarzania opisu przez Claude (zgodny ze schematem JSON poniżej).
struct ParsedRecipe: Decodable {
    var is_recipe: Bool
    var title: String
    var emoji: String
    var summary: String
    var servings: String
    var prep_time: String
    var cook_time: String
    var ingredients: [Ingredient]
    var steps: [String]
    var tips: [String]
    var tags: [String]
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
    - Zachowaj ilości i jednostki z opisu. Zamień skróty typu "tbsp" na "łyżka", "tsp" na "łyżeczka", "cup" na "szklanka", ale nie przeliczaj ilości.
    - Jeśli czegoś brakuje (np. kroków, a są tylko składniki), uzupełnij rozsądnie na podstawie wiedzy kulinarnej i zaznacz to w "tips" zdaniem zaczynającym się od "Uzupełnione:".
    - Nie wymyślaj czasu ani liczby porcji, jeśli nie da się ich sensownie oszacować - zostaw pusty tekst.
    - Jeśli ani opis, ani transkrypcja, ani notatki nie zawierają przepisu ani nazwy dania, ustaw is_recipe na false, a w summary krótko napisz, czego brakuje.
    """

    private static let schema: [String: Any] = {
        func str(_ d: String? = nil) -> [String: Any] {
            var s: [String: Any] = ["type": "string"]
            if let d { s["description"] = d }
            return s
        }
        func array(of items: [String: Any], _ d: String? = nil) -> [String: Any] {
            var a: [String: Any] = ["type": "array", "items": items]
            if let d { a["description"] = d }
            return a
        }
        let ingredientProps: [String: Any] = [
            "group": str("Sekcja, np. 'Ciasto', 'Sos'. Pusty, jeśli przepis nie ma sekcji."),
            "name": str(),
            "amount": str("Ilość z jednostką, np. '200 g'. Pusty, jeśli brak."),
        ]
        let ingredient: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["group", "name", "amount"],
            "properties": ingredientProps,
        ]
        let isRecipe: [String: Any] = [
            "type": "boolean",
            "description": "Czy w opisie w ogóle jest przepis (lub dość informacji, by go odtworzyć).",
        ]
        let props: [String: Any] = [
            "is_recipe": isRecipe,
            "title": str("Krótka, naturalna nazwa dania po polsku (2-6 słów), bez emoji, cudzysłowów i nazwy autora."),
            "emoji": str("Jedno emoji najlepiej pasujące do dania, np. 🍝."),
            "summary": str("1-2 zdania o daniu."),
            "servings": str("Np. '2 porcje'. Pusty, jeśli nieznane."),
            "prep_time": str("Np. '15 min'. Pusty, jeśli nieznane."),
            "cook_time": str("Np. '25 min'. Pusty, jeśli nieznane."),
            "ingredients": array(of: ingredient),
            "steps": array(of: str()),
            "tips": array(of: str()),
            "tags": array(of: str(), "3-6 krótkich tagów, małymi literami."),
        ]
        let required: [String] = ["is_recipe", "title", "emoji", "summary", "servings", "prep_time", "cook_time",
                                  "ingredients", "steps", "tips", "tags"]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": required,
            "properties": props,
        ]
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
