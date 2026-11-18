import http from "node:http";
import { readFile, writeFile, mkdir, unlink } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { extractTikTokUrl, fetchTikTok, downloadImage } from "./tiktok.js";
import { buildRecipe, translateRecipe } from "./recipe.js";
// Kod języka BCP 47, np. "ko", "zh-Hant", "sr-Latn"
const langOf = (l) => (typeof l === "string" && l.length <= 20 && /^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$/.test(l) ? l : "en");
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

/** Błąd z kodem – interfejs pokazuje komunikat w języku użytkownika na podstawie `code`. */
const fail = (status, code, message, extra = {}) => Object.assign(new Error(message), { status, code, ...extra });

function send(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
}

async function readJson(req, limit = 200_000) {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > limit) throw fail(413, "too_large", "Request too large");
  }
  try {
    return raw ? JSON.parse(raw) : {};
  } catch {
    throw fail(400, "invalid_json", "Invalid JSON");
  }
}

// POST /api/recipes  { url?, text?, notes?, force?, language? }
async function importRecipe(body) {
  const url = extractTikTokUrl(body.url) || extractTikTokUrl(body.text);
  const notes = (body.notes || "").trim();
  if (!url && !notes) {
    throw fail(400, "no_input", "Provide a TikTok link or recipe notes");
  }

  let source = { url: url || "", author: "", thumbnail: "", description: "", transcript: "" };
  if (url) {
    try {
      source = await fetchTikTok(url);
    } catch (e) {
      if (!notes) throw Object.assign(e, { status: 502, code: e.code || "tiktok_failed" });
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
    language: langOf(body.language),
  });
  if (!recipe.is_recipe) {
    throw fail(422, "no_recipe", "No recipe found", {
      summary: recipe.summary || "", hasTranscript: !!source.transcript, description: source.description,
    });
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
  if (parts[1] !== "recipes") return send(res, 404, { error: "Not found", code: "not_found" });
  if (id && parts[3] === "translate" && req.method === "POST") return handleTranslate(req, res, id);

  if (!id && req.method === "GET") return send(res, 200, await store.listRecipes());
  if (!id && req.method === "POST") return send(res, 201, await importRecipe(await readJson(req)));

  if (id && req.method === "GET") {
    const r = await store.getRecipe(id);
    return r ? send(res, 200, r) : send(res, 404, { error: "No such recipe", code: "not_found" });
  }
  if (id && req.method === "PATCH") {
    const { title, notes, favorite, tags, portions, language } = await readJson(req);
    if (portions !== undefined && !(Number.isInteger(portions) && portions >= 1 && portions <= 99)) {
      return send(res, 400, { error: "Portions must be 1-99", code: "bad_portions" });
    }
    const current = await store.getRecipe(id);
    if (!current) return send(res, 404, { error: "No such recipe", code: "not_found" });
    const patch = Object.fromEntries(
      Object.entries({ notes, favorite, tags, portions }).filter(([, v]) => v !== undefined)
    );
    // Zmiana nazwy dotyczy języka, w którym przepis jest właśnie wyświetlany
    if (typeof title === "string" && title.trim()) {
      const lang = language && language !== (current.language || "pl") ? langOf(language) : null;
      if (lang && current.translations?.[lang]) {
        patch.translations = { ...current.translations, [lang]: { ...current.translations[lang], title: title.trim() } };
      } else {
        patch.title = title.trim();
      }
    }
    return send(res, 200, await store.updateRecipe(id, patch));
  }
  if (id && req.method === "DELETE") {
    const r = await store.getRecipe(id);
    if (r?.thumbnailFile) await unlink(path.join(THUMBS, path.basename(r.thumbnailFile))).catch(() => {});
    return (await store.deleteRecipe(id))
      ? send(res, 200, { ok: true })
      : send(res, 404, { error: "No such recipe", code: "not_found" });
  }
  send(res, 405, { error: "Method not allowed" });
}

// POST /api/recipes/:id/translate { language } – tłumaczenie tekstu przepisu, zapamiętywane w recipe.translations
async function handleTranslate(req, res, id) {
  const { language } = await readJson(req);
  const lang = langOf(language);
  const r = await store.getRecipe(id);
  if (!r) return send(res, 404, { error: "No such recipe", code: "not_found" });
  if (lang === (r.language || "pl") || r.translations?.[lang]) return send(res, 200, r);
  const translation = await translateRecipe(r, lang);
  return send(res, 200, await store.updateRecipe(id, { translations: { ...(r.translations || {}), [lang]: translation } }));
}

// GET/PUT /api/shopping – stan listy zakupów: { recipes: {id: porcje}, checked: [klucze], extras: [teksty] }
async function handleShopping(req, res) {
  if (req.method === "GET") return send(res, 200, await store.getShopping());
  if (req.method === "PUT") return send(res, 200, await store.setShopping(await readJson(req)));
  send(res, 405, { error: "Method not allowed" });
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
    return res.end(JSON.stringify({ format: "przepisy-backup", version: 2, exportedAt: new Date().toISOString(), recipes }));
  }
  if (req.method === "POST") {
    const body = await readJson(req, 100_000_000);
    if (body.format !== "przepisy-backup" || !Array.isArray(body.recipes)) {
      return send(res, 400, { error: "Not a recipe backup file", code: "bad_backup" });
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
  send(res, 405, { error: "Method not allowed" });
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
    send(res, 404, { error: "No thumbnail", code: "not_found" });
  }
}

async function serveStatic(res, pathname) {
  const rel = pathname === "/" ? "index.html" : pathname.slice(1);
  const file = path.normalize(path.join(PUBLIC, rel));
  if (!file.startsWith(PUBLIC)) return send(res, 403, { error: "Forbidden" });
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
    const { status = 500, code = "server_error", summary, hasTranscript, description } = e;
    send(res, status, { error: e.message || "Server error", code, summary, hasTranscript, description });
  }
});

server.listen(PORT, () => console.log(`Przepisy z TikToka: http://localhost:${PORT}`));
