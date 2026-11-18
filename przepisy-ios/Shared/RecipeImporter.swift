import Foundation
import SwiftData
import UIKit

/// Dodawanie i przetwarzanie przepisów. Wspólne dla aplikacji i rozszerzenia „Udostępnij”.
@MainActor
enum RecipeImporter {

    /// Tworzy wpis (status: pending) albo zwraca istniejący przepis z tego samego filmiku.
    static func enqueue(link: String?, notes: String, in context: ModelContext) -> (recipe: Recipe, duplicate: Bool) {
        let url = link.flatMap { TikTokService.extractURL(from: $0) } ?? ""
        if !url.isEmpty, let existing = findExisting(url: url, in: context) {
            return (existing, true)
        }
        let recipe = Recipe(sourceURL: url, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(recipe)
        try? context.save()
        return (recipe, false)
    }

    /// Pobiera dane filmiku i zamienia je w przepis. Kolejność źródeł:
    /// opis + automatyczne napisy TikToka (+ notatki), a jeśli to nie wystarczy – rozpoznawanie mowy na telefonie.
    /// `allowSpeech: false` (rozszerzenie „Udostępnij”) zostawia rozpoznawanie mowy aplikacji.
    static func process(_ recipe: Recipe, in context: ModelContext, allowSpeech: Bool = true) async {
        recipe.status = .processing
        recipe.errorMessage = ""
        try? context.save()

        do {
            // 1. Dane filmiku (raz – kolejne przetworzenia korzystają z zapisanych)
            var video: TikTokVideo?
            let alreadyFetched = !recipe.originalDescription.isEmpty || !recipe.transcript.isEmpty || !recipe.thumbnailURL.isEmpty
            if !recipe.sourceURL.isEmpty && !alreadyFetched {
                do {
                    let v = try await TikTokService.fetch(recipe.sourceURL)
                    video = v
                    recipe.sourceURL = v.url
                    recipe.originalDescription = v.description
                    recipe.transcript = v.transcript
                    recipe.author = v.author
                    recipe.thumbnailURL = v.thumbnail
                    try? context.save()
                } catch {
                    if recipe.notes.isEmpty { throw error }   // bez filmiku da się pracować tylko na notatkach
                }
            }
            if recipe.thumbnailData == nil && !recipe.thumbnailURL.isEmpty {
                recipe.thumbnailData = await downloadThumbnail(recipe.thumbnailURL)
                try? context.save()
            }

            // 2. Claude: opis + napisy + notatki (pomijamy, jeśli już wiadomo, że trzeba rozpoznać mowę)
            var parsed: ParsedRecipe?
            if !(recipe.needsSpeech && allowSpeech) {
                parsed = try await ask(recipe)
            }

            // 3. Brak przepisu i brak napisów → rozpoznawanie mowy z nagrania
            var speechProblem = ""
            let noRecipeYet = parsed.map { !$0.is_recipe } ?? true
            if noRecipeYet && recipe.transcript.isEmpty && !recipe.sourceURL.isEmpty {
                guard allowSpeech else {
                    recipe.needsSpeech = true
                    recipe.status = .pending
                    try? context.save()
                    return
                }
                do {
                    // Adres nagrania wygasa – po przerwie pobieramy go od nowa
                    let v: TikTokVideo
                    if let video { v = video } else { v = try await TikTokService.fetch(recipe.sourceURL) }
                    guard !v.videoURL.isEmpty else { throw SpeechError.noVideo }
                    recipe.transcript = try await SpeechTranscriber.transcribe(videoURL: v.videoURL, languageHint: v.language)
                    try? context.save()
                    parsed = try await ask(recipe)
                } catch {
                    speechProblem = error.localizedDescription
                }
            }
            recipe.needsSpeech = false

            guard let parsed, parsed.is_recipe else {
                recipe.status = .failed
                var msg = L.t("import.noRecipe")
                if let summary = parsed?.summary, !summary.isEmpty { msg += " \(summary)" }
                if !speechProblem.isEmpty { msg += "\n\n\(speechProblem)" }
                msg += "\n\n" + L.t("import.addNotes")
                recipe.errorMessage = msg
                try? context.save()
                return
            }

            apply(parsed, to: recipe)
            recipe.status = .ready
        } catch {
            recipe.status = .failed
            recipe.errorMessage = error.localizedDescription
        }
        try? context.save()
    }

    /// Dokańcza wpisy dodane z rozszerzenia (niedokończone albo czekające na rozpoznanie mowy).
    static func processPending(in context: ModelContext) async {
        guard let all = try? context.fetch(FetchDescriptor<Recipe>()) else { return }
        let staleProcessing = Date().addingTimeInterval(-120)
        let waiting = all.filter {
            $0.status == .pending || ($0.status == .processing && $0.updatedAt < staleProcessing)
        }
        for recipe in waiting {
            await process(recipe, in: context)
        }
    }

    // MARK: - Pomocnicze

    /// Przepis zawsze powstaje w języku użytkownika (z ustawień aplikacji albo telefonu).
    private static func ask(_ recipe: Recipe) async throws -> ParsedRecipe {
        try await ClaudeService.buildRecipe(
            description: recipe.originalDescription,
            transcript: recipe.transcript,
            notes: recipe.notes,
            author: recipe.author,
            language: L.recipeLang
        )
    }

    /// Tłumaczy tekst przepisu (np. „Pokaż oryginał” albo przepis z kopii w innym języku) i zapamiętuje tłumaczenie.
    static func translate(_ recipe: Recipe, to lang: String, in context: ModelContext) async throws {
        guard lang != recipe.language, recipe.translations[lang] == nil else { return }
        let translated = try await ClaudeService.translate(recipe.translatableText, to: lang)
        var all = recipe.translations
        all[lang] = translated
        recipe.translations = all
        try? context.save()
    }

    private static func apply(_ parsed: ParsedRecipe, to recipe: Recipe) {
        let lang = L.recipeLang
        if !recipe.titleEdited || recipe.language != lang { recipe.title = parsed.title }
        recipe.language = lang
        recipe.sourceLanguage = parsed.source_language.isEmpty ? "" : L.normalizeTag(parsed.source_language)
        recipe.translations = [:]   // tekst się zmienił – stare tłumaczenia są nieaktualne
        recipe.emoji = parsed.emoji
        recipe.summary = parsed.summary
        recipe.servings = parsed.servings
        recipe.servingsCount = max(parsed.servings_count, 1)
        recipe.prepTime = parsed.prep_time
        recipe.cookTime = parsed.cook_time
        recipe.ingredients = parsed.perPortionIngredients
        recipe.steps = parsed.steps
        recipe.tips = parsed.tips
        recipe.tags = parsed.tags
        recipe.checked = []
    }

    /// Pobiera miniaturkę i zapisuje ją pomniejszoną (ok. 600 px), bo linki TikToka wygasają.
    private static func downloadThumbnail(_ url: String) async -> Data? {
        guard let (data, _) = try? await TikTokService.download(url),
              let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 600
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = await image.byPreparingThumbnail(ofSize: size) ?? image
        return resized.jpegData(compressionQuality: 0.8)
    }

    private static func findExisting(url: String, in context: ModelContext) -> Recipe? {
        let clean = URLComponents(string: url).map { c -> String in
            var c = c; c.query = nil; c.fragment = nil; return c.string ?? url
        } ?? url
        let descriptor = FetchDescriptor<Recipe>(predicate: #Predicate { $0.sourceURL == clean || $0.sourceURL == url })
        return try? context.fetch(descriptor).first
    }
}
