// Prosty magazyn przepisów w pliku JSON (data/recipes.json).
import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { CATEGORIES } from "../public/kitchen.js";
import path from "node:path";

export const DATA_DIR = process.env.DATA_DIR || path.resolve("data");
const FILE = path.join(DATA_DIR, "recipes.json");

let cache = null;
let writing = Promise.resolve();

async function load() {
  if (cache) return cache;
  try {
    cache = JSON.parse(await readFile(FILE, "utf8"));
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
    cache = [];
  }
  return cache;
}

function persist() {
  // zapisy po kolei + atomowa podmiana pliku
  writing = writing.then(async () => {
    await mkdir(DATA_DIR, { recursive: true });
    const tmp = `${FILE}.tmp`;
    await writeFile(tmp, JSON.stringify(cache, null, 2));
    await rename(tmp, FILE);
  });
  return writing;
}

export async function listRecipes() {
  return [...(await load())].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

export async function getRecipe(id) {
  return (await load()).find((r) => r.id === id) || null;
}

export async function findBySource(url) {
  return (await load()).find((r) => r.source?.url === url) || null;
}

export function newId() {
  return randomUUID();
}

export async function addRecipe(data) {
  const recipes = await load();
  const recipe = { id: data.id || randomUUID(), createdAt: new Date().toISOString(), favorite: false, ...data };
  recipes.push(recipe);
  await persist();
  return recipe;
}

export async function updateRecipe(id, patch) {
  const recipes = await load();
  const r = recipes.find((x) => x.id === id);
  if (!r) return null;
  Object.assign(r, patch, { id: r.id, createdAt: r.createdAt, updatedAt: new Date().toISOString() });
  await persist();
  return r;
}

export async function deleteRecipe(id) {
  const recipes = await load();
  const i = recipes.findIndex((r) => r.id === id);
  if (i === -1) return false;
  recipes.splice(i, 1);
  await persist();
  return true;
}

// ---------- Lista zakupów (data/shopping.json) ----------
const SHOP_FILE = path.join(DATA_DIR, "shopping.json");
const EMPTY_SHOPPING = { recipes: {}, checked: [], extras: [], overrides: {} };
const text = (v, max) => String(v ?? "").trim().slice(0, max);

export async function getShopping() {
  try {
    return { ...EMPTY_SHOPPING, ...JSON.parse(await readFile(SHOP_FILE, "utf8")) };
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
    return { ...EMPTY_SHOPPING };
  }
}

export async function setShopping(state) {
  const clean = {
    recipes: Object.fromEntries(
      Object.entries(state.recipes || {}).filter(([, n]) => Number.isFinite(n) && n > 0).map(([id, n]) => [id, Math.min(n, 99)])
    ),
    checked: [...new Set((state.checked || []).map(String))],
    // Własne pozycje: { id, name, amount, category } (starsze wersje: same napisy)
    extras: (Array.isArray(state.extras) ? state.extras : [])
      .map((e) => (typeof e === "string" ? { name: e } : e || {}))
      .map((e) => ({
        id: text(e.id, 64) || randomUUID(),
        name: text(e.name, 200),
        amount: text(e.amount, 100),
        category: CATEGORIES.includes(e.category) ? e.category : "Inne",
      }))
      .filter((e) => e.name)
      .slice(0, 500),
    // Ręczne zmiany pozycji z przepisów: { [klucz]: { name?, amount?, removed? } }
    overrides: Object.fromEntries(
      Object.entries(state.overrides && typeof state.overrides === "object" ? state.overrides : {})
        .slice(0, 1000)
        .map(([key, o]) => {
          const clean = {};
          if (o?.name != null && text(o.name, 200)) clean.name = text(o.name, 200);
          if (o?.amount != null) clean.amount = text(o.amount, 100);
          if (o?.removed === true) clean.removed = true;
          return [text(key, 300), clean];
        })
        .filter(([key, o]) => key && Object.keys(o).length)
    ),
  };
  await mkdir(DATA_DIR, { recursive: true });
  await writeFile(SHOP_FILE, JSON.stringify(clean, null, 2));
  return clean;
}

// ---------- Import kopii zapasowej ----------
/** Dodaje przepisy, których jeszcze nie ma (po id albo linku do filmiku). Zwraca dodane. */
export async function importRecipes(list) {
  const recipes = await load();
  const ids = new Set(recipes.map((r) => r.id));
  const urls = new Set(recipes.map((r) => r.source?.url).filter(Boolean));
  const added = [];
  for (const r of list) {
    if (!r || typeof r.title !== "string") continue;
    if (ids.has(r.id) || (r.source?.url && urls.has(r.source.url))) continue;
    const { thumbnailFile, ...data } = r; // nazwę pliku miniaturki nadaje serwer, nie importowany plik
    const recipe = { ...data, id: r.id && !ids.has(r.id) ? r.id : randomUUID(), createdAt: r.createdAt || new Date().toISOString() };
    recipes.push(recipe);
    ids.add(recipe.id);
    if (recipe.source?.url) urls.add(recipe.source.url);
    added.push(recipe);
  }
  if (added.length) await persist();
  return added;
}
