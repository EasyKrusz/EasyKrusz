// Prosty magazyn przepisów w pliku JSON (data/recipes.json).
import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { randomUUID } from "node:crypto";
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
