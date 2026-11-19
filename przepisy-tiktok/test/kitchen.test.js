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

import { normalizeLangTag, isRTL, truncate, normName, langAttrs } from "../public/kitchen.js";

test("kody języków: pismo chińskie zachowane, regiony pominięte", () => {
  assert.equal(normalizeLangTag("zh-TW"), "zh-Hant");
  assert.equal(normalizeLangTag("zh-Hant-HK"), "zh-Hant");
  assert.equal(normalizeLangTag("zh-CN"), "zh-Hans");
  assert.equal(normalizeLangTag("zh"), "zh-Hans");
  assert.equal(normalizeLangTag("sr-Latn-RS"), "sr-Latn");
  assert.equal(normalizeLangTag("pt_BR"), "pt");
  assert.equal(normalizeLangTag("ja-JP"), "ja");
});

test("kierunek pisma", () => {
  for (const l of ["ar", "he", "fa", "ur", "ar-EG"]) assert.equal(isRTL(l), true, l);
  for (const l of ["ja", "zh-Hant", "ko", "en", "th", "hi"]) assert.equal(isRTL(l), false, l);
  assert.equal(langAttrs("ar"), 'lang="ar" dir="rtl"');
  assert.equal(langAttrs(""), 'dir="auto"');
});

test("liczby i jednostki w innych językach nie psują się", () => {
  assert.equal(formatAmount(2.5, "g", "fr"), "2,5 g");
  assert.equal(formatAmount(2, "cup", "ja"), "2 cups"); // język bez tabeli jednostek → angielskie skróty
  assert.match(formatAmount(1250, "g", "ar"), /kg$/);
});

test("skracanie nie przecina znaków złożonych, porównania ujednolicają Unicode", () => {
  assert.equal(truncate("👨‍👩‍👧 김치볶음밥", 4), "👨‍👩‍👧 김치…");
  assert.equal(truncate("krótki", 40), "krótki");
  assert.equal(normName("ＫＩＭＣＨＩ"), "kimchi");
  assert.equal(normName("ﾗｰﾒﾝ"), "ラーメン");
});

import { canonicalUnit, resolveUnitSystem, convertTemperatures } from "../public/kitchen.js";

test("jednostki z filmiku zapisujemy w g / ml", () => {
  assert.deepEqual(canonicalUnit(1, "lb"), { quantity: 453.592, unit: "g" });
  assert.deepEqual(canonicalUnit(2, "kg"), { quantity: 2000, unit: "g" });
  assert.equal(Math.round(canonicalUnit(8, "oz").quantity), 227);
  assert.equal(Math.round(canonicalUnit(2, "fl oz").quantity), 59);
  assert.deepEqual(canonicalUnit(2, "cup"), { quantity: 2, unit: "cup" });
  assert.deepEqual(canonicalUnit(1, "łyżka"), { quantity: 1, unit: "tbsp" });
  const r = toPerPortion({ servings_count: 2, ingredients: [{ name: "ser", quantity: 8, unit: "oz", note: "", category: "dairy_eggs", group: "" }] });
  assert.equal(r.ingredients[0].unit, "g");
  assert.equal(Math.round(r.ingredients[0].per_portion), 113);
});

test("system amerykański: oz, lb, cups, łyżki", () => {
  const us = (v, u) => formatAmount(v, u, "en", "us");
  assert.equal(us(227, "g"), "8 oz");
  assert.equal(us(30, "g"), "1 oz");
  assert.equal(us(1000, "g"), "2¼ lb");
  assert.equal(us(5, "g"), "5 g"); // drobne ilości zostają w gramach
  assert.equal(us(240, "ml"), "1 cup");
  assert.equal(us(80, "ml"), "⅓ cup");
  assert.equal(us(30, "ml"), "2 tbsp");
  assert.equal(us(5, "ml"), "1 tsp");
  assert.equal(us(2, "tbsp"), "2 tbsp");
  assert.equal(us(0.66, "cup"), "⅔ cup");
});

test("system metryczny: szklanki → ml, łyżki zostają; „bez przeliczania” nic nie zmienia", () => {
  assert.equal(formatAmount(1, "cup", "pl", "metric"), "240 ml");
  assert.equal(formatAmount(5, "cup", "de", "metric"), "1,2 l");
  assert.equal(formatAmount(2, "tbsp", "pl", "metric"), "2 łyżki");
  assert.equal(formatAmount(1, "cup", "pl", "original"), "1 szklanka");
  assert.equal(formatAmount(1, "cup", "pl"), "1 szklanka");
});

test("„automatycznie”: USA → amerykański, reszta → metryczny", () => {
  assert.equal(resolveUnitSystem("auto", "en-US"), "us");
  assert.equal(resolveUnitSystem("auto", "es-US"), "us");
  assert.equal(resolveUnitSystem("auto", "en-GB"), "metric");
  assert.equal(resolveUnitSystem("auto", "de-DE"), "metric");
  assert.equal(resolveUnitSystem("metric", "en-US"), "metric");
  assert.equal(resolveUnitSystem("us", "pl-PL"), "us");
});

test("temperatury w krokach jak w tabelach piekarnikowych", () => {
  assert.equal(convertTemperatures("Piecz w 180°C przez 25 min.", "us"), "Piecz w 350°F przez 25 min.");
  assert.equal(convertTemperatures("Bake at 375 °F", "metric"), "Bake at 190°C");
  assert.equal(convertTemperatures("200℃で焼く", "us"), "400°Fで焼く");
  assert.equal(convertTemperatures("180°C", "original"), "180°C");
  assert.equal(convertTemperatures("Dodaj 200 g mąki i 2 jajka.", "us"), "Dodaj 200 g mąki i 2 jajka.");
});

test("lista zakupów sumuje szklanki z mililitrami", () => {
  const a = { id: "a", title: "A", servings_count: 1, ingredients: [{ name: "mleko", unit: "cup", per_portion: 1, note: "", category: "dairy_eggs" }] };
  const b = { id: "b", title: "B", servings_count: 1, ingredients: [{ name: "mleko", unit: "ml", per_portion: 260, note: "", category: "dairy_eggs" }] };
  const metric = buildShoppingList([{ recipe: a, portions: 1 }, { recipe: b, portions: 1 }], [], {}, "pl", "metric").groups;
  assert.equal(metric[0].items.length, 1);
  assert.equal(metric[0].items[0].amount, "500 ml");
  const us = buildShoppingList([{ recipe: a, portions: 1 }, { recipe: b, portions: 1 }], [], {}, "en", "us").groups;
  assert.equal(us[0].items[0].amount, "2 cups");
});
