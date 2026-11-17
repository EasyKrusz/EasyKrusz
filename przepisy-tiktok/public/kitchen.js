// Wspólna logika kuchenna (przeglądarka + testy w Node): porcje, formatowanie ilości, lista zakupów.

/** Działy sklepu – w tej kolejności pokazuje je lista zakupów. Ta sama lista jest w schemacie dla Claude. */
export const CATEGORIES = [
  "Warzywa i owoce",
  "Mięso i ryby",
  "Nabiał i jajka",
  "Pieczywo",
  "Makarony, ryż i kasze",
  "Mąka i pieczenie",
  "Przyprawy i sosy",
  "Konserwy i słoiki",
  "Mrożonki",
  "Napoje",
  "Inne",
];

// Odmiana jednostek: [1, 2-4, 5+, ułamek]
const FORMS = {
  "łyżka": ["łyżka", "łyżki", "łyżek", "łyżki"],
  "łyżeczka": ["łyżeczka", "łyżeczki", "łyżeczek", "łyżeczki"],
  "szklanka": ["szklanka", "szklanki", "szklanek", "szklanki"],
  "ząbek": ["ząbek", "ząbki", "ząbków", "ząbka"],
  "szczypta": ["szczypta", "szczypty", "szczypt", "szczypty"],
  "pęczek": ["pęczek", "pęczki", "pęczków", "pęczka"],
  "opakowanie": ["opakowanie", "opakowania", "opakowań", "opakowania"],
  "plaster": ["plaster", "plastry", "plastrów", "plastra"],
  "puszka": ["puszka", "puszki", "puszek", "puszki"],
  "garść": ["garść", "garście", "garści", "garści"],
  "kostka": ["kostka", "kostki", "kostek", "kostki"],
  "słoik": ["słoik", "słoiki", "słoików", "słoika"],
};

function unitForm(unit, n) {
  const forms = FORMS[unit];
  if (!forms) return unit;
  if (!Number.isInteger(n)) return forms[3];
  if (n === 1) return forms[0];
  const d = n % 10, t = n % 100;
  return d >= 2 && d <= 4 && (t < 12 || t > 14) ? forms[1] : forms[2];
}

const FRACTIONS = { 0.25: "¼", 0.5: "½", 0.75: "¾" };

function decimal(n, digits = 1) {
  return String(Math.round(n * 10 ** digits) / 10 ** digits).replace(".", ",");
}

/** Ładnie zaokrąglona ilość z jednostką, np. formatAmount(1250, "g") → "1,25 kg", (1.5, "łyżka") → "1½ łyżki". */
export function formatAmount(value, unit = "") {
  if (!value || value <= 0) return "";
  unit = (unit || "").trim();

  if (unit === "g" || unit === "ml") {
    if (value >= 1000) return `${decimal(value / 1000, 2)} ${unit === "g" ? "kg" : "l"}`;
    const rounded = value >= 100 ? Math.round(value / 5) * 5 : value >= 10 ? Math.round(value) : Math.round(value * 10) / 10;
    return `${decimal(rounded)} ${unit}`;
  }

  // Sztuki, łyżki itp. – do ćwiartek, z ułamkami ¼ ½ ¾
  let text, n;
  if (value < 0.125) {
    n = Math.round(value * 100) / 100;
    text = decimal(n, 2);
  } else {
    n = Math.round(value * 4) / 4;
    const whole = Math.floor(n);
    const frac = FRACTIONS[n - whole] || "";
    text = whole ? `${whole}${frac}` : frac;
  }
  return unit ? `${text} ${unitForm(unit, n)}` : text;
}

/** Ujednolica przepis – także stare wpisy (ilość jako tekst, kroki jako same napisy). */
export function normalizeRecipe(r) {
  const count = r.servings_count > 0 ? r.servings_count : parseInt(r.servings, 10) || 1;
  return {
    ...r,
    servings_count: count,
    ingredients: (r.ingredients || []).map((i) => ({
      group: i.group || "",
      name: i.name || "",
      unit: i.unit || "",
      note: i.note ?? (i.per_portion == null ? i.amount || "" : ""),
      category: CATEGORIES.includes(i.category) ? i.category : "Inne",
      per_portion: typeof i.per_portion === "number" ? i.per_portion : 0,
    })),
    steps: (r.steps || []).map((s) => (typeof s === "string" ? { text: s, minutes: 0 } : s)),
  };
}

/** Liczba porcji do pokazania: wybrana przez użytkownika albo ta z filmiku. */
export function portionsOf(r) {
  return r.portions > 0 ? r.portions : normalizeRecipe(r).servings_count;
}

/** Tekst ilości składnika dla danej liczby porcji (ilości są zapisane na 1 porcję). */
export function ingredientAmount(i, portions) {
  const amount = formatAmount(i.per_portion * portions, i.unit);
  return [amount, i.note].filter(Boolean).join(", ");
}

const normName = (s) => s.toLowerCase().replace(/\s+/g, " ").trim();

/**
 * Lista zakupów z wybranych przepisów.
 * entries: [{ recipe, portions }]  →  [{ category, items: [{ key, name, amount, recipes: [tytuły] }] }]
 * Te same składniki (nazwa + jednostka) są sumowane.
 */
export function buildShoppingList(entries, extras = []) {
  const byKey = new Map();
  for (const { recipe, portions } of entries) {
    const r = normalizeRecipe(recipe);
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
  for (const text of extras) {
    const key = `extra|${normName(text)}`;
    byKey.set(key, { key, name: text, unit: "", qty: 0, notes: new Set(), category: "Inne", recipes: new Set(), extra: true });
  }

  const groups = CATEGORIES.map((category) => ({ category, items: [] }));
  for (const item of byKey.values()) {
    const amount = [formatAmount(item.qty, item.unit), ...item.notes].filter(Boolean).join(", ");
    groups.find((g) => g.category === item.category).items.push({
      key: item.key, name: item.name, amount, recipes: [...item.recipes], extra: !!item.extra,
    });
  }
  for (const g of groups) g.items.sort((a, b) => a.name.localeCompare(b.name, "pl"));
  return groups.filter((g) => g.items.length);
}

/** Lista zakupów jako zwykły tekst (do skopiowania / wysłania). */
export function shoppingListText(groups, checked = []) {
  const done = new Set(checked);
  return groups
    .map((g) => {
      const items = g.items.filter((i) => !done.has(i.key));
      if (!items.length) return "";
      return `${g.category}:\n` + items.map((i) => `• ${i.name}${i.amount ? ` – ${i.amount}` : ""}`).join("\n");
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
