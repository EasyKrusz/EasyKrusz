import Foundation
import SwiftData

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

    /// Pobiera opis z TikToka i zamienia go w przepis. Błędy zapisuje w samym przepisie.
    static func process(_ recipe: Recipe, in context: ModelContext) async {
        recipe.status = .processing
        recipe.errorMessage = ""
        try? context.save()

        do {
            if !recipe.sourceURL.isEmpty && recipe.originalDescription.isEmpty {
                do {
                    let video = try await TikTokService.fetch(recipe.sourceURL)
                    recipe.sourceURL = video.url
                    recipe.originalDescription = video.description
                    recipe.author = video.author
                    recipe.thumbnailURL = video.thumbnail
                    try? context.save()
                } catch {
                    // Bez opisu da się dalej pracować tylko, jeśli są notatki
                    if recipe.notes.isEmpty { throw error }
                }
            }

            let parsed = try await ClaudeService.buildRecipe(
                description: recipe.originalDescription,
                notes: recipe.notes,
                author: recipe.author
            )

            guard parsed.is_recipe else {
                recipe.status = .failed
                recipe.errorMessage = "W opisie nie ma przepisu. \(parsed.summary) Często przepis jest tylko mówiony w filmiku – wpisz go w notatkach i przetwórz ponownie."
                try? context.save()
                return
            }

            recipe.title = parsed.title
            recipe.summary = parsed.summary
            recipe.servings = parsed.servings
            recipe.prepTime = parsed.prep_time
            recipe.cookTime = parsed.cook_time
            recipe.ingredients = parsed.ingredients
            recipe.steps = parsed.steps
            recipe.tips = parsed.tips
            recipe.tags = parsed.tags
            recipe.checked = []
            recipe.status = .ready
        } catch {
            recipe.status = .failed
            recipe.errorMessage = error.localizedDescription
        }
        try? context.save()
    }

    /// Dokańcza wpisy dodane z rozszerzenia, które nie zdążyły się przetworzyć (np. zamknięto okno udostępniania).
    static func processPending(in context: ModelContext) async {
        let descriptor = FetchDescriptor<Recipe>()
        guard let all = try? context.fetch(descriptor) else { return }
        let staleProcessing = Date().addingTimeInterval(-120)
        let waiting = all.filter {
            $0.status == .pending || ($0.status == .processing && $0.updatedAt < staleProcessing)
        }
        for recipe in waiting {
            await process(recipe, in: context)
        }
    }

    private static func findExisting(url: String, in context: ModelContext) -> Recipe? {
        let clean = URLComponents(string: url).map { c -> String in
            var c = c; c.query = nil; c.fragment = nil; return c.string ?? url
        } ?? url
        let descriptor = FetchDescriptor<Recipe>(predicate: #Predicate { $0.sourceURL == clean || $0.sourceURL == url })
        return try? context.fetch(descriptor).first
    }
}
