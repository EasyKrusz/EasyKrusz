# Przepisy z TikToka

Wklejasz link do filmiku z TikToka (albo udostępniasz go prosto z aplikacji TikTok), a aplikacja:

1. pobiera opis filmiku i, jeśli są, jego automatyczne napisy, czyli transkrypcję tego, co mówi autor
   (dane ze strony filmiku i publiczny endpoint oEmbed TikToka),
2. przerabia go przez Claude na uporządkowany przepis po polsku: tytuł, porcje, czasy, składniki, kroki, wskazówki, tagi
   (usuwa hashtagi i emoji, tłumaczy, a brakujące kroki uzupełnia z adnotacją „Uzupełnione:”).
   Nazwę dania nadaje automatycznie (można ją zmienić ✏️) i dobiera do niego emoji,
3. zapisuje miniaturkę filmiku na serwerze, bo linki TikToka wygasają po kilku dniach.
   Gdy miniaturki nie ma, pokazuje kafelek z emoji dania,
4. zapisuje przepis, żeby był pod ręką: lista, wyszukiwarka (po nazwie, składnikach i tagach), ulubione, własne notatki,
   odhaczanie składników i kroków podczas gotowania, link do oryginalnego filmiku.

Gdy przepis jest tylko mówiony w filmiku, aplikacja bierze go z automatycznych napisów TikToka. Nie każdy filmik je ma.
Jeśli nie ma ich ani przepisu w opisie, wpisz przepis (albo jego część) w pole **Notatki**. Wersja webowa nie rozpoznaje
mowy sama; robi to aplikacja na iPhone'a.

## Uruchomienie

Wymaga Node.js 20+ i klucza API Anthropic.

```bash
cd przepisy-tiktok
npm install
export ANTHROPIC_API_KEY=sk-ant-...
npm start          # http://localhost:3000
```

Zmienne środowiskowe (opcjonalne):

| Zmienna | Domyślnie | Opis |
|---|---|---|
| `PORT` | `3000` | port serwera |
| `DATA_DIR` | `./data` | gdzie zapisywać `recipes.json` |
| `CLAUDE_MODEL` | `claude-opus-5-5` | model użyty do przetwarzania opisów |

## Na telefonie

Aplikacja jest PWA. Wystaw ją pod adresem HTTPS (np. Render, Fly.io, Railway albo własny serwer) i otwórz w Chrome na
Androidzie, potem „Dodaj do ekranu głównego”. Od tej chwili w TikToku: **Udostępnij → Więcej → Przepisy**,
a przepis zapisze się automatycznie.

Na iPhonie Safari nie obsługuje udostępniania do aplikacji webowych, więc tam kopiujesz link w TikToku i wklejasz go w aplikacji.

## Testy

```bash
npm test
```

## Struktura

- `src/tiktok.js`: pobieranie opisu filmiku
- `src/recipe.js`: prompt i schemat JSON przepisu (Claude, structured outputs)
- `src/store.js`: zapis przepisów w pliku JSON
- `src/server.js`: API (`GET/POST /api/recipes`, `GET/PATCH/DELETE /api/recipes/:id`) i pliki statyczne
- `public/`: interfejs (jeden plik HTML), manifest PWA z `share_target`, service worker
