// Zamiana surowego opisu z TikToka w uporządkowany przepis (Claude API, structured outputs).
import Anthropic from "@anthropic-ai/sdk";
import { CATEGORIES } from "../public/kitchen.js";

const client = new Anthropic();
const MODEL = process.env.CLAUDE_MODEL || "claude-sonnet-5-5";

const RECIPE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: [
    "is_recipe",
    "title",
    "emoji",
    "summary",
    "servings",
    "servings_count",
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
    servings: { type: "string", description: "Np. '4 porcje' albo 'blacha 25×35 cm (12 kawałków)'." },
    servings_count: {
      type: "integer",
      description: "Na ile porcji są podane ilości składników. Jeśli nie podano, oszacuj (np. 400 g makaronu ≈ 4 porcje); dla ciast – liczba kawałków.",
    },
    prep_time: { type: "string", description: "Np. '15 min'. Pusty, jeśli nieznane." },
    cook_time: { type: "string", description: "Np. '25 min'. Pusty, jeśli nieznane." },
    ingredients: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["group", "name", "quantity", "unit", "note", "category"],
        properties: {
          group: {
            type: "string",
            description: "Sekcja, np. 'Ciasto', 'Sos'. Pusty, jeśli przepis nie ma sekcji.",
          },
          name: { type: "string", description: "Nazwa składnika w mianowniku, np. 'cebula', 'mąka pszenna'." },
          quantity: {
            type: "number",
            description: "Ilość na CAŁY przepis (na servings_count porcji), jako liczba. 0, jeśli nie da się jej podać (np. 'do smaku').",
          },
          unit: {
            type: "string",
            description: "Jedna z: g, ml, łyżka, łyżeczka, szklanka, szt., ząbek, szczypta, pęczek, opakowanie, plaster, puszka, garść, kostka, słoik. Kilogramy i litry przelicz na g i ml. Pusty, gdy quantity = 0.",
          },
          note: { type: "string", description: "Dopisek, np. 'do smaku', 'opcjonalnie', 'pokrojona w kostkę'. Zwykle pusty." },
          category: {
            type: "string",
            enum: CATEGORIES,
            description: "Dział sklepu, w którym kupuje się ten składnik.",
          },
        },
      },
    },
    steps: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["text", "minutes"],
        properties: {
          text: { type: "string" },
          minutes: {
            type: "number",
            description: "Ile minut trwa czekanie w tym kroku (pieczenie, gotowanie, odpoczynek ciasta) – do minutnika. Dla zakresu podaj dolną granicę. 0, jeśli krok nie wymaga odmierzania czasu.",
          },
        },
      },
    },
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
- Zachowaj ilości z opisu, podając je jako liczby w polu quantity (np. "pół szklanki" → 0.5 + "szklanka", "1,5 kg" → 1500 + "g"). Zamień skróty typu "tbsp" na "łyżka", "tsp" na "łyżeczka", "cup" na "szklanka". Ilości mają odpowiadać servings_count porcjom – nie dziel ich sam.
- Jeśli czegoś brakuje (np. kroków, a są tylko składniki), uzupełnij rozsądnie na podstawie wiedzy kulinarnej i zaznacz to w "tips" zdaniem zaczynającym się od "Uzupełnione:".
- Nie wymyślaj czasu przygotowania, jeśli nie da się go sensownie oszacować - zostaw pusty tekst.
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
  return toPerPortion(JSON.parse(text));
}

/** Zapisujemy ilości na 1 porcję – potem wystarczy je pomnożyć przez wybraną liczbę porcji. */
export function toPerPortion(recipe) {
  const count = recipe.servings_count > 0 ? recipe.servings_count : 1;
  return {
    ...recipe,
    servings_count: count,
    ingredients: (recipe.ingredients || []).map(({ quantity, ...i }) => ({
      ...i,
      unit: quantity > 0 ? i.unit : "",
      per_portion: quantity > 0 ? quantity / count : 0,
    })),
  };
}
