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

async function readJson(req) {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 200_000) throw Object.assign(new Error("Za duże zapytanie"), { status: 413 });
  }
  return raw ? JSON.parse(raw) : {};
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
  if (parts[1] !== "recipes") return send(res, 404, { error: "Nie znaleziono" });

  if (!id && req.method === "GET") return send(res, 200, await store.listRecipes());
  if (!id && req.method === "POST") return send(res, 201, await importRecipe(await readJson(req)));

  if (id && req.method === "GET") {
    const r = await store.getRecipe(id);
    return r ? send(res, 200, r) : send(res, 404, { error: "Nie ma takiego przepisu" });
  }
  if (id && req.method === "PATCH") {
    const { title, notes, favorite, tags } = await readJson(req);
    const patch = Object.fromEntries(
      Object.entries({ title, notes, favorite, tags }).filter(([, v]) => v !== undefined)
    );
    const r = await store.updateRecipe(id, patch);
    return r ? send(res, 200, r) : send(res, 404, { error: "Nie ma takiego przepisu" });
  }
  if (id && req.method === "DELETE") {
    const r = await store.getRecipe(id);
    if (r?.thumbnailFile) await unlink(path.join(THUMBS, r.thumbnailFile)).catch(() => {});
    return (await store.deleteRecipe(id))
      ? send(res, 200, { ok: true })
      : send(res, 404, { error: "Nie ma takiego przepisu" });
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
