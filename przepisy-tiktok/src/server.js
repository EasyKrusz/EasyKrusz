import http from "node:http";
import { readFile, writeFile, mkdir, unlink } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { extractTikTokUrl, fetchTikTok, downloadImage } from "./tiktok.js";
import { buildRecipe } from "./recipe.js";
import * as store from "./store.js";

const PORT = Number(process.env.PORT) || 3000;
const PUBLIC = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "public");
const THUMBS = path.join(store.DATA_DIR, "thumbs");
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
};

function send(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
}

async function readJson(req, limit = 200_000) {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > limit) throw Object.assign(new Error("Za duże zapytanie"), { status: 413 });
  }
  try {
    return raw ? JSON.parse(raw) : {};
  } catch {
    throw Object.assign(new Error("Nieprawidłowy JSON"), { status: 400 });
  }
}

// POST /api/recipes  { url?, text?, notes?, force? }
async function importRecipe(body) {
  const url = extractTikTokUrl(body.url) || extractTikTokUrl(body.text);
  const notes = (body.notes || "").trim();
  if (!url && !notes) {
    throw Object.assign(new Error("Podaj link do TikToka albo wklej opis przepisu."), { status: 400 });
  }

  let source = { url: url || "", author: "", thumbnail: "", description: "", transcript: "" };
  if (url) {
    try {
      source = await fetchTikTok(url);
    } catch (e) {
      if (!notes) throw Object.assign(e, { status: 502 });
      source.url = url; // mamy notatki - przetwarzamy mimo braku opisu
    }
    if (!body.force) {
      const existing = await store.findBySource(source.url);
      if (existing) return { recipe: existing, duplicate: true };
    }
  }

  const recipe = await buildRecipe({
    description: source.description,
    transcript: source.transcript,
    notes,
    author: source.author,
  });
  if (!recipe.is_recipe) {
    throw Object.assign(
      new Error(
        `W opisie${source.transcript ? " ani w napisach" : ""} filmiku nie ma przepisu. ${recipe.summary || ""} ` +
          (source.transcript
            ? "Wpisz brakujące informacje w pole „Notatki”."
            : "Filmik nie ma automatycznych napisów, więc nie da się odczytać, co mówi autor – wpisz przepis w pole „Notatki”.")
      ),
      { status: 422, description: source.description }
    );
  }
  const { is_recipe, ...fields } = recipe;
  const id = store.newId();
  const thumbnailFile = await saveThumbnail(id, source.thumbnail);
  return { recipe: await store.addRecipe({ ...fields, id, notes, source, thumbnailFile }) };
}

async function saveThumbnail(id, url) {
  const img = await downloadImage(url);
  if (!img) return "";
  await mkdir(THUMBS, { recursive: true });
  const name = `${id}.${img.ext}`;
  await writeFile(path.join(THUMBS, name), img.buf);
  return name;
}

async function handleApi(req, res, url) {
  const parts = url.pathname.split("/").filter(Boolean); // ["api","recipes",id?]
  const id = parts[2];
  if (parts[1] === "shopping") return handleShopping(req, res);
  if (parts[1] === "backup") return handleBackup(req, res);
  if (parts[1] !== "recipes") return send(res, 404, { error: "Nie znaleziono" });

  if (!id && req.method === "GET") return send(res, 200, await store.listRecipes());
  if (!id && req.method === "POST") return send(res, 201, await importRecipe(await readJson(req)));

  if (id && req.method === "GET") {
    const r = await store.getRecipe(id);
    return r ? send(res, 200, r) : send(res, 404, { error: "Nie ma takiego przepisu" });
  }
  if (id && req.method === "PATCH") {
    const { title, notes, favorite, tags, portions } = await readJson(req);
    if (portions !== undefined && !(Number.isInteger(portions) && portions >= 1 && portions <= 99)) {
      return send(res, 400, { error: "Liczba porcji musi być od 1 do 99" });
    }
    const patch = Object.fromEntries(
      Object.entries({ title, notes, favorite, tags, portions }).filter(([, v]) => v !== undefined)
    );
    const r = await store.updateRecipe(id, patch);
    return r ? send(res, 200, r) : send(res, 404, { error: "Nie ma takiego przepisu" });
  }
  if (id && req.method === "DELETE") {
    const r = await store.getRecipe(id);
    if (r?.thumbnailFile) await unlink(path.join(THUMBS, path.basename(r.thumbnailFile))).catch(() => {});
    return (await store.deleteRecipe(id))
      ? send(res, 200, { ok: true })
      : send(res, 404, { error: "Nie ma takiego przepisu" });
  }
  send(res, 405, { error: "Niedozwolona metoda" });
}

// GET/PUT /api/shopping – stan listy zakupów: { recipes: {id: porcje}, checked: [klucze], extras: [teksty] }
async function handleShopping(req, res) {
  if (req.method === "GET") return send(res, 200, await store.getShopping());
  if (req.method === "PUT") return send(res, 200, await store.setShopping(await readJson(req)));
  send(res, 405, { error: "Niedozwolona metoda" });
}

// GET /api/backup – plik z kopią wszystkich przepisów (z miniaturkami), POST – import takiego pliku.
// Ten sam format czyta i zapisuje aplikacja na iPhone'a.
async function handleBackup(req, res) {
  if (req.method === "GET") {
    const recipes = [];
    for (const r of await store.listRecipes()) {
      const { thumbnailFile, ...rest } = r;
      let thumbnail = null;
      if (thumbnailFile) {
        const buf = await readFile(path.join(THUMBS, thumbnailFile)).catch(() => null);
        if (buf) thumbnail = { type: TYPES[path.extname(thumbnailFile)] || "image/jpeg", data: buf.toString("base64") };
      }
      recipes.push({ ...rest, thumbnail });
    }
    const day = new Date().toISOString().slice(0, 10);
    res.writeHead(200, {
      "Content-Type": "application/json; charset=utf-8",
      "Content-Disposition": `attachment; filename="przepisy-${day}.json"`,
    });
    return res.end(JSON.stringify({ format: "przepisy-backup", version: 1, exportedAt: new Date().toISOString(), recipes }));
  }
  if (req.method === "POST") {
    const body = await readJson(req, 100_000_000);
    if (body.format !== "przepisy-backup" || !Array.isArray(body.recipes)) {
      return send(res, 400, { error: "To nie jest plik kopii zapasowej przepisów" });
    }
    const incoming = body.recipes.map(({ thumbnail, ...r }) => ({ ...r, _thumb: thumbnail }));
    const added = await store.importRecipes(incoming.map(({ _thumb, ...r }) => r));
    // Miniaturki dodanych przepisów
    for (const r of added) {
      const thumb = incoming.find((x) => x.id === r.id || (x.source?.url && x.source.url === r.source?.url))?._thumb;
      if (!thumb?.data) continue;
      const ext = /png/.test(thumb.type) ? "png" : /webp/.test(thumb.type) ? "webp" : "jpg";
      await mkdir(THUMBS, { recursive: true });
      await writeFile(path.join(THUMBS, `${r.id}.${ext}`), Buffer.from(thumb.data, "base64"));
      await store.updateRecipe(r.id, { thumbnailFile: `${r.id}.${ext}` });
    }
    return send(res, 200, { added: added.length, skipped: body.recipes.length - added.length });
  }
  send(res, 405, { error: "Niedozwolona metoda" });
}

async function serveThumb(res, pathname) {
  const name = path.basename(pathname);
  try {
    const data = await readFile(path.join(THUMBS, name));
    res.writeHead(200, {
      "Content-Type": TYPES[path.extname(name)] || "application/octet-stream",
      "Cache-Control": "public, max-age=31536000, immutable",
    });
    res.end(data);
  } catch {
    send(res, 404, { error: "Brak miniaturki" });
  }
}

async function serveStatic(res, pathname) {
  const rel = pathname === "/" ? "index.html" : pathname.slice(1);
  const file = path.normalize(path.join(PUBLIC, rel));
  if (!file.startsWith(PUBLIC)) return send(res, 403, { error: "Zabronione" });
  try {
    const data = await readFile(file);
    res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] || "application/octet-stream" });
    res.end(data);
  } catch {
    // SPA: każda nieznana ścieżka -> index.html
    const data = await readFile(path.join(PUBLIC, "index.html"));
    res.writeHead(200, { "Content-Type": TYPES[".html"] });
    res.end(data);
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  try {
    if (url.pathname.startsWith("/api/")) return await handleApi(req, res, url);
    if (url.pathname.startsWith("/thumbs/")) return await serveThumb(res, url.pathname);
    return await serveStatic(res, url.pathname);
  } catch (e) {
    console.error(e);
    send(res, e.status || 500, { error: e.message || "Błąd serwera", description: e.description });
  }
});

server.listen(PORT, () => console.log(`Przepisy z TikToka: http://localhost:${PORT}`));
