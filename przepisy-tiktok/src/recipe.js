// Zamiana opisu / transkrypcji z TikToka w uporządkowany przepis i tłumaczenie przepisów (Claude API, structured outputs).
import Anthropic from "@anthropic-ai/sdk";
import { CATEGORIES, SOURCE_UNITS, canonicalUnit, translatableText } from "../public/kitchen.js";

const client = new Anthropic();
const MODEL = process.env.CLAUDE_MODEL || "claude-sonnet-5-5";

const UNIT_CODES = SOURCE_UNITS;

/** Nazwa języka po angielsku dla promptu, np. "ko" → "Korean". */
export function languageName(code) {
  try {
    return new Intl.DisplayNames(["en"], { type: "language" }).of(code) || code;
  } catch {
    return code;
  }
}

const str = (description) => (description ? { type: "string", description } : { type: "string" });
const obj = (properties) => ({
  type: "object", additionalProperties: false, required: Object.keys(properties), properties,
});

const RECIPE_SCHEMA = obj({
  is_recipe: {
    type: "boolean",
    description: "Whether the sources contain a recipe (or enough information to reconstruct one).",
  },
  source_language: str("BCP 47 tag of the language the video is in (caption/speech): a 2-letter code like 'ko', 'en', 'ar', plus the script for Chinese ('zh-Hans' or 'zh-Hant')."),
  title: str("Short, natural name of the dish (2-6 words), no emoji, quotes or author name."),
  emoji: str("One emoji that best fits the dish, e.g. 🍝."),
  summary: str("1-2 sentences about the dish."),
  servings: str("E.g. '4 servings' or 'baking tray 25×35 cm (12 pieces)'."),
  servings_count: {
    type: "integer",
    description: "How many servings the ingredient quantities are for. If not given, estimate (e.g. 400 g pasta ≈ 4); for cakes use the number of pieces.",
  },
  prep_time: str("E.g. '15 min'. Empty if unknown."),
  cook_time: str("E.g. '25 min'. Empty if unknown."),
  ingredients: {
    type: "array",
    items: obj({
      group: str("Section, e.g. 'Dough', 'Sauce'. Empty if the recipe has no sections."),
      name: str("Ingredient name in its base form, e.g. 'onion', 'wheat flour'."),
      quantity: {
        type: "number",
        description: "Quantity for the WHOLE recipe (servings_count servings) as a number. 0 if it cannot be given (e.g. 'to taste').",
      },
      unit: {
        type: "string",
        enum: [...UNIT_CODES, ""],
        description: "Unit code, in the unit system used in the source (metric or US – do not convert between them). Use 'pc' for countable items. Empty when quantity is 0.",
      },
      note: str("Short remark, e.g. 'to taste', 'optional', 'diced'. Usually empty."),
      category: { type: "string", enum: CATEGORIES, description: "Supermarket section where you buy it." },
    }),
  },
  steps: {
    type: "array",
    items: obj({
      text: { type: "string" },
      minutes: {
        type: "number",
        description: "Minutes of waiting in this step (baking, simmering, resting dough) for a kitchen timer. Use the lower bound of a range. 0 if no timing is needed.",
      },
    }),
  },
  tips: { type: "array", items: { type: "string" } },
  tags: { type: "array", items: { type: "string" }, description: "3-6 short lowercase tags." },
});

const TRANSLATION_SCHEMA = obj({
  title: { type: "string" },
  summary: { type: "string" },
  servings: { type: "string" },
  prep_time: { type: "string" },
  cook_time: { type: "string" },
  ingredients: { type: "array", items: obj({ group: { type: "string" }, name: { type: "string" }, note: { type: "string" } }) },
  steps: { type: "array", items: { type: "string" } },
  tips: { type: "array", items: { type: "string" } },
  tags: { type: "array", items: { type: "string" } },
});

const recipeSystem = (lang) => `You are a cooking assistant. You get the caption of a TikTok video, sometimes an automatic transcript of what the creator says, and sometimes notes from the user.
Turn them into a clear, complete recipe.

Rules:
- Write ALL text (title, ingredient names, notes, steps, tips, tags, servings) in ${languageName(lang)}, whatever language the video is in, using that language's normal script and punctuation. Translate when needed.
- Use all sources together. The transcript comes from automatic speech recognition: fix obvious mistakes (e.g. similar-sounding ingredient names) and skip chatter unrelated to cooking.
- The title should say what the dish is (e.g. "Creamy zucchini spaghetti"), not repeat a catchy video title.
- Remove hashtags, emoji, @mentions, calls to follow and similar noise.
- Steps must be concrete and in the order they are done; one step = one action or a short group of actions.
- Keep the quantities and units from the sources and give them as numbers in "quantity" (e.g. "half a cup" → 0.5 + "cup", "1.5 kg" → 1.5 + "kg", "8 oz" → 8 + "oz"). Do not convert between metric and US units – the app does that. Quantities must match servings_count servings – do not divide them yourself.
- Keep oven temperatures as in the source, written with a degree sign (e.g. "180°C", "350°F").
- If something is missing (e.g. there are ingredients but no steps), fill it in sensibly from cooking knowledge and mention it in "tips".
- Do not invent preparation times that cannot be reasonably estimated – leave them empty.
- If none of the sources contain a recipe or the name of a dish, set is_recipe to false and briefly say in "summary" what is missing.`;

async function ask({ system, user, schema }) {
  const response = await client.beta.messages.create({
    model: MODEL,
    max_tokens: 16000,
    system,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low", format: { type: "json_schema", schema } },
    messages: [{ role: "user", content: user }],
  });
  if (response.stop_reason === "refusal") throw Object.assign(new Error("Model refused"), { code: "refusal" });
  if (response.stop_reason === "max_tokens") throw Object.assign(new Error("Response truncated"), { code: "truncated" });
  return JSON.parse(response.content.filter((b) => b.type === "text").map((b) => b.text).join(""));
}

/** Przepis w języku `language` (kod ISO, np. "de") z opisu, transkrypcji i notatek. */
export async function buildRecipe({ description, transcript, notes, author, language = "en" }) {
  const user = [
    author ? `Video author: @${author}` : "",
    `Video caption:\n"""\n${description || "(none)"}\n"""`,
    transcript ? `Transcript of the speech in the video (automatic, may contain errors):\n"""\n${transcript}\n"""` : "",
    notes ? `User notes (e.g. typed from the video):\n"""\n${notes}\n"""` : "",
  ].filter(Boolean).join("\n\n");

  const recipe = await ask({ system: recipeSystem(language), user, schema: RECIPE_SCHEMA });
  return { ...toPerPortion(recipe), language };
}

/** Zapisujemy ilości na 1 porcję – potem wystarczy je pomnożyć przez wybraną liczbę porcji. */
export function toPerPortion(recipe) {
  const count = recipe.servings_count > 0 ? recipe.servings_count : 1;
  return {
    ...recipe,
    servings_count: count,
    ingredients: (recipe.ingredients || []).map(({ quantity, ...i }) => {
      // oz → g, lb → g, fl oz → ml, kg → g… – zapisujemy w jednym systemie, przeliczamy przy wyświetlaniu
      const c = canonicalUnit(quantity, i.unit);
      return { ...i, unit: c.quantity > 0 ? c.unit : "", per_portion: c.quantity > 0 ? c.quantity / count : 0 };
    }),
  };
}

/** Tłumaczenie tekstu przepisu na `language`. Liczby, jednostki i kolejność pozycji się nie zmieniają. */
export async function translateRecipe(recipe, language) {
  const source = translatableText(recipe);
  const out = await ask({
    system: `You translate recipes into ${languageName(language)}. Translate every text field naturally, as a native cook would write it. Keep the same number and order of ingredients, steps, tips and tags. Keep empty strings empty.`,
    user: JSON.stringify(source),
    schema: TRANSLATION_SCHEMA,
  });
  if (out.ingredients.length !== source.ingredients.length || out.steps.length !== source.steps.length) {
    throw Object.assign(new Error("Translation does not match the recipe"), { code: "translation_mismatch" });
  }
  return out;
}
