import Foundation

/// Wynik przetwarzania opisu przez Claude (zgodny ze schematem JSON poniżej).
struct ParsedRecipe: Decodable {
    struct ParsedIngredient: Decodable {
        var group: String
        var name: String
        var quantity: Double      // na cały przepis (servings_count porcji)
        var unit: String          // kod jednostki
        var note: String
        var category: String      // kod działu sklepu
    }

    var is_recipe: Bool
    var source_language: String
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
                       unit: i.quantity > 0 ? Kitchen.unitCode(i.unit) : "",
                       note: i.note,
                       category: Kitchen.categoryCode(i.category),
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
        case .missingKey: return L.t("err.missingKey")
        case .http(401, _): return L.t("err.badKey")
        case .http(429, _): return L.t("err.rateLimit")
        case .http(let code, let msg): return L.t("err.api", ["code": "\(code)", "msg": msg])
        case .refusal: return L.t("err.refusal")
        case .truncated: return L.t("err.truncated")
        case .badResponse: return L.t("err.badResponse")
        }
    }
}

/// Wywołanie Claude API przez HTTP (dla Swifta nie ma oficjalnego SDK).
enum ClaudeService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Nazwa języka po angielsku dla promptu, np. "ko" → "Korean".
    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private static func recipeSystem(_ lang: String) -> String {
        """
        You are a cooking assistant. You get the caption of a TikTok video, sometimes an automatic transcript of what the creator says, and sometimes notes from the user.
        Turn them into a clear, complete recipe.

        Rules:
        - Write ALL text (title, ingredient names, notes, steps, tips, tags, servings) in \(languageName(lang)), whatever language the video is in. Translate when needed.
        - Use all sources together. The transcript comes from automatic speech recognition: fix obvious mistakes (e.g. similar-sounding ingredient names) and skip chatter unrelated to cooking.
        - The title should say what the dish is (e.g. "Creamy zucchini spaghetti"), not repeat a catchy video title.
        - Remove hashtags, emoji, @mentions, calls to follow and similar noise.
        - Steps must be concrete and in the order they are done; one step = one action or a short group of actions.
        - Keep the quantities from the sources and give them as numbers in "quantity" (e.g. "half a cup" → 0.5 + "cup", "1.5 kg" → 1500 + "g"). Quantities must match servings_count servings – do not divide them yourself.
        - If something is missing (e.g. there are ingredients but no steps), fill it in sensibly from cooking knowledge and mention it in "tips".
        - Do not invent preparation times that cannot be reasonably estimated – leave them empty.
        - If none of the sources contain a recipe or the name of a dish, set is_recipe to false and briefly say in "summary" what is missing.
        """
    }

    // MARK: - Schematy JSON

    private static func str(_ d: String? = nil) -> [String: Any] {
        var s: [String: Any] = ["type": "string"]
        if let d { s["description"] = d }
        return s
    }
    private static func num(_ type: String, _ d: String) -> [String: Any] { ["type": type, "description": d] }
    private static func array(of items: [String: Any], _ d: String? = nil) -> [String: Any] {
        var a: [String: Any] = ["type": "array", "items": items]
        if let d { a["description"] = d }
        return a
    }
    private static func object(_ props: [String: Any]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "required": Array(props.keys).sorted(), "properties": props]
    }

    private static let recipeSchema: [String: Any] = {
        var category = str("Supermarket section where you buy it.")
        category["enum"] = Kitchen.categories
        var unit = str("Unit code. Convert kg → g and l → ml. Use 'pc' for countable items. Empty when quantity is 0.")
        unit["enum"] = Array(Kitchen.units.keys).sorted() + [""]
        let ingredient = object([
            "group": str("Section, e.g. 'Dough', 'Sauce'. Empty if the recipe has no sections."),
            "name": str("Ingredient name in its base form, e.g. 'onion', 'wheat flour'."),
            "quantity": num("number", "Quantity for the WHOLE recipe (servings_count servings) as a number. 0 if it cannot be given (e.g. 'to taste')."),
            "unit": unit,
            "note": str("Short remark, e.g. 'to taste', 'optional', 'diced'. Usually empty."),
            "category": category,
        ])
        let step = object([
            "text": str(),
            "minutes": num("number", "Minutes of waiting in this step (baking, simmering, resting dough) for a kitchen timer. Use the lower bound of a range. 0 if no timing is needed."),
        ])
        let isRecipe: [String: Any] = [
            "type": "boolean",
            "description": "Whether the sources contain a recipe (or enough information to reconstruct one).",
        ]
        return object([
            "is_recipe": isRecipe,
            "source_language": str("ISO 639-1 code of the language the video is in (caption/speech), e.g. 'ko', 'en', 'de'."),
            "title": str("Short, natural name of the dish (2-6 words), no emoji, quotes or author name."),
            "emoji": str("One emoji that best fits the dish, e.g. 🍝."),
            "summary": str("1-2 sentences about the dish."),
            "servings": str("E.g. '4 servings' or 'baking tray 25×35 cm (12 pieces)'."),
            "servings_count": num("integer", "How many servings the ingredient quantities are for. If not given, estimate (e.g. 400 g pasta ≈ 4); for cakes use the number of pieces."),
            "prep_time": str("E.g. '15 min'. Empty if unknown."),
            "cook_time": str("E.g. '25 min'. Empty if unknown."),
            "ingredients": array(of: ingredient),
            "steps": array(of: step),
            "tips": array(of: str()),
            "tags": array(of: str(), "3-6 short lowercase tags."),
        ])
    }()

    private static let translationSchema: [String: Any] = {
        let ingredient = object(["group": str(), "name": str(), "note": str()])
        return object([
            "title": str(), "summary": str(), "servings": str(), "prep_time": str(), "cook_time": str(),
            "ingredients": array(of: ingredient), "steps": array(of: str()),
            "tips": array(of: str()), "tags": array(of: str()),
        ])
    }()

    // MARK: - Wywołania

    /// Przepis w języku `language` (kod ISO, np. "de") z opisu, transkrypcji i notatek.
    static func buildRecipe(description: String, transcript: String, notes: String, author: String,
                            language: String) async throws -> ParsedRecipe {
        var parts: [String] = []
        if !author.isEmpty { parts.append("Video author: @\(author)") }
        parts.append("Video caption:\n\"\"\"\n\(description.isEmpty ? "(none)" : description)\n\"\"\"")
        if !transcript.isEmpty {
            parts.append("Transcript of the speech in the video (automatic, may contain errors):\n\"\"\"\n\(transcript)\n\"\"\"")
        }
        if !notes.isEmpty { parts.append("User notes (e.g. typed from the video):\n\"\"\"\n\(notes)\n\"\"\"") }

        let text = try await ask(system: recipeSystem(language), user: parts.joined(separator: "\n\n"), schema: recipeSchema)
        guard let parsed = try? JSONDecoder().decode(ParsedRecipe.self, from: Data(text.utf8)) else {
            throw ClaudeError.badResponse
        }
        return parsed
    }

    /// Tłumaczenie tekstu przepisu na `language`. Liczby, jednostki i kolejność pozycji się nie zmieniają.
    static func translate(_ source: RecipeText, to language: String) async throws -> RecipeText {
        let input = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        let text = try await ask(
            system: "You translate recipes into \(languageName(language)). Translate every text field naturally, as a native cook would write it. Keep the same number and order of ingredients, steps, tips and tags. Keep empty strings empty.",
            user: input,
            schema: translationSchema
        )
        guard let out = try? JSONDecoder().decode(RecipeText.self, from: Data(text.utf8)),
              out.ingredients.count == source.ingredients.count,
              out.steps.count == source.steps.count
        else { throw ClaudeError.badResponse }
        return out
    }

    private static func ask(system: String, user: String, schema: [String: Any]) async throws -> String {
        guard let key = APIKeyStore.apiKey else { throw ClaudeError.missingKey }

        let format: [String: Any] = ["type": "json_schema", "schema": schema]
        let outputConfig: [String: Any] = ["effort": "low", "format": format]
        let messages: [[String: String]] = [["role": "user", "content": user]]
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

        return (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }
}
