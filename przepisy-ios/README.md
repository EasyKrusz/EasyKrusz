# Przepisy – aplikacja na iPhone'a

Natywna aplikacja iOS (SwiftUI + SwiftData), która zamienia opisy filmików z TikToka w przepisy i trzyma je na telefonie.

- **Przepis nawet bez opisu:** gdy w opisie nie ma przepisu, aplikacja bierze to, co mówi autor: najpierw
  z automatycznych napisów TikToka, a gdy filmik ich nie ma, rozpoznaje mowę z nagrania wbudowanym rozpoznawaniem
  mowy iOS (na telefonie, za darmo; za pierwszym razem iPhone zapyta o zgodę). Rozpoznawanie mowy działa w aplikacji,
  nie w okienku „Udostępnij”, więc taki przepis dokończy się po jej otwarciu.
- **Automatyczna nazwa i miniaturka:** Claude nadaje daniu zwięzłą nazwę (można ją zmienić ✏️) i dobiera emoji.
  Miniaturka filmiku jest zapisywana na telefonie, a gdy jej brak, pokazuje się kolorowy kafelek z emoji.
- **Porcje:** ilości są zapisane na 1 porcję, więc przyciskami −/+ ustawiasz, na ile osób gotujesz.
- **Tryb gotowania:** przycisk „Gotuj krok po kroku”, czyli jeden krok na ekranie, duży tekst i ekran, który
  nie gaśnie. Gdy krok ma czas (np. pieczenie), jednym stuknięciem włączasz minutnik. Zadzwoni nawet przy
  zablokowanym telefonie.
- **Lista zakupów (zakładka „Zakupy”):** sumuje te same składniki z kilku przepisów i grupuje je według działów
  sklepu. Możesz dopisać własne rzeczy z ilością i działem (np. sól, której zabrakło), a pozycje z przepisów
  zmienić (przesuń w lewo → Edytuj) albo usunąć, jeśli masz je w domu. Usunięte da się przywrócić. Odhaczasz
  w sklepie, a listę wysyłasz jako tekst albo do Przypomnień.
- **Kopia zapasowa (Ustawienia):** zapis wszystkich przepisów z miniaturkami do pliku (np. w iCloud Drive)
  i wczytanie z pliku. Ten sam plik działa w wersji webowej.
- **Z TikToka jednym ruchem:** Udostępnij → Więcej → **Przepisy**. Rozszerzenie pobiera opis filmiku, Claude układa
  z niego przepis po polsku i zapisuje go w aplikacji. Okienko możesz zamknąć od razu, a przepis dokończy się
  po otwarciu aplikacji.
- **Albo ręcznie:** przycisk + w aplikacji, wklejasz link, opcjonalnie notatki (gdy przepis jest tylko mówiony w filmiku).
- Lista z wyszukiwarką (nazwa, składniki, tagi), ulubione, odhaczanie składników i kroków przy gotowaniu,
  własne notatki, ponowne przetworzenie, udostępnianie przepisu jako tekstu, link do oryginalnego filmiku.
- Działa bez serwera: aplikacja sama łączy się z TikTokiem i z Claude API. Przepisy są zapisane tylko na tym iPhonie.

## Czego potrzebujesz

- Maca z **Xcode 16** lub nowszym,
- iPhone'a z **iOS 17** lub nowszym,
- konta Apple (wystarczy zwykłe Apple ID),
- **klucza API Anthropic** (platform.claude.com → API keys). Płacisz za użycie: zwykle kilka centów (ok. 10–25 gr) za przepis.

## Instalacja na telefonie

```bash
brew install xcodegen
cd przepisy-ios
xcodegen            # tworzy Przepisy.xcodeproj
open Przepisy.xcodeproj
```

W Xcode:

1. Kliknij projekt **Przepisy**, a potem w obu targetach (*Przepisy* i *PrzepisyShare*) w zakładce
   **Signing & Capabilities** wybierz swój **Team** (zaloguj Apple ID w Xcode → Settings → Accounts).
   Możesz też wpisać ID zespołu raz w `project.yml` (`DEVELOPMENT_TEAM`) i ponownie uruchomić `xcodegen`.
2. Jeśli Xcode zgłosi, że identyfikator aplikacji lub App Group jest zajęty, zmień `BUNDLE_ID_PREFIX`
   w `project.yml` (np. na `pl.twojeimie.przepisy`) i uruchom `xcodegen` jeszcze raz.
3. Podłącz iPhone'a, wybierz go u góry i naciśnij ▶︎ (Run).
4. Na iPhonie: Ustawienia → Ogólne → VPN i urządzenia → zaufaj swojemu certyfikatowi. Przy pierwszym
   uruchomieniu z Xcode trzeba też włączyć **Tryb dewelopera** (Ustawienia → Prywatność i ochrona).
5. Otwórz aplikację, stuknij ⚙︎ i wklej klucz API.

> Z darmowym kontem Apple aplikacja działa **7 dni**, potem trzeba ją ponownie zainstalować z Xcode (przepisy zostają).
> Płatne konto Apple Developer (99 USD/rok) daje instalację na rok, TestFlight i App Store.

## Pierwsze udostępnienie z TikToka

W TikToku: **Udostępnij** → przewiń dolny rząd w prawo → **Więcej** → **Przepisy**.
W tym samym menu możesz przez *Edytuj działania* dodać „Przepisy” do ulubionych, żeby były zawsze na początku.

## Jak to jest zbudowane

| Plik | Co robi |
|---|---|
| `Shared/TikTokService.swift` | pobiera opis, napisy, miniaturkę i adres nagrania (strona filmiku + publiczny oEmbed) |
| `Shared/SpeechTranscriber.swift` | rozpoznawanie mowy z nagrania (Apple Speech), gdy nie ma opisu ani napisów |
| `Shared/ClaudeService.swift` | prompt i schemat JSON przepisu, wywołanie Claude API (structured outputs) |
| `Shared/RecipeImporter.swift` | dodawanie, przetwarzanie i dokańczanie zaległych przepisów |
| `Shared/Recipe.swift` | model SwiftData |
| `Shared/Kitchen.swift` | porcje, formatowanie ilości, sumowanie listy zakupów |
| `App/CookingView.swift`, `App/CookingTimers.swift` | tryb gotowania i minutniki |
| `App/ShoppingListView.swift` | lista zakupów, eksport do Przypomnień |
| `App/Backup.swift` | eksport i import kopii zapasowej |
| `Shared/SharedStore.swift` | baza w kontenerze App Group, wspólna dla aplikacji i rozszerzenia |
| `Shared/Keychain.swift` | klucz API w pęku kluczy, współdzielony z rozszerzeniem |
| `App/` | ekrany aplikacji |
| `ShareExtension/` | rozszerzenie „Udostępnij” |
| `project.yml` | definicja projektu dla XcodeGen |
