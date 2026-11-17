import { test } from "node:test";
import assert from "node:assert/strict";
import {
  formatAmount, ingredientAmount, normalizeRecipe, portionsOf, buildShoppingList, shoppingListText, formatClock,
} from "../public/kitchen.js";
import { toPerPortion } from "../src/recipe.js";

test("formatuje ilości z odmianą jednostek", () => {
  assert.equal(formatAmount(150, "g"), "150 g");
  assert.equal(formatAmount(152, "g"), "150 g");
  assert.equal(formatAmount(1250, "g"), "1,25 kg");
  assert.equal(formatAmount(1500, "ml"), "1,5 l");
  assert.equal(formatAmount(12.4, "g"), "12 g");
  assert.equal(formatAmount(2.5, "g"), "2,5 g");
  assert.equal(formatAmount(1, "łyżka"), "1 łyżka");
  assert.equal(formatAmount(3, "łyżka"), "3 łyżki");
  assert.equal(formatAmount(5, "łyżka"), "5 łyżek");
  assert.equal(formatAmount(1.5, "łyżka"), "1½ łyżki");
  assert.equal(formatAmount(0.5, "szklanka"), "½ szklanki");
  assert.equal(formatAmount(0.25, "szt."), "¼ szt.");
  assert.equal(formatAmount(2, "ząbek"), "2 ząbki");
  assert.equal(formatAmount(12, "ząbek"), "12 ząbków");
  assert.equal(formatAmount(22, "ząbek"), "22 ząbki");
  assert.equal(formatAmount(0, "g"), "");
});

test("ilości są zapisywane na 1 porcję i mnożone przez liczbę porcji", () => {
  const r = toPerPortion({
    servings_count: 4,
    ingredients: [
      { group: "", name: "makaron", quantity: 400, unit: "g", note: "", category: "Makarony, ryż i kasze" },
      { group: "", name: "jajko", quantity: 2, unit: "szt.", note: "", category: "Nabiał i jajka" },
      { group: "", name: "sól", quantity: 0, unit: "szczypta", note: "do smaku", category: "Przyprawy i sosy" },
    ],
  });
  assert.equal(r.ingredients[0].per_portion, 100);
  assert.equal(ingredientAmount(r.ingredients[0], 1), "100 g");
  assert.equal(ingredientAmount(r.ingredients[0], 3), "300 g");
  assert.equal(ingredientAmount(r.ingredients[1], 1), "½ szt.");
  assert.equal(ingredientAmount(r.ingredients[1], 6), "3 szt.");
  assert.equal(ingredientAmount(r.ingredients[2], 6), "do smaku");
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

test("lista zakupów sumuje te same składniki i grupuje według działów", () => {
  const a = { id: "a", title: "Spaghetti", servings_count: 1, ingredients: [
    { name: "Makaron", unit: "g", per_portion: 100, note: "", category: "Makarony, ryż i kasze" },
    { name: "czosnek", unit: "ząbek", per_portion: 1, note: "", category: "Warzywa i owoce" },
    { name: "sól", unit: "", per_portion: 0, note: "do smaku", category: "Przyprawy i sosy" },
  ] };
  const b = { id: "b", title: "Zupa", servings_count: 1, ingredients: [
    { name: "czosnek", unit: "ząbek", per_portion: 0.5, note: "", category: "Warzywa i owoce" },
    { name: "makaron", unit: "g", per_portion: 50, note: "", category: "Makarony, ryż i kasze" },
  ] };
  const groups = buildShoppingList([{ recipe: a, portions: 2 }, { recipe: b, portions: 4 }], ["papier do pieczenia"]);
  assert.deepEqual(groups.map((g) => g.category), ["Warzywa i owoce", "Makarony, ryż i kasze", "Przyprawy i sosy", "Inne"]);
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

test("formatuje czas minutnika", () => {
  assert.equal(formatClock(90), "1:30");
  assert.equal(formatClock(3700), "1:01:40");
  assert.equal(formatClock(-5), "0:00");
});
