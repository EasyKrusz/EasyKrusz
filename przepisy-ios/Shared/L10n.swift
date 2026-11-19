import Foundation
import NaturalLanguage
import SwiftUI

/// Tłumaczenia interfejsu (EN/DE/PL). Język: wybrany w Ustawieniach albo język telefonu; domyślnie angielski.
/// Ustawienie jest w App Group, więc rozszerzenie „Udostępnij” używa tego samego języka.
enum L {
    static let supported = ["en", "de", "pl"]
    static let settingKey = "appLanguage"
    static let store = UserDefaults(suiteName: AppConfig.appGroup)

    /// "auto", "en", "de" albo "pl".
    static var setting: String { store?.string(forKey: settingKey) ?? "auto" }

    static let unitSettingKey = "unitSystem"
    /// Ustawienie jednostek: "auto", "metric", "us" albo "original".
    static var unitSetting: String { store?.string(forKey: unitSettingKey) ?? "auto" }
    /// System miar do wyświetlania (dla „auto” – według ustawień regionu iPhone'a).
    static var unitSystem: String { Kitchen.resolveUnitSystem(unitSetting) }

    private static var deviceLanguage: String {
        normalizeTag(Locale.preferredLanguages.first ?? "en")
    }

    /// Główny podtag języka, np. "zh-Hant" → "zh".
    static func baseLang(_ tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en").lowercased()
    }

    /// Kod języka przepisu (BCP 47). Zostawiamy pismo tam, gdzie ma znaczenie (chiński tradycyjny vs uproszczony,
    /// serbski cyrylica vs łacinka); regiony pomijamy. Tak samo działa wersja webowa (normalizeLangTag).
    static func normalizeTag(_ tag: String) -> String {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        let lang = (parts.first ?? "en").lowercased()
        let rest = parts.dropFirst()
        let script = rest.first { $0.count == 4 && $0.allSatisfy(\.isLetter) }
        let region = rest.first { ($0.count == 2 && $0.allSatisfy(\.isLetter)) || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }?.uppercased()
        if lang == "zh" {
            let traditional = script.map { $0.lowercased() == "hant" } ?? ["TW", "HK", "MO"].contains(region ?? "")
            return traditional ? "zh-Hant" : "zh-Hans"
        }
        guard let script else { return lang }
        return "\(lang)-\(script.prefix(1).uppercased())\(script.dropFirst().lowercased())"
    }

    /// Czy język pisze się od prawej do lewej (arabski, hebrajski, perski, urdu…).
    static func isRTL(_ tag: String) -> Bool {
        guard !tag.isEmpty else { return false }
        return Locale.Language(identifier: tag).characterDirection == .rightToLeft
    }

    /// Kierunek układu dla tekstu w danym języku.
    static func direction(_ tag: String) -> LayoutDirection { isRTL(tag) ? .rightToLeft : .leftToRight }

    /// Kierunek układu dla tekstu nieznanego języka (np. wpisanego ręcznie) – rozpoznany z treści.
    static func direction(ofText text: String) -> LayoutDirection {
        guard let lang = NLLanguageRecognizer.dominantLanguage(for: text) else { return .leftToRight }
        return direction(lang.rawValue)
    }

    /// Izoluje fragment w innym kierunku pisma (jak <bdi> w HTML), np. arabską nazwę w angielskim zdaniu
    /// albo „400 g” w arabskim przepisie – inaczej znaki potrafią się przestawić.
    static func isolate(_ s: String) -> String { s.isEmpty ? s : "\u{2068}\(s)\u{2069}" }

    /// Język interfejsu.
    static var lang: String {
        if supported.contains(setting) { return setting }
        for id in Locale.preferredLanguages {
            let code = baseLang(id)
            if supported.contains(code) { return code }
        }
        return "en"
    }

    /// Język, w którym AI pisze przepisy: język interfejsu, a przy „automatycznie” – język telefonu
    /// (także spoza EN/DE/PL, np. hiszpański: interfejs będzie po angielsku, przepisy po hiszpańsku).
    static var recipeLang: String {
        setting == "auto" ? deviceLanguage : lang
    }

    /// Tekst w języku interfejsu; {nazwa} zastępowane wartościami z `vars`.
    static func t(_ key: String, _ vars: [String: String] = [:]) -> String {
        let s = strings[lang]?[key] ?? strings["en"]?[key] ?? key
        return fill(s, vars)
    }

    /// Tekst z odmianą liczby, np. tp("portions", 5) → "5 porcji".
    static func tp(_ key: String, _ n: Int, _ vars: [String: String] = [:]) -> String {
        let forms = plurals[lang]?[key] ?? plurals["en"]?[key] ?? [:]
        let s = forms[pluralForm(n)] ?? forms["other"] ?? key
        var all = vars
        all["n"] = "\(n)"
        return fill(s, all)
    }

    /// Tekst z prostym formatowaniem **pogrubienia** (Markdown).
    static func md(_ key: String) -> AttributedString {
        let s = t(key)
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    static func portions(_ n: Int) -> String { tp("portions", n) }

    /// Nazwa języka w języku interfejsu, np. "ko" → "koreański", "zh-Hant" → "chiński (tradycyjny)".
    static func langName(_ code: String) -> String {
        let ui = Locale(identifier: lang)
        return ui.localizedString(forIdentifier: code) ?? ui.localizedString(forLanguageCode: code) ?? code
    }

    private static func pluralForm(_ n: Int) -> String {
        if lang == "pl" {
            if n == 1 { return "one" }
            let d = n % 10, t = n % 100
            return (2...4).contains(d) && !(12...14).contains(t) ? "few" : "many"
        }
        return n == 1 ? "one" : "other"
    }

    private static func fill(_ s: String, _ vars: [String: String]) -> String {
        vars.reduce(s) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    // MARK: - Liczba mnoga

    private static let plurals: [String: [String: [String: String]]] = [
        "en": [
            "portions": ["one": "{n} serving", "other": "{n} servings"],
            "reminders.added": ["one": "Added {n} item to the “{list}” list in Reminders.", "other": "Added {n} items to the “{list}” list in Reminders."],
            "settings.exported": ["one": "Saved a backup of {n} recipe.", "other": "Saved a backup of {n} recipes."],
            "settings.imported": ["one": "Added {n} recipe", "other": "Added {n} recipes"],
        ],
        "de": [
            "portions": ["one": "{n} Portion", "other": "{n} Portionen"],
            "reminders.added": ["one": "{n} Eintrag zur Liste „{list}“ in Erinnerungen hinzugefügt.", "other": "{n} Einträge zur Liste „{list}“ in Erinnerungen hinzugefügt."],
            "settings.exported": ["one": "Sicherung von {n} Rezept gespeichert.", "other": "Sicherung von {n} Rezepten gespeichert."],
            "settings.imported": ["one": "{n} Rezept hinzugefügt", "other": "{n} Rezepte hinzugefügt"],
        ],
        "pl": [
            "portions": ["one": "{n} porcja", "few": "{n} porcje", "many": "{n} porcji"],
            "reminders.added": ["one": "Dodano {n} pozycję do listy „{list}” w Przypomnieniach.", "few": "Dodano {n} pozycje do listy „{list}” w Przypomnieniach.", "many": "Dodano {n} pozycji do listy „{list}” w Przypomnieniach."],
            "settings.exported": ["one": "Zapisano kopię {n} przepisu.", "few": "Zapisano kopię {n} przepisów.", "many": "Zapisano kopię {n} przepisów."],
            "settings.imported": ["one": "Dodano {n} przepis", "few": "Dodano {n} przepisy", "many": "Dodano {n} przepisów"],
        ],
    ]

    // MARK: - Teksty

    private static let strings: [String: [String: String]] = [
        "en": [
            "app.name": "Recipes",
            "tab.recipes": "Recipes",
            "tab.shopping": "Shopping",
            "common.cancel": "Cancel",
            "common.save": "Save",
            "common.delete": "Delete",
            "common.edit": "Edit",
            "common.done": "Done",
            "common.close": "Close",

            "list.addKey": "Add your Anthropic API key to process recipes",
            "list.favorite": "Favourite",
            "list.empty": "No recipes",
            "list.emptyHint": "In TikTok, tap **Share → More → Recipes**, or add a link with the + button.",
            "list.addRecipe": "Add recipe",
            "list.search": "Name, ingredient, tag…",
            "list.onlyFavorites": "Favourites only",
            "status.processing": "Processing…",
            "status.speech": "Listening to the video…",
            "status.failed": "Didn't work",

            "add.linkHeader": "Video link",
            "add.linkFooter": "In TikTok: Share → Copy link.",
            "add.notesHeader": "Notes (optional)",
            "add.notesFooter": "If the recipe is only spoken in the video, type the ingredients or steps here – they'll be combined with the caption.",
            "add.duplicate": "This video is already saved: “{title}”.",

            "recipe.new": "New recipe",
            "recipe.videoBy": "Video by @{author}",
            "recipe.rename": "Rename",
            "recipe.renamePrompt": "Recipe name",
            "recipe.prep": "prep: {t}",
            "recipe.cook": "cooking: {t}",
            "recipe.cookMode": "Cook step by step",
            "recipe.toCart": "Add to shopping list",
            "recipe.ingredients": "Ingredients",
            "recipe.inVideo": "In the video: {s}. ",
            "recipe.perPortion": "Amounts are calculated from 1 serving × number of servings.",
            "recipe.steps": "Method",
            "recipe.tips": "Tips",
            "recipe.myNotes": "My notes",
            "recipe.originalDescription": "Original TikTok caption",
            "recipe.transcript": "Transcript of the video",
            "recipe.openVideo": "Open video in TikTok",
            "recipe.confirmDelete": "Delete “{title}”?",
            "recipe.source": "Source",

            "detail.working": "Fetching the caption and subtitles, writing the recipe…",
            "detail.workingHint": "If the caption has no recipe, I listen to the video – this can take a minute.",
            "detail.failed": "Couldn't process this.",
            "detail.retry": "Try again",
            "detail.notesHint": "After changing your notes you can process the recipe again – they'll be included.",
            "detail.reprocess": "Process again",
            "detail.delete": "Delete recipe",
            "detail.prep": "prep: {t}",
            "detail.cook": "cooking: {t}",
            "detail.inCart": "On the shopping list ✓ (remove)",
            "detail.portions": "Servings",
            "detail.tapToCheck": "Tap an ingredient to tick it off.",
            "detail.timer": "Timer: {t}",
            "detail.clearChecks": "Clear ticks",

            "lang.auto": "Automatic (phone language)",
            "lang.showOriginal": "Show original ({lang})",
            "lang.showTranslated": "Show in {lang}",
            "lang.translating": "Translating…",
            "lang.recipeIn": "This recipe is in {lang}.",
            "lang.translate": "Translate to {lang}",

            "portions.less": "Fewer servings",
            "portions.more": "More servings",
            "time.min": "{n} min",
            "time.h": "{h} h",
            "time.hmin": "{h} h {m} min",
            "timer.start": "Start timer: {t}",
            "timer.done": "Done!",
            "timer.remove": "Remove timer",
            "timer.body": "Time's up: {label}",

            "cook.ingredients": "Get the ingredients ready",
            "cook.step": "Step {i} of {n}",
            "cook.prev": "Back",
            "cook.next": "Next",
            "cook.finish": "Done 🎉",
            "cook.close": "Close cooking mode",

            "shop.title": "Shopping list",
            "shop.addHeader": "Add your own",
            "shop.addPlaceholder": "What to add? E.g. salt, baking paper",
            "shop.amountOptional": "Amount (optional), e.g. 1 pack",
            "shop.category": "Supermarket section",
            "shop.addToList": "Add to list",
            "shop.fromRecipes": "From recipes",
            "shop.hint": "Add recipes with “Add to shopping list” on a recipe page.",
            "shop.extraBadge": "added",
            "shop.editedBadge": "edited",
            "shop.sendText": "Send as text",
            "shop.toReminders": "Add to Reminders",
            "shop.clear": "Clear list",
            "shop.clearConfirm": "Clear the whole shopping list (recipes, added items and edits)?",
            "shop.removed": "Removed from the list ({n})",
            "shop.restore": "Restore",
            "shop.merged": "“{name}” was already on the list from a recipe – changed the amount to “{amount}”.",
            "shop.mergedSame": "“{name}” was already on the list from a recipe – kept a single item.",
            "shop.dlgExtra": "Your item",
            "shop.dlgRecipe": "Item from a recipe",
            "shop.name": "Name",
            "shop.amountPh": "Amount, e.g. 1 pack",
            "shop.fromInfo": "From recipes ({recipes}): {original}. An edited amount does not change with the number of servings.",
            "shop.reset": "Restore from recipe",
            "shop.delete": "Remove from list",

            "reminders.listName": "Shopping",
            "reminders.denied": "No access to Reminders – allow it in iPhone Settings → Recipes.",
            "reminders.noAccount": "No Reminders account found on this iPhone.",
            "reminders.failed": "Couldn't add to Reminders: {error}",

            "settings.title": "Settings",
            "settings.language": "Language",
            "settings.units": "Units",
            "settings.unitsFooter": "Amounts and oven temperatures are converted when shown – the saved recipe doesn't change. Spoons stay spoons in every system.",
            "units.auto": "Automatic (by region)",
            "units.metric": "Metric (g, ml, °C)",
            "units.us": "US (oz, lb, cups, °F)",
            "units.original": "As in the recipe",
            "settings.languageFooter": "New recipes are written in this language. A recipe in another language can be translated with one tap.",
            "settings.apiKey": "Anthropic API key",
            "settings.apiKeyFooter": "Needed to turn captions into recipes. Create a key at platform.claude.com – you pay per processed recipe (usually about 2 cents). The key is stored in this iPhone's keychain.",
            "settings.createKey": "Create an API key",
            "settings.howTo": "How to add recipes",
            "settings.howToText": "1. In TikTok, tap **Share**.\n2. Scroll right and choose **More** (…).\n3. Choose **Recipes**. You can add it to your favourites in that menu (Edit Actions).",
            "settings.backup": "Backup",
            "settings.backupFooter": "Save the file to iCloud Drive or send it to yourself. When loading, recipes that are already in the app are skipped. The same file works in the web version.",
            "settings.export": "Save a backup to a file",
            "settings.import": "Load recipes from a file",
            "settings.exportFailed": "Couldn't create the backup: {error}",
            "settings.skipped": ", skipped {n} (already in the app).",
            "settings.keySaveFailed": "Couldn't save the key.",

            "share.noLink": "No TikTok link found in what was shared.",
            "share.noKey": "Link saved. Add your API key in the Recipes app – the recipe will be processed when you open it.",
            "share.needsSpeech": "There's no recipe in the caption or subtitles.\n\nOpen the Recipes app – it will listen to what the creator says and write the recipe from the video.",
            "share.failedHint": "The entry is in the app – you can add notes there and try again.",
            "share.canClose": "You can close this window – the recipe will finish in the app.",
            "share.saved": "Saved",

            "import.noRecipe": "I couldn't find a recipe in the caption or in what the creator says.",
            "import.addNotes": "Type the recipe (or part of it) in the notes and process it again.",

            "err.missingKey": "No Anthropic API key. Add it in the app's Settings.",
            "err.badKey": "Invalid Anthropic API key – check it in Settings.",
            "err.rateLimit": "Too many requests to Claude – try again in a moment.",
            "err.api": "Claude API error ({code}): {msg}",
            "err.refusal": "The AI declined to process this description.",
            "err.truncated": "The AI response was cut off – try again.",
            "err.badResponse": "Unexpected response from the Claude API.",
            "err.tiktokFailed": "Couldn't fetch the video from TikTok ({why}).",
            "err.tiktokEmpty": "The video has no caption or subtitles to read a recipe from.",
            "err.bad_backup": "This is not a recipe backup file.",

            "speech.notAuthorized": "Speech recognition isn't allowed. Turn it on in iPhone Settings → Recipes.",
            "speech.unavailable": "Speech recognition is unavailable on this iPhone right now.",
            "speech.noVideo": "Couldn't download the video recording.",
            "speech.audioExport": "Couldn't extract the audio from the video.",
            "speech.nothingHeard": "No speech was recognised in the video.",
        ],

        "de": [
            "app.name": "Rezepte",
            "tab.recipes": "Rezepte",
            "tab.shopping": "Einkauf",
            "common.cancel": "Abbrechen",
            "common.save": "Sichern",
            "common.delete": "Löschen",
            "common.edit": "Bearbeiten",
            "common.done": "Fertig",
            "common.close": "Schließen",

            "list.addKey": "Füge deinen Anthropic-API-Schlüssel hinzu, um Rezepte zu verarbeiten",
            "list.favorite": "Favorit",
            "list.empty": "Keine Rezepte",
            "list.emptyHint": "Tippe in TikTok auf **Teilen → Mehr → Rezepte** oder füge einen Link mit + hinzu.",
            "list.addRecipe": "Rezept hinzufügen",
            "list.search": "Name, Zutat, Tag…",
            "list.onlyFavorites": "Nur Favoriten",
            "status.processing": "Wird verarbeitet…",
            "status.speech": "Video wird angehört…",
            "status.failed": "Hat nicht geklappt",

            "add.linkHeader": "Link zum Video",
            "add.linkFooter": "In TikTok: Teilen → Link kopieren.",
            "add.notesHeader": "Notizen (optional)",
            "add.notesFooter": "Wenn das Rezept im Video nur gesprochen wird, schreib hier Zutaten oder Schritte auf – sie werden mit der Beschreibung kombiniert.",
            "add.duplicate": "Dieses Video ist schon gespeichert: „{title}“.",

            "recipe.new": "Neues Rezept",
            "recipe.videoBy": "Video von @{author}",
            "recipe.rename": "Umbenennen",
            "recipe.renamePrompt": "Name des Rezepts",
            "recipe.prep": "Vorbereitung: {t}",
            "recipe.cook": "Kochzeit: {t}",
            "recipe.cookMode": "Schritt für Schritt kochen",
            "recipe.toCart": "Auf die Einkaufsliste",
            "recipe.ingredients": "Zutaten",
            "recipe.inVideo": "Im Video: {s}. ",
            "recipe.perPortion": "Mengen werden aus 1 Portion × Anzahl der Portionen berechnet.",
            "recipe.steps": "Zubereitung",
            "recipe.tips": "Tipps",
            "recipe.myNotes": "Meine Notizen",
            "recipe.originalDescription": "Originalbeschreibung auf TikTok",
            "recipe.transcript": "Transkript des Videos",
            "recipe.openVideo": "Video in TikTok öffnen",
            "recipe.confirmDelete": "„{title}“ löschen?",
            "recipe.source": "Quelle",

            "detail.working": "Beschreibung und Untertitel werden geladen, Rezept wird erstellt…",
            "detail.workingHint": "Steht kein Rezept in der Beschreibung, höre ich mir das Video an – das kann eine Minute dauern.",
            "detail.failed": "Konnte nicht verarbeitet werden.",
            "detail.retry": "Noch einmal versuchen",
            "detail.notesHint": "Nach dem Ändern der Notizen kannst du das Rezept neu verarbeiten – sie werden berücksichtigt.",
            "detail.reprocess": "Neu verarbeiten",
            "detail.delete": "Rezept löschen",
            "detail.prep": "Vorbereitung: {t}",
            "detail.cook": "Kochzeit: {t}",
            "detail.inCart": "Auf der Einkaufsliste ✓ (entfernen)",
            "detail.portions": "Portionen",
            "detail.tapToCheck": "Tippe auf eine Zutat, um sie abzuhaken.",
            "detail.timer": "Timer: {t}",
            "detail.clearChecks": "Häkchen entfernen",

            "lang.auto": "Automatisch (Sprache des Telefons)",
            "lang.showOriginal": "Original anzeigen ({lang})",
            "lang.showTranslated": "Auf {lang} anzeigen",
            "lang.translating": "Wird übersetzt…",
            "lang.recipeIn": "Dieses Rezept ist auf {lang}.",
            "lang.translate": "Übersetzen: {lang}",

            "portions.less": "Weniger Portionen",
            "portions.more": "Mehr Portionen",
            "time.min": "{n} Min.",
            "time.h": "{h} Std.",
            "time.hmin": "{h} Std. {m} Min.",
            "timer.start": "Timer starten: {t}",
            "timer.done": "Fertig!",
            "timer.remove": "Timer entfernen",
            "timer.body": "Zeit ist um: {label}",

            "cook.ingredients": "Zutaten bereitstellen",
            "cook.step": "Schritt {i} von {n}",
            "cook.prev": "Zurück",
            "cook.next": "Weiter",
            "cook.finish": "Fertig 🎉",
            "cook.close": "Kochmodus schließen",

            "shop.title": "Einkaufsliste",
            "shop.addHeader": "Eigene Einträge",
            "shop.addPlaceholder": "Was hinzufügen? Z. B. Salz, Backpapier",
            "shop.amountOptional": "Menge (optional), z. B. 1 Packung",
            "shop.category": "Abteilung im Supermarkt",
            "shop.addToList": "Zur Liste hinzufügen",
            "shop.fromRecipes": "Aus Rezepten",
            "shop.hint": "Rezepte fügst du mit „Auf die Einkaufsliste“ auf der Rezeptseite hinzu.",
            "shop.extraBadge": "hinzugefügt",
            "shop.editedBadge": "geändert",
            "shop.sendText": "Als Text senden",
            "shop.toReminders": "Zu Erinnerungen hinzufügen",
            "shop.clear": "Liste leeren",
            "shop.clearConfirm": "Die ganze Einkaufsliste leeren (Rezepte, eigene Einträge und Änderungen)?",
            "shop.removed": "Von der Liste entfernt ({n})",
            "shop.restore": "Wiederherstellen",
            "shop.merged": "„{name}“ stand schon aus einem Rezept auf der Liste – Menge auf „{amount}“ geändert.",
            "shop.mergedSame": "„{name}“ stand schon aus einem Rezept auf der Liste – es bleibt bei einem Eintrag.",
            "shop.dlgExtra": "Dein Eintrag",
            "shop.dlgRecipe": "Eintrag aus einem Rezept",
            "shop.name": "Name",
            "shop.amountPh": "Menge, z. B. 1 Packung",
            "shop.fromInfo": "Aus Rezepten ({recipes}): {original}. Eine geänderte Menge passt sich nicht an die Portionen an.",
            "shop.reset": "Aus dem Rezept wiederherstellen",
            "shop.delete": "Von der Liste entfernen",

            "reminders.listName": "Einkauf",
            "reminders.denied": "Kein Zugriff auf Erinnerungen – erlaube ihn in den iPhone-Einstellungen → Rezepte.",
            "reminders.noAccount": "Auf diesem iPhone wurde kein Konto für Erinnerungen gefunden.",
            "reminders.failed": "Hinzufügen zu Erinnerungen fehlgeschlagen: {error}",

            "settings.title": "Einstellungen",
            "settings.language": "Sprache",
            "settings.units": "Einheiten",
            "settings.unitsFooter": "Mengen und Backtemperaturen werden beim Anzeigen umgerechnet – das gespeicherte Rezept bleibt gleich. Löffel bleiben in jedem System Löffel.",
            "units.auto": "Automatisch (nach Region)",
            "units.metric": "Metrisch (g, ml, °C)",
            "units.us": "US (oz, lb, Cups, °F)",
            "units.original": "Wie im Rezept",
            "settings.languageFooter": "Neue Rezepte werden in dieser Sprache geschrieben. Ein Rezept in einer anderen Sprache lässt sich mit einem Tippen übersetzen.",
            "settings.apiKey": "Anthropic-API-Schlüssel",
            "settings.apiKeyFooter": "Wird benötigt, um Beschreibungen in Rezepte umzuwandeln. Den Schlüssel erstellst du auf platform.claude.com – du zahlst pro verarbeitetem Rezept (meist etwa 2 Cent). Der Schlüssel liegt im Schlüsselbund dieses iPhones.",
            "settings.createKey": "API-Schlüssel erstellen",
            "settings.howTo": "So fügst du Rezepte hinzu",
            "settings.howToText": "1. Tippe in TikTok auf **Teilen**.\n2. Wische nach rechts und wähle **Mehr** (…).\n3. Wähle **Rezepte**. In diesem Menü kannst du die App zu den Favoriten hinzufügen (Aktionen bearbeiten).",
            "settings.backup": "Sicherung",
            "settings.backupFooter": "Speichere die Datei in iCloud Drive oder schick sie dir selbst. Beim Laden werden Rezepte übersprungen, die schon in der App sind. Dieselbe Datei funktioniert in der Web-Version.",
            "settings.export": "Sicherung in eine Datei speichern",
            "settings.import": "Rezepte aus einer Datei laden",
            "settings.exportFailed": "Sicherung konnte nicht erstellt werden: {error}",
            "settings.skipped": ", {n} übersprungen (schon in der App).",
            "settings.keySaveFailed": "Der Schlüssel konnte nicht gespeichert werden.",

            "share.noLink": "In den geteilten Daten wurde kein TikTok-Link gefunden.",
            "share.noKey": "Link gespeichert. Füge in der Rezepte-App deinen API-Schlüssel hinzu – das Rezept wird beim Öffnen verarbeitet.",
            "share.needsSpeech": "Weder in der Beschreibung noch in den Untertiteln steht ein Rezept.\n\nÖffne die Rezepte-App – sie hört sich an, was im Video gesagt wird, und schreibt daraus das Rezept.",
            "share.failedHint": "Der Eintrag ist in der App – dort kannst du Notizen ergänzen und es erneut versuchen.",
            "share.canClose": "Du kannst dieses Fenster schließen – das Rezept wird in der App fertiggestellt.",
            "share.saved": "Gespeichert",

            "import.noRecipe": "Weder in der Beschreibung noch im Gesprochenen habe ich ein Rezept gefunden.",
            "import.addNotes": "Schreib das Rezept (oder einen Teil davon) in die Notizen und verarbeite es neu.",

            "err.missingKey": "Kein Anthropic-API-Schlüssel. Füge ihn in den Einstellungen der App hinzu.",
            "err.badKey": "Ungültiger Anthropic-API-Schlüssel – prüfe ihn in den Einstellungen.",
            "err.rateLimit": "Zu viele Anfragen an Claude – versuch es gleich noch einmal.",
            "err.api": "Fehler der Claude-API ({code}): {msg}",
            "err.refusal": "Die KI hat die Verarbeitung dieser Beschreibung abgelehnt.",
            "err.truncated": "Die Antwort der KI wurde abgeschnitten – versuch es noch einmal.",
            "err.badResponse": "Unerwartete Antwort der Claude-API.",
            "err.tiktokFailed": "Das Video konnte nicht von TikTok geladen werden ({why}).",
            "err.tiktokEmpty": "Das Video hat weder Beschreibung noch Untertitel, aus denen sich ein Rezept lesen lässt.",
            "err.bad_backup": "Das ist keine Sicherungsdatei mit Rezepten.",

            "speech.notAuthorized": "Spracherkennung ist nicht erlaubt. Schalte sie in den iPhone-Einstellungen → Rezepte ein.",
            "speech.unavailable": "Die Spracherkennung ist auf diesem iPhone gerade nicht verfügbar.",
            "speech.noVideo": "Die Videoaufnahme konnte nicht geladen werden.",
            "speech.audioExport": "Der Ton konnte nicht aus dem Video gelesen werden.",
            "speech.nothingHeard": "Im Video wurde keine Sprache erkannt.",
        ],

        "pl": [
            "app.name": "Przepisy",
            "tab.recipes": "Przepisy",
            "tab.shopping": "Zakupy",
            "common.cancel": "Anuluj",
            "common.save": "Zapisz",
            "common.delete": "Usuń",
            "common.edit": "Edytuj",
            "common.done": "Gotowe",
            "common.close": "Zamknij",

            "list.addKey": "Dodaj klucz API Anthropic, żeby przetwarzać przepisy",
            "list.favorite": "Ulubiony",
            "list.empty": "Brak przepisów",
            "list.emptyHint": "W TikToku stuknij **Udostępnij → Więcej → Przepisy** albo dodaj link przyciskiem +.",
            "list.addRecipe": "Dodaj przepis",
            "list.search": "Nazwa, składnik, tag…",
            "list.onlyFavorites": "Tylko ulubione",
            "status.processing": "Przetwarzam…",
            "status.speech": "Rozpoznaję mowę z filmiku…",
            "status.failed": "Nie udało się",

            "add.linkHeader": "Link do filmiku",
            "add.linkFooter": "W TikToku: Udostępnij → Kopiuj link.",
            "add.notesHeader": "Notatki (opcjonalnie)",
            "add.notesFooter": "Jeśli przepis jest tylko mówiony w filmiku, wpisz tu składniki lub kroki – zostaną połączone z opisem.",
            "add.duplicate": "Ten filmik jest już zapisany: „{title}”.",

            "recipe.new": "Nowy przepis",
            "recipe.videoBy": "Filmik @{author}",
            "recipe.rename": "Zmień nazwę",
            "recipe.renamePrompt": "Nazwa przepisu",
            "recipe.prep": "przygotowanie: {t}",
            "recipe.cook": "gotowanie: {t}",
            "recipe.cookMode": "Gotuj krok po kroku",
            "recipe.toCart": "Do listy zakupów",
            "recipe.ingredients": "Składniki",
            "recipe.inVideo": "W filmiku: {s}. ",
            "recipe.perPortion": "Ilości są liczone z 1 porcji × liczba porcji.",
            "recipe.steps": "Przygotowanie",
            "recipe.tips": "Wskazówki",
            "recipe.myNotes": "Moje notatki",
            "recipe.originalDescription": "Oryginalny opis z TikToka",
            "recipe.transcript": "Transkrypcja mowy z filmiku",
            "recipe.openVideo": "Otwórz filmik w TikToku",
            "recipe.confirmDelete": "Usunąć „{title}”?",
            "recipe.source": "Źródło",

            "detail.working": "Pobieram opis i napisy, układam przepis…",
            "detail.workingHint": "Gdy w opisie nie ma przepisu, słucham filmiku – to może potrwać minutę.",
            "detail.failed": "Nie udało się przetworzyć.",
            "detail.retry": "Spróbuj ponownie",
            "detail.notesHint": "Po zmianie notatek możesz przetworzyć przepis ponownie – zostaną uwzględnione.",
            "detail.reprocess": "Przetwórz ponownie",
            "detail.delete": "Usuń przepis",
            "detail.prep": "przygotowanie: {t}",
            "detail.cook": "gotowanie: {t}",
            "detail.inCart": "Na liście zakupów ✓ (usuń)",
            "detail.portions": "Porcje",
            "detail.tapToCheck": "Stuknij składnik, żeby go odhaczyć.",
            "detail.timer": "Minutnik: {t}",
            "detail.clearChecks": "Wyczyść odhaczenia",

            "lang.auto": "Automatycznie (język telefonu)",
            "lang.showOriginal": "Pokaż oryginał ({lang})",
            "lang.showTranslated": "Pokaż w języku: {lang}",
            "lang.translating": "Tłumaczę…",
            "lang.recipeIn": "Ten przepis jest w języku: {lang}.",
            "lang.translate": "Przetłumacz na język: {lang}",

            "portions.less": "Mniej porcji",
            "portions.more": "Więcej porcji",
            "time.min": "{n} min",
            "time.h": "{h} h",
            "time.hmin": "{h} h {m} min",
            "timer.start": "Włącz minutnik: {t}",
            "timer.done": "Gotowe!",
            "timer.remove": "Usuń minutnik",
            "timer.body": "Minął czas: {label}",

            "cook.ingredients": "Przygotuj składniki",
            "cook.step": "Krok {i} z {n}",
            "cook.prev": "Wstecz",
            "cook.next": "Dalej",
            "cook.finish": "Gotowe 🎉",
            "cook.close": "Zamknij tryb gotowania",

            "shop.title": "Lista zakupów",
            "shop.addHeader": "Dopisz coś od siebie",
            "shop.addPlaceholder": "Co dopisać? Np. sól, papier do pieczenia",
            "shop.amountOptional": "Ilość (opcjonalnie), np. 1 opakowanie",
            "shop.category": "Dział sklepu",
            "shop.addToList": "Dodaj do listy",
            "shop.fromRecipes": "Z przepisów",
            "shop.hint": "Przepisy dodasz przyciskiem „Do listy zakupów” na stronie przepisu.",
            "shop.extraBadge": "dopisane",
            "shop.editedBadge": "zmienione",
            "shop.sendText": "Wyślij jako tekst",
            "shop.toReminders": "Dodaj do Przypomnień",
            "shop.clear": "Wyczyść listę",
            "shop.clearConfirm": "Wyczyścić całą listę zakupów (przepisy, dopisane rzeczy i zmiany)?",
            "shop.removed": "Usunięte z listy ({n})",
            "shop.restore": "Przywróć",
            "shop.merged": "„{name}” już było na liście z przepisu – zmieniłem ilość na „{amount}”.",
            "shop.mergedSame": "„{name}” już było na liście z przepisu – zostawiłem jedną pozycję.",
            "shop.dlgExtra": "Twoja pozycja",
            "shop.dlgRecipe": "Pozycja z przepisu",
            "shop.name": "Nazwa",
            "shop.amountPh": "Ilość, np. 1 opakowanie",
            "shop.fromInfo": "Z przepisów ({recipes}): {original}. Zmieniona ilość nie przelicza się przy zmianie porcji.",
            "shop.reset": "Przywróć z przepisu",
            "shop.delete": "Usuń z listy",

            "reminders.listName": "Zakupy",
            "reminders.denied": "Brak dostępu do Przypomnień – włącz go w Ustawieniach iPhone'a → Przepisy.",
            "reminders.noAccount": "Nie znalazłem konta Przypomnień na tym iPhonie.",
            "reminders.failed": "Nie udało się dodać do Przypomnień: {error}",

            "settings.title": "Ustawienia",
            "settings.language": "Język",
            "settings.units": "Jednostki",
            "settings.unitsFooter": "Ilości i temperatury piekarnika są przeliczane przy wyświetlaniu – zapisany przepis się nie zmienia. Łyżki zostają łyżkami w każdym systemie.",
            "units.auto": "Automatycznie (wg regionu)",
            "units.metric": "Metryczne (g, ml, °C)",
            "units.us": "Amerykańskie (oz, lb, cups, °F)",
            "units.original": "Bez przeliczania",
            "settings.languageFooter": "W tym języku powstają nowe przepisy. Przepis w innym języku przetłumaczysz jednym stuknięciem.",
            "settings.apiKey": "Klucz API Anthropic",
            "settings.apiKeyFooter": "Potrzebny do zamiany opisów w przepisy. Klucz zakładasz na platform.claude.com – płacisz za każdy przetworzony przepis (zwykle ok. 2 centy). Klucz jest zapisany w pęku kluczy tego iPhone'a.",
            "settings.createKey": "Utwórz klucz API",
            "settings.howTo": "Jak dodawać przepisy",
            "settings.howToText": "1. W TikToku stuknij **Udostępnij**.\n2. Przewiń w prawo i wybierz **Więcej** (…).\n3. Wybierz **Przepisy**. Za pierwszym razem możesz je dodać do ulubionych w tym menu (Edytuj działania).",
            "settings.backup": "Kopia zapasowa",
            "settings.backupFooter": "Plik możesz zapisać w iCloud Drive albo wysłać sobie. Przy wczytywaniu przepisy, które już są w aplikacji, zostaną pominięte. Ten sam plik działa w wersji webowej aplikacji.",
            "settings.export": "Zapisz kopię przepisów do pliku",
            "settings.import": "Wczytaj przepisy z pliku",
            "settings.exportFailed": "Nie udało się przygotować kopii: {error}",
            "settings.skipped": ", pominięto {n} (już były w aplikacji).",
            "settings.keySaveFailed": "Nie udało się zapisać klucza.",

            "share.noLink": "Nie znalazłem linku do TikToka w udostępnionych danych.",
            "share.noKey": "Link zapisany. Dodaj klucz API w aplikacji Przepisy – przepis przetworzy się po jej otwarciu.",
            "share.needsSpeech": "W opisie ani w napisach filmiku nie ma przepisu.\n\nOtwórz aplikację Przepisy – posłucha, co mówi autor, i ułoży przepis z nagrania.",
            "share.failedHint": "Wpis jest w aplikacji – możesz tam dopisać notatki i spróbować ponownie.",
            "share.canClose": "Możesz zamknąć to okno – przepis dokończy się w aplikacji.",
            "share.saved": "Zapisano",

            "import.noRecipe": "Nie znalazłem przepisu ani w opisie, ani w tym, co mówi autor filmiku.",
            "import.addNotes": "Wpisz przepis (albo jego część) w notatkach i przetwórz ponownie.",

            "err.missingKey": "Brak klucza API Anthropic. Dodaj go w Ustawieniach aplikacji.",
            "err.badKey": "Nieprawidłowy klucz API Anthropic – sprawdź go w Ustawieniach.",
            "err.rateLimit": "Za dużo zapytań do Claude – spróbuj za chwilę.",
            "err.api": "Błąd Claude API ({code}): {msg}",
            "err.refusal": "AI odmówiła przetworzenia tego opisu.",
            "err.truncated": "Odpowiedź AI została ucięta – spróbuj ponownie.",
            "err.badResponse": "Nieoczekiwana odpowiedź Claude API.",
            "err.tiktokFailed": "Nie udało się pobrać filmiku z TikToka ({why}).",
            "err.tiktokEmpty": "Filmik nie ma opisu ani napisów, z których dałoby się odczytać przepis.",
            "err.bad_backup": "To nie jest plik kopii zapasowej przepisów.",

            "speech.notAuthorized": "Brak zgody na rozpoznawanie mowy. Włącz ją w Ustawieniach iPhone'a → Przepisy.",
            "speech.unavailable": "Rozpoznawanie mowy jest teraz niedostępne na tym iPhonie.",
            "speech.noVideo": "Nie udało się pobrać nagrania z filmiku.",
            "speech.audioExport": "Nie udało się wyciągnąć dźwięku z filmiku.",
            "speech.nothingHeard": "W filmiku nie rozpoznano żadnej mowy.",
        ],
    ]
}

extension View {
    /// Tekst przepisu w danym języku: kierunek pisma (np. arabski od prawej) i język dla czcionek (CJK).
    func contentLanguage(_ tag: String) -> some View {
        environment(\.layoutDirection, L.direction(tag))
            .environment(\.locale, Locale(identifier: tag.isEmpty ? L.lang : tag))
    }
}
