// Wspólna logika kuchenna (przeglądarka + testy w Node): porcje, jednostki, języki przepisów, lista zakupów.
// Jednostki i działy sklepu są zapisywane jako stałe kody (np. "tbsp", "produce"), a nazwy w danym języku
// dobierane dopiero przy wyświetlaniu – dzięki temu lista zakupów łączy przepisy w różnych językach.

export const LANGS = ["en", "de", "pl"];

/** Działy sklepu (kody) – w tej kolejności pokazuje je lista zakupów. Ta sama lista jest w schemacie dla Claude. */
export const CATEGORIES = [
  "produce", "meat_fish", "dairy_eggs", "bakery", "pasta_grains", "baking",
  "spices_sauces", "canned", "frozen", "drinks", "other",
];

const CATEGORY_LABELS = {
  produce: { pl: "Warzywa i owoce", de: "Obst & Gemüse", en: "Fruit & vegetables" },
  meat_fish: { pl: "Mięso i ryby", de: "Fleisch & Fisch", en: "Meat & fish" },
  dairy_eggs: { pl: "Nabiał i jajka", de: "Milchprodukte & Eier", en: "Dairy & eggs" },
  bakery: { pl: "Pieczywo", de: "Brot & Backwaren", en: "Bakery" },
  pasta_grains: { pl: "Makarony, ryż i kasze", de: "Nudeln, Reis & Getreide", en: "Pasta, rice & grains" },
  baking: { pl: "Mąka i pieczenie", de: "Mehl & Backzutaten", en: "Baking" },
  spices_sauces: { pl: "Przyprawy i sosy", de: "Gewürze & Soßen", en: "Spices & sauces" },
  canned: { pl: "Konserwy i słoiki", de: "Konserven & Gläser", en: "Canned & jarred" },
  frozen: { pl: "Mrożonki", de: "Tiefkühl", en: "Frozen" },
  drinks: { pl: "Napoje", de: "Getränke", en: "Drinks" },
  other: { pl: "Inne", de: "Sonstiges", en: "Other" },
};

/**
 * Kody jednostek i ich nazwy w językach interfejsu. Formy są według kategorii liczby mnogiej
 * (Intl.PluralRules: one/two/few/many/other) plus "fraction" dla ułamków – nowy język to tylko nowy wpis.
 * Dla języków spoza tabeli używane są angielskie skróty.
 */
const F = (one, few, many, fraction) => ({ one, few, many, other: many, fraction });
const E = (one, other = one) => ({ one, other });
export const UNITS = {
  g: { pl: E("g"), de: E("g"), en: E("g") },
  ml: { pl: E("ml"), de: E("ml"), en: E("ml") },
  tbsp: { pl: F("łyżka", "łyżki", "łyżek", "łyżki"), de: E("EL"), en: E("tbsp") },
  tsp: { pl: F("łyżeczka", "łyżeczki", "łyżeczek", "łyżeczki"), de: E("TL"), en: E("tsp") },
  cup: { pl: F("szklanka", "szklanki", "szklanek", "szklanki"), de: E("Tasse", "Tassen"), en: E("cup", "cups") },
  pc: { pl: E("szt."), de: E("Stk."), en: E("") },
  clove: { pl: F("ząbek", "ząbki", "ząbków", "ząbka"), de: E("Zehe", "Zehen"), en: E("clove", "cloves") },
  pinch: { pl: F("szczypta", "szczypty", "szczypt", "szczypty"), de: E("Prise", "Prisen"), en: E("pinch", "pinches") },
  bunch: { pl: F("pęczek", "pęczki", "pęczków", "pęczka"), de: E("Bund"), en: E("bunch", "bunches") },
  pack: { pl: F("opakowanie", "opakowania", "opakowań", "opakowania"), de: E("Packung", "Packungen"), en: E("pack", "packs") },
  slice: { pl: F("plaster", "plastry", "plastrów", "plastra"), de: E("Scheibe", "Scheiben"), en: E("slice", "slices") },
  can: { pl: F("puszka", "puszki", "puszek", "puszki"), de: E("Dose", "Dosen"), en: E("can", "cans") },
  handful: { pl: F("garść", "garście", "garści", "garści"), de: E("Handvoll"), en: E("handful", "handfuls") },
  cube: { pl: F("kostka", "kostki", "kostek", "kostki"), de: E("Würfel"), en: E("cube", "cubes") },
  jar: { pl: F("słoik", "słoiki", "słoików", "słoika"), de: E("Glas", "Gläser"), en: E("jar", "jars") },
};

// ---------- Języki ----------

/** Główny podtag języka, np. "zh-Hant" → "zh". */
export const baseLang = (tag) => String(tag || "").split(/[-_]/)[0].toLowerCase();

/**
 * Kod języka przepisu z ustawień przeglądarki/telefonu (BCP 47). Zostawiamy pismo tam, gdzie ma znaczenie:
 * chiński tradycyjny vs uproszczony, serbski cyrylica vs łacinka; regiony pomijamy.
 */
export function normalizeLangTag(tag) {
  const parts = String(tag || "en").replace(/_/g, "-").split("-");
  const lang = parts[0].toLowerCase() || "en";
  const script = parts.slice(1).find((p) => /^[A-Za-z]{4}$/.test(p));
  const region = parts.slice(1).find((p) => /^([A-Za-z]{2}|\d{3})$/.test(p))?.toUpperCase();
  if (lang === "zh") {
    const traditional = script ? /^hant$/i.test(script) : ["TW", "HK", "MO"].includes(region);
    return traditional ? "zh-Hant" : "zh-Hans";
  }
  return script ? `${lang}-${script[0].toUpperCase()}${script.slice(1).toLowerCase()}` : lang;
}

const RTL = new Set(["ar", "he", "iw", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ckb", "syr", "arc", "ku-Arab"]);

/** Czy język pisze się od prawej do lewej (arabski, hebrajski, perski, urdu…). */
export function isRTL(tag) {
  if (!tag) return false;
  try {
    const loc = new Intl.Locale(tag);
    const info = loc.getTextInfo?.() ?? loc.textInfo;
    if (info?.direction) return info.direction === "rtl";
  } catch {}
  return RTL.has(tag) || RTL.has(baseLang(tag));
}

/** Atrybuty HTML dla bloku tekstu w danym języku (poprawne znaki CJK i kierunek pisma). */
export const langAttrs = (tag) => (tag ? `lang="${tag}" dir="${isRTL(tag) ? "rtl" : "ltr"}"` : `dir="auto"`);

// Starsze przepisy zapisywały polskie słowa zamiast kodów
const LEGACY_UNITS = {
  "łyżka": "tbsp", "łyżeczka": "tsp", "szklanka": "cup", "szt.": "pc", "szt": "pc", "ząbek": "clove",
  "szczypta": "pinch", "pęczek": "bunch", "opakowanie": "pack", "plaster": "slice", "puszka": "can",
  "garść": "handful", "kostka": "cube", "słoik": "jar",
};
const LEGACY_CATEGORIES = Object.fromEntries(Object.entries(CATEGORY_LABELS).map(([code, l]) => [l.pl, code]));

export const unitCode = (u) => (UNITS[u] ? u : LEGACY_UNITS[(u || "").trim()] ?? (u || "").trim());
export const categoryCode = (c) => (CATEGORY_LABELS[c] ? c : LEGACY_CATEGORIES[c] || "other");
export const categoryLabel = (code, lang) => CATEGORY_LABELS[categoryCode(code)][lang] || CATEGORY_LABELS[categoryCode(code)].en;

function unitForm(unit, n, lang) {
  const byLang = UNITS[unit];
  if (!byLang) return unit; // nieznana jednostka – pokazujemy tak, jak przyszła
  const forms = byLang[lang] || byLang[baseLang(lang)] || byLang.en;
  if (!Number.isInteger(n)) return forms.fraction ?? (n <= 1 ? forms.one : forms.other) ?? forms.other;
  let cat = "other";
  try { cat = new Intl.PluralRules(lang).select(n); } catch {}
  return forms[cat] ?? forms.other ?? forms.one;
}

const FRACTIONS = { 0.25: "¼", 0.5: "½", 0.75: "¾" };

/** Liczba w zapisie danego języka (przecinek/kropka, cyfry), bez separatorów tysięcy. */
function decimal(n, digits, lang) {
  try {
    return new Intl.NumberFormat(lang, { maximumFractionDigits: digits, useGrouping: false }).format(n);
  } catch {
    return String(Math.round(n * 10 ** digits) / 10 ** digits);
  }
}

/** Ładnie zaokrąglona ilość z jednostką, np. (1250, "g", "pl") → "1,25 kg", (1.5, "tbsp", "pl") → "1½ łyżki". */
export function formatAmount(value, unit = "", lang = "pl") {
  if (!value || value <= 0) return "";
  unit = unitCode(unit);

  if (unit === "g" || unit === "ml") {
    if (value >= 1000) return `${decimal(value / 1000, 2, lang)} ${unit === "g" ? "kg" : "l"}`;
    const rounded = value >= 100 ? Math.round(value / 5) * 5 : value >= 10 ? Math.round(value) : Math.round(value * 10) / 10;
    return `${decimal(rounded, 1, lang)} ${unit}`;
  }

  // Sztuki, łyżki itp. – do ćwiartek, z ułamkami ¼ ½ ¾
  let text, n;
  if (value < 0.125) {
    n = Math.round(value * 100) / 100;
    text = decimal(n, 2, lang);
  } else {
    n = Math.round(value * 4) / 4;
    const whole = Math.floor(n);
    const frac = FRACTIONS[n - whole] || "";
    text = whole ? `${decimal(whole, 0, lang)}${frac}` : frac;
  }
  const label = unit ? unitForm(unit, n, lang) : "";
  return label ? `${text} ${label}` : text;
}

/** Ujednolica przepis – także stare wpisy (polskie jednostki, ilość jako tekst, kroki jako same napisy). */
export function normalizeRecipe(r) {
  const count = r.servings_count > 0 ? r.servings_count : parseInt(r.servings, 10) || 1;
  return {
    ...r,
    language: r.language || "pl", // przepisy sprzed wersji wielojęzycznej były po polsku
    source_language: r.source_language || "",
    translations: r.translations || {},
    servings_count: count,
    ingredients: (r.ingredients || []).map((i) => ({
      group: i.group || "",
      name: i.name || "",
      unit: unitCode(i.unit),
      note: i.note ?? (i.per_portion == null ? i.amount || "" : ""),
      category: categoryCode(i.category),
      per_portion: typeof i.per_portion === "number" ? i.per_portion : 0,
    })),
    steps: (r.steps || []).map((s) => (typeof s === "string" ? { text: s, minutes: 0 } : s)),
  };
}

/**
 * Przepis z tekstem w danym języku: zapisany (jeśli to jego język) albo z zapamiętanego tłumaczenia.
 * Zwraca null, gdy tłumaczenia jeszcze nie ma. Ilości, jednostki i czasy są wspólne dla wszystkich języków.
 */
export function textIn(recipe, lang) {
  const r = normalizeRecipe(recipe);
  if (!lang || lang === r.language) return { ...r, shownLanguage: r.language };
  const tr = r.translations[lang];
  if (!tr) return null;
  return {
    ...r,
    shownLanguage: lang,
    title: tr.title || r.title,
    summary: tr.summary ?? r.summary,
    servings: tr.servings ?? r.servings,
    prep_time: tr.prep_time ?? r.prep_time,
    cook_time: tr.cook_time ?? r.cook_time,
    tips: tr.tips || r.tips,
    tags: tr.tags || r.tags,
    ingredients: r.ingredients.map((i, k) => ({
      ...i,
      group: tr.ingredients?.[k]?.group ?? i.group,
      name: tr.ingredients?.[k]?.name || i.name,
      note: tr.ingredients?.[k]?.note ?? i.note,
    })),
    steps: r.steps.map((s, k) => ({ ...s, text: tr.steps?.[k] || s.text })),
  };
}

/** Tekst przepisu do tłumaczenia (bez liczb – te się nie zmieniają). */
export function translatableText(recipe) {
  const r = normalizeRecipe(recipe);
  return {
    title: r.title || "", summary: r.summary || "", servings: r.servings || "",
    prep_time: r.prep_time || "", cook_time: r.cook_time || "",
    ingredients: r.ingredients.map((i) => ({ group: i.group, name: i.name, note: i.note })),
    steps: r.steps.map((s) => s.text),
    tips: r.tips || [], tags: r.tags || [],
  };
}

/** Liczba porcji do pokazania: wybrana przez użytkownika albo ta z filmiku. */
export function portionsOf(r) {
  return r.portions > 0 ? r.portions : normalizeRecipe(r).servings_count;
}

/** Tekst ilości składnika dla danej liczby porcji (ilości są zapisane na 1 porcję). */
export function ingredientAmount(i, portions, lang = "pl") {
  const amount = formatAmount(i.per_portion * portions, i.unit, lang);
  return [amount, i.note].filter(Boolean).join(", ");
}

/** Nazwa do porównań: ta sama postać Unicode (np. znaki pełnej szerokości), małe litery, pojedyncze spacje. */
export const normName = (s) => String(s || "").normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();

/** Skraca tekst bez przecinania znaków złożonych (emoji, znaki z akcentami, sylaby hangul). */
export function truncate(text, max) {
  const s = String(text || "");
  let parts;
  try {
    parts = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(s)].map((x) => x.segment);
  } catch {
    parts = Array.from(s);
  }
  return parts.length > max ? parts.slice(0, max).join("") + "…" : s;
}

/** Własna pozycja listy zakupów. Starsze wersje zapisywały same napisy – też je przyjmujemy. */
export function normalizeExtra(e, i = 0) {
  if (typeof e === "string") return { id: `old-${i}-${normName(e)}`, name: e.trim(), amount: "", category: "other" };
  return {
    id: String(e?.id || `x-${i}`),
    name: String(e?.name || "").trim(),
    amount: String(e?.amount || "").trim(),
    category: categoryCode(e?.category),
  };
}

/** Dział sklepu dla nazwy wpisanej ręcznie – podpowiedź na podstawie składników z zapisanych przepisów. */
export function guessCategory(name, recipes = []) {
  const n = normName(name);
  if (!n) return "other";
  for (const raw of recipes) {
    const r = normalizeRecipe(raw);
    for (const [k, i] of r.ingredients.entries()) {
      const names = [i.name, ...Object.values(r.translations).map((t) => t.ingredients?.[k]?.name)];
      if (names.some((x) => normName(x) === n)) return i.category;
    }
  }
  return "other";
}

/**
 * Lista zakupów z wybranych przepisów i własnych pozycji, z nazwami w języku `lang`
 * (z tłumaczenia przepisu, jeśli jest; inaczej w języku, w którym przepis zapisano).
 * entries:   [{ recipe, portions }]
 * extras:    [{ id, name, amount, category }]   – dopisane ręcznie
 * overrides: { [klucz]: { name?, amount?, removed? } } – ręczne zmiany pozycji wyliczonych z przepisów
 * Zwraca { groups: [{ category, label, items: [...] }], removed: [...] }.
 * Te same składniki (nazwa + jednostka) są sumowane.
 */
export function buildShoppingList(entries, extras = [], overrides = {}, lang = "pl") {
  const byKey = new Map();
  for (const { recipe, portions } of entries) {
    const r = textIn(recipe, lang) || textIn(recipe);
    for (const i of r.ingredients) {
      if (!i.name) continue;
      const hasQty = i.per_portion > 0;
      const key = `${normName(i.name)}|${hasQty ? i.unit : "-"}`;
      const item = byKey.get(key) || {
        key, name: i.name, unit: i.unit, qty: 0, notes: new Set(), category: i.category, recipes: new Set(),
      };
      if (hasQty) item.qty += i.per_portion * portions;
      else if (i.note) item.notes.add(i.note);
      item.recipes.add(r.title);
      byKey.set(key, item);
    }
  }

  const groups = CATEGORIES.map((category) => ({ category, label: categoryLabel(category, lang), items: [] }));
  const removed = [];
  for (const item of byKey.values()) {
    const amount = [formatAmount(item.qty, item.unit, lang), ...item.notes].filter(Boolean).join(", ");
    const o = overrides[item.key] || {};
    const out = {
      key: item.key,
      name: o.name || item.name,
      amount: o.amount ?? amount,
      recipes: [...item.recipes],
      extra: false,
      edited: o.name != null || o.amount != null,
      original: { name: item.name, amount },
    };
    if (o.removed) removed.push(out);
    else groups.find((g) => g.category === item.category).items.push(out);
  }
  extras.map(normalizeExtra).filter((e) => e.name).forEach((e) => {
    groups.find((g) => g.category === e.category).items.push({
      key: `extra|${e.id}`, id: e.id, name: e.name, amount: e.amount, category: e.category,
      recipes: [], extra: true, edited: false,
    });
  });
  for (const g of groups) g.items.sort((a, b) => a.name.localeCompare(b.name, lang));
  return { groups: groups.filter((g) => g.items.length), removed };
}

/** Lista zakupów jako zwykły tekst (do skopiowania / wysłania). */
export function shoppingListText(groups, checked = []) {
  const done = new Set(checked);
  return groups
    .map((g) => {
      const items = g.items.filter((i) => !done.has(i.key));
      if (!items.length) return "";
      return `${g.label}:\n` + items.map((i) => `• ${i.name}${i.amount ? ` – ${i.amount}` : ""}`).join("\n");
    })
    .filter(Boolean)
    .join("\n\n");
}

/** Czas minutnika jako tekst, np. 90 → "1:30", 3700 → "1:01:40". */
export function formatClock(seconds) {
  seconds = Math.max(0, Math.ceil(seconds));
  const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = seconds % 60;
  const mm = h ? String(m).padStart(2, "0") : String(m);
  return `${h ? h + ":" : ""}${mm}:${String(s).padStart(2, "0")}`;
}
