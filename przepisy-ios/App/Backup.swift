import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Kopia zapasowa przepisów jako plik JSON. Ten sam format zapisuje i czyta wersja webowa
/// (GET/POST /api/backup), więc plikiem można też przenosić przepisy między telefonem a stroną.
enum Backup {
    static let format = "przepisy-backup"

    // MARK: Eksport

    @MainActor
    static func export(_ recipes: [Recipe]) throws -> Data {
        let iso = ISO8601DateFormatter()
        let list: [[String: Any]] = recipes.filter { $0.status == .ready }.map { r in
            var thumbnail: Any = NSNull()
            if let data = r.thumbnailData {
                thumbnail = ["type": "image/jpeg", "data": data.base64EncodedString()]
            }
            let ingredients: [[String: Any]] = r.ingredients.map {
                ["group": $0.group, "name": $0.name, "unit": $0.unit, "note": $0.note,
                 "category": $0.category, "per_portion": $0.perPortion]
            }
            let steps: [[String: Any]] = r.steps.map { ["text": $0.text, "minutes": $0.minutes] }
            let translations: Any = (try? JSONEncoder().encode(r.translations))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [String: Any]()
            let source: [String: Any] = [
                "url": r.sourceURL, "author": r.author,
                "description": r.originalDescription, "transcript": r.transcript,
            ]
            return [
                "id": r.id.uuidString, "createdAt": iso.string(from: r.createdAt),
                "language": r.language, "source_language": r.sourceLanguage, "translations": translations,
                "title": r.title, "emoji": r.emoji, "summary": r.summary,
                "servings": r.servings, "servings_count": r.servingsCount, "portions": r.portions,
                "prep_time": r.prepTime, "cook_time": r.cookTime,
                "ingredients": ingredients, "steps": steps, "tips": r.tips, "tags": r.tags,
                "notes": r.notes, "favorite": r.favorite, "source": source, "thumbnail": thumbnail,
            ]
        }
        let root: [String: Any] = [
            "format": format, "version": 2, "exportedAt": iso.string(from: Date()), "recipes": list,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static var fileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "przepisy-\(f.string(from: Date()))"
    }

    // MARK: Import

    enum ImportError: LocalizedError {
        case notBackup
        var errorDescription: String? { L.t("err.bad_backup") }
    }

    /// Dodaje przepisy, których jeszcze nie ma (po id albo linku do filmiku). Zwraca (dodane, pominięte).
    @MainActor
    static func importData(_ data: Data, into context: ModelContext) throws -> (added: Int, skipped: Int) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format,
              let list = root["recipes"] as? [[String: Any]]
        else { throw ImportError.notBackup }

        let existing = (try? context.fetch(FetchDescriptor<Recipe>())) ?? []
        var ids = Set(existing.map(\.id.uuidString))
        var urls = Set(existing.map(\.sourceURL).filter { !$0.isEmpty })
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var added = 0
        for d in list {
            guard let title = d["title"] as? String else { continue }
            let source = d["source"] as? [String: Any] ?? [:]
            let url = source["url"] as? String ?? ""
            let idString = d["id"] as? String ?? ""
            if ids.contains(idString) || (!url.isEmpty && urls.contains(url)) { continue }

            let r = Recipe(sourceURL: url, notes: d["notes"] as? String ?? "")
            if let uuid = UUID(uuidString: idString) { r.id = uuid }
            if let date = d["createdAt"] as? String, let parsed = iso.date(from: date) ?? isoPlain.date(from: date) {
                r.createdAt = parsed
            }
            // Pliki z wersji 1 (przed wielojęzycznością) pochodziły z polskiej wersji aplikacji
            r.language = d["language"] as? String ?? "pl"
            r.sourceLanguage = d["source_language"] as? String ?? ""
            if let tr = d["translations"], let data = try? JSONSerialization.data(withJSONObject: tr),
               let decoded = try? JSONDecoder().decode([String: RecipeText].self, from: data) {
                r.translations = decoded
            }
            r.title = title
            r.titleEdited = true
            r.emoji = d["emoji"] as? String ?? ""
            r.summary = d["summary"] as? String ?? ""
            r.servings = d["servings"] as? String ?? ""
            r.servingsCount = max(1, d["servings_count"] as? Int ?? Int(r.servings.prefix { $0.isNumber }) ?? 1)
            r.portions = d["portions"] as? Int ?? 0
            r.prepTime = d["prep_time"] as? String ?? ""
            r.cookTime = d["cook_time"] as? String ?? ""
            r.tips = d["tips"] as? [String] ?? []
            r.tags = d["tags"] as? [String] ?? []
            r.favorite = d["favorite"] as? Bool ?? false
            r.author = source["author"] as? String ?? ""
            r.originalDescription = source["description"] as? String ?? ""
            r.transcript = source["transcript"] as? String ?? ""

            // Składniki – także ze starszych wersji (ilość jako tekst w polu „amount”)
            r.ingredients = (d["ingredients"] as? [[String: Any]] ?? []).map { i in
                let perPortion = (i["per_portion"] as? NSNumber)?.doubleValue
                return Ingredient(
                    group: i["group"] as? String ?? "",
                    name: i["name"] as? String ?? "",
                    unit: Kitchen.unitCode(i["unit"] as? String ?? ""),
                    note: i["note"] as? String ?? (perPortion == nil ? i["amount"] as? String ?? "" : ""),
                    category: Kitchen.categoryCode(i["category"] as? String ?? "other"),
                    perPortion: perPortion ?? 0
                )
            }
            // Kroki – obiekty {text, minutes} albo (starsze) same napisy
            r.steps = (d["steps"] as? [Any] ?? []).compactMap { s in
                if let text = s as? String { return Step(text: text, minutes: 0) }
                guard let o = s as? [String: Any], let text = o["text"] as? String else { return nil }
                return Step(text: text, minutes: (o["minutes"] as? NSNumber)?.doubleValue ?? 0)
            }
            if let thumb = d["thumbnail"] as? [String: Any], let b64 = thumb["data"] as? String {
                r.thumbnailData = Data(base64Encoded: b64)
            }
            r.status = .ready

            context.insert(r)
            ids.insert(r.id.uuidString)
            if !url.isEmpty { urls.insert(url) }
            added += 1
        }
        try context.save()
        return (added, list.count - added)
    }
}

/// Plik kopii zapasowej dla `.fileExporter`.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
