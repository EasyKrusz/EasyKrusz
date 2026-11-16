// Zamiana surowego opisu z TikToka w uporządkowany przepis (Claude API, structured outputs).
import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic();
const MODEL = process.env.CLAUDE_MODEL || "claude-opus-5-5";

const RECIPE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: [
    "is_recipe",
    "title",
    "emoji",
    "summary",
    "servings",
    "prep_time",
    "cook_time",
    "ingredients",
    "steps",
    "tips",
    "tags",
  ],
  properties: {
    is_recipe: {
      type: "boolean",
      description: "Czy w opisie w ogóle jest przepis (lub wystarczająco informacji, by go odtworzyć).",
    },
    title: {
      type: "string",
      description: "Krótka, naturalna nazwa dania po polsku (2-6 słów), bez emoji, cudzysłowów i nazwy autora.",
    },
    emoji: { type: "string", description: "Jedno emoji najlepiej pasujące do dania, np. 🍝." },
    summary: { type: "string", description: "1-2 zdania o daniu." },
    servings: { type: "string", description: "Np. '2 porcje'. Pusty, jeśli nieznane." },
    prep_time: { type: "string", description: "Np. '15 min'. Pusty, jeśli nieznane." },
    cook_time: { type: "string", description: "Np. '25 min'. Pusty, jeśli nieznane." },
    ingredients: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["group", "name", "amount"],
        properties: {
          group: {
            type: "string",
            description: "Sekcja, np. 'Ciasto', 'Sos'. Pusty, jeśli przepis nie ma sekcji.",
          },
          name: { type: "string" },
          amount: { type: "string", description: "Ilość z jednostką, np. '200 g'. Pusty, jeśli brak." },
        },
      },
    },
    steps: { type: "array", items: { type: "string" } },
    tips: { type: "array", items: { type: "string" } },
    tags: { type: "array", items: { type: "string" }, description: "3-6 krótkich tagów, małymi literami." },
  },
};

const SYSTEM = `Jesteś asystentem kulinarnym. Dostajesz opis (caption) filmiku z TikToka, czasem automatyczną transkrypcję tego, co mówi autor, i ewentualnie notatki użytkownika.
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
- Jeśli ani opis, ani transkrypcja, ani notatki nie zawierają przepisu ani nazwy dania, ustaw is_recipe na false, a w summary krótko napisz, czego brakuje.`;

export async function buildRecipe({ description, transcript, notes, author }) {
  const userText = [
    author ? `Autor filmiku: @${author}` : "",
    `Opis filmiku:\n"""\n${description || "(brak)"}\n"""`,
    transcript ? `Transkrypcja mowy z filmiku (automatyczna, może zawierać błędy):\n"""\n${transcript}\n"""` : "",
    notes ? `Notatki użytkownika (np. przepisane z filmiku):\n"""\n${notes}\n"""` : "",
  ]
    .filter(Boolean)
    .join("\n\n");

  const response = await client.beta.messages.create({
    model: MODEL,
    max_tokens: 16000,
    system: SYSTEM,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: {
      effort: "low",
      format: { type: "json_schema", schema: RECIPE_SCHEMA },
    },
    messages: [{ role: "user", content: userText }],
  });

  if (response.stop_reason === "refusal") {
    throw new Error("Model odmówił przetworzenia tego opisu.");
  }
  if (response.stop_reason === "max_tokens") {
    throw new Error("Odpowiedź modelu została ucięta - spróbuj ponownie.");
  }
  const text = response.content
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("");
  return JSON.parse(text);
}
