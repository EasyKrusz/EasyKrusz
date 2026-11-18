import { test } from "node:test";
import assert from "node:assert/strict";
import {
  formatAmount, ingredientAmount, normalizeRecipe, portionsOf, buildShoppingList, shoppingListText, formatClock,
  guessCategory, normalizeExtra, textIn, translatableText, categoryLabel,
} from "../public/kitchen.js";
import { toPerPortion } from "../src/recipe.js";

test("formatuje ilości z odmianą jednostek (PL)", () => {
  assert.equal(formatAmount(150, "g"), "150 g");
  assert.equal(formatAmount(152, "g"), "150 g");
  assert.equal(formatAmount(1250, "g"), "1,25 kg");
  assert.equal(formatAmount(1500, "ml"), "1,5 l");
  assert.equal(formatAmount(12.4, "g"), "12 g");
  assert.equal(formatAmount(2.5, "g"), "2,5 g");
  assert.equal(formatAmount(1, "tbsp"), "1 łyżka");
  assert.equal(formatAmount(3, "tbsp"), "3 łyżki");
  assert.equal(formatAmount(5, "tbsp"), "5 łyżek");
  assert.equal(formatAmount(1.5, "tbsp"), "1½ łyżki");
  assert.equal(formatAmount(0.5, "cup"), "½ szklanki");
  assert.equal(formatAmount(0.25, "pc"), "¼ szt.");
  assert.equal(formatAmount(2, "clove"), "2 ząbki");
  assert.equal(formatAmount(12, "clove"), "12 ząbków");
  assert.equal(formatAmount(22, "clove"), "22 ząbki");
  assert.equal(formatAmount(0, "g"), "");
});

test("formatuje ilości po niemiecku i angielsku", () => {
  assert.equal(formatAmount(1250, "g", "de"), "1,25 kg");
  assert.equal(formatAmount(1250, "g", "en"), "1.25 kg");
  assert.equal(formatAmount(2.5, "g", "en"), "2.5 g");
  assert.equal(formatAmount(2, "tbsp", "de"), "2 EL");
  assert.equal(formatAmount(0.5, "cup", "de"), "½ Tasse");
  assert.equal(formatAmount(1.5, "cup", "de"), "1½ Tassen");
  assert.equal(formatAmount(3, "clove", "en"), "3 cloves");
  assert.equal(formatAmount(1, "clove", "en"), "1 clove");
  assert.equal(formatAmount(2, "pc", "en"), "2");
  assert.equal(formatAmount(2, "pc", "de"), "2 Stk.");
  assert.equal(formatAmount(2, "jar", "de"), "2 Gläser");
});

test("stare polskie jednostki i działy są zamieniane na kody", () => {
  assert.equal(formatAmount(2, "łyżka", "de"), "2 EL");
  const r = normalizeRecipe({ title: "x", ingredients: [{ name: "a", unit: "ząbek", per_portion: 1, category: "Warzywa i owoce" }] });
  assert.equal(r.ingredients[0].unit, "clove");
  assert.equal(r.ingredients[0].category, "produce");
  assert.equal(r.language, "pl");
  assert.equal(categoryLabel("produce", "de"), "Obst & Gemüse");
  assert.equal(categoryLabel("Nie ma", "en"), "Other");
});

test("ilości są zapisywane na 1 porcję i mnożone przez liczbę porcji", () => {
  const r = toPerPortion({
    servings_count: 4,
    ingredients: [
      { group: "", name: "makaron", quantity: 400, unit: "g", note: "", category: "pasta_grains" },
      { group: "", name: "jajko", quantity: 2, unit: "pc", note: "", category: "dairy_eggs" },
      { group: "", name: "sól", quantity: 0, unit: "pinch", note: "do smaku", category: "spices_sauces" },
    ],
  });
  assert.equal(r.ingredients[0].per_portion, 100);
  assert.equal(ingredientAmount(r.ingredients[0], 1), "100 g");
  assert.equal(ingredientAmount(r.ingredients[0], 3), "300 g");
  assert.equal(ingredientAmount(r.ingredients[1], 1), "½ szt.");
  assert.equal(ingredientAmount(r.ingredients[1], 6), "3 szt.");
  assert.equal(ingredientAmount(r.ingredients[2], 6), "do smaku");
  assert.equal(r.ingredients[2].unit, "");
});

test("liczba porcji: wybrana przez użytkownika albo z filmiku", () => {
  assert.equal(portionsOf({ servings_count: 4 }), 4);
  assert.equal(portionsOf({ servings_count: 4, portions: 2 }), 2);
  assert.equal(portionsOf({ servings: "2 porcje" }), 2);
});

test("stare przepisy (ilość jako tekst, kroki jako napisy) dalej się wyświetlają", () => {
  const r = normalizeRecipe({ title: "x", ingredients: [{ group: "", name: "mąka", amount: "200 g" }], steps: ["Wymieszaj."] });
  assert.equal(ingredientAmount(r.ingredients[0], 3), "200 g");
  assert.deepEqual(r.steps, [{ text: "Wymieszaj.", minutes: 0 }]);
});

const kimchi = {
  id: "k", title: "Kimchi-Reis", language: "de", source_language: "ko", servings_count: 2,
  summary: "Gebratener Reis.", servings: "2 Portionen", tags: ["reis"], tips: [],
  ingredients: [
    { group: "", name: "Reis", unit: "g", per_portion: 150, note: "", category: "pasta_grains" },
    { group: "", name: "Kimchi", unit: "g", per_portion: 100, note: "gehackt", category: "canned" },
  ],
  steps: [{ text: "Reis braten.", minutes: 5 }],
  translations: {
    ko: {
      title: "김치볶음밥", summary: "볶음밥.", servings: "2인분", tags: ["밥"], tips: [],
      ingredients: [{ group: "", name: "밥", note: "" }, { group: "", name: "김치", note: "다진" }],
      steps: ["밥을 볶는다."],
    },
  },
};

test("tekst przepisu w danym języku: zapisany, z tłumaczenia albo brak", () => {
  assert.equal(textIn(kimchi, "de").title, "Kimchi-Reis");
  const ko = textIn(kimchi, "ko");
  assert.equal(ko.title, "김치볶음밥");
  assert.equal(ko.shownLanguage, "ko");
  assert.equal(ko.ingredients[1].name, "김치");
  assert.equal(ko.ingredients[1].per_portion, 100); // liczby wspólne dla wszystkich języków
  assert.equal(ko.steps[0].minutes, 5);
  assert.equal(textIn(kimchi, "pl"), null); // jeszcze nie przetłumaczony
  assert.deepEqual(translatableText(kimchi).steps, ["Reis braten."]);
});

test("lista zakupów sumuje te same składniki i grupuje według działów", () => {
  const a = { id: "a", title: "Spaghetti", servings_count: 1, ingredients: [
    { name: "Makaron", unit: "g", per_portion: 100, note: "", category: "pasta_grains" },
    { name: "czosnek", unit: "clove", per_portion: 1, note: "", category: "produce" },
    { name: "sól", unit: "", per_portion: 0, note: "do smaku", category: "spices_sauces" },
  ] };
  const b = { id: "b", title: "Zupa", servings_count: 1, ingredients: [
    { name: "czosnek", unit: "clove", per_portion: 0.5, note: "", category: "produce" },
    { name: "makaron", unit: "g", per_portion: 50, note: "", category: "pasta_grains" },
  ] };
  const { groups } = buildShoppingList([{ recipe: a, portions: 2 }, { recipe: b, portions: 4 }], ["papier do pieczenia"], {}, "pl");
  assert.deepEqual(groups.map((g) => g.category), ["produce", "pasta_grains", "spices_sauces", "other"]);
  assert.deepEqual(groups.map((g) => g.label), ["Warzywa i owoce", "Makarony, ryż i kasze", "Przyprawy i sosy", "Inne"]);
  const garlic = groups[0].items[0];
  assert.equal(garlic.amount, "4 ząbki");
  assert.deepEqual(garlic.recipes, ["Spaghetti", "Zupa"]);
  assert.equal(groups[1].items[0].amount, "400 g");
  assert.equal(groups[2].items[0].amount, "do smaku");
  assert.equal(groups[3].items[0].name, "papier do pieczenia");

  const text = shoppingListText(groups, [garlic.key]);
  assert.doesNotMatch(text, /czosnek/);
  assert.match(text, /Makarony, ryż i kasze:\n• Makaron – 400 g/);
});

test("lista zakupów używa nazw w języku użytkownika, gdy jest tłumaczenie", () => {
  const { groups } = buildShoppingList([{ recipe: kimchi, portions: 2 }], [], {}, "ko");
  assert.deepEqual(groups.flatMap((g) => g.items.map((i) => i.name)).sort(), ["김치", "밥"].sort());
  const de = buildShoppingList([{ recipe: kimchi, portions: 2 }], [], {}, "de").groups;
  assert.equal(de[0].label, "Nudeln, Reis & Getreide");
  assert.equal(de[0].items[0].amount, "300 g");
  // brak tłumaczenia na polski → nazwy z zapisanego języka
  const pl = buildShoppingList([{ recipe: kimchi, portions: 2 }], [], {}, "pl").groups;
  assert.equal(pl[0].items[0].name, "Reis");
});

const pasta = { id: "a", title: "Spaghetti", servings_count: 1, ingredients: [
  { name: "makaron", unit: "g", per_portion: 100, note: "", category: "pasta_grains" },
  { name: "cebula", unit: "pc", per_portion: 0.5, note: "", category: "produce" },
] };

test("ręczne zmiany pozycji z przepisu: nazwa, ilość, usunięcie", () => {
  const { groups, removed } = buildShoppingList([{ recipe: pasta, portions: 4 }], [], {
    "makaron|g": { amount: "1 opakowanie" },
    "cebula|pc": { removed: true },
  });
  assert.equal(groups.length, 1);
  const pastaItem = groups[0].items[0];
  assert.equal(pastaItem.amount, "1 opakowanie");
  assert.equal(pastaItem.edited, true);
  assert.equal(pastaItem.original.amount, "400 g");
  assert.equal(removed.length, 1);
  assert.equal(removed[0].name, "cebula");
});

test("własne pozycje mają ilość i dział sklepu", () => {
  const { groups } = buildShoppingList([], [
    { id: "1", name: "sól", amount: "1 opakowanie", category: "spices_sauces" },
    { id: "2", name: "", amount: "", category: "other" },
    "papier do pieczenia",
  ]);
  assert.deepEqual(groups.map((g) => g.category), ["spices_sauces", "other"]);
  assert.equal(groups[0].items[0].key, "extra|1");
  assert.equal(groups[0].items[0].amount, "1 opakowanie");
  assert.equal(groups[1].items[0].extra, true);
  assert.equal(normalizeExtra({ id: "x", name: " a ", category: "Nie ma takiego" }).category, "other");
  assert.equal(normalizeExtra({ id: "x", name: "a", category: "Przyprawy i sosy" }).category, "spices_sauces");
});

test("dział dla wpisanej pozycji podpowiadany ze składników przepisów (także z tłumaczeń)", () => {
  assert.equal(guessCategory("Cebula", [pasta]), "produce");
  assert.equal(guessCategory("papier", [pasta]), "other");
  assert.equal(guessCategory("김치", [kimchi]), "canned");
});

test("formatuje czas minutnika", () => {
  assert.equal(formatClock(90), "1:30");
  assert.equal(formatClock(3700), "1:01:40");
  assert.equal(formatClock(-5), "0:00");
});
