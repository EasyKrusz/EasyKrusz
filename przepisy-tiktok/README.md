# Przepisy z TikToka

Wklejasz link do filmiku z TikToka (albo udostępniasz go prosto z aplikacji TikTok), a aplikacja:

1. pobiera opis filmiku (publiczny endpoint oEmbed TikToka, awaryjnie dane ze strony filmiku),
2. przerabia go przez Claude na uporządkowany przepis po polsku: tytuł, porcje, czasy, składniki, kroki, wskazówki, tagi
   (usuwa hashtagi i emoji, tłumaczy, a brakujące kroki uzupełnia z adnotacją „Uzupełnione:”),
3. zapisuje go, żeby był pod ręką: lista, wyszukiwarka (po nazwie, składnikach i tagach), ulubione, własne notatki,
   odhaczanie składników i kroków podczas gotowania, link do oryginalnego filmiku.

Często przepis jest tylko mówiony w filmiku, a w opisie go nie ma. Wtedy wpisz go (albo jego część) w pole **Notatki**,
a aplikacja połączy to z opisem.

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
