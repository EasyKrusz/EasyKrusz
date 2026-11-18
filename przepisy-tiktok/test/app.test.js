import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { extractTikTokUrl, fetchTikTok, subtitleCandidates, vttToText } from "../src/tiktok.js";

test("wyciąga link z tekstu udostępnienia", () => {
  assert.equal(
    extractTikTokUrl("Zobacz ten filmik! https://vm.tiktok.com/ZMabc123/ #tiktok"),
    "https://vm.tiktok.com/ZMabc123/"
  );
  assert.equal(extractTikTokUrl("brak linku"), null);
});

test("pobiera opis przez oEmbed, z czyszczeniem parametrów URL", async () => {
  const realFetch = globalThis.fetch;
  const asked = [];
  globalThis.fetch = async (u) => {
    asked.push(String(u));
    if (String(u).includes("oembed")) {
      return new Response(JSON.stringify({ title: "Makaron: 200g spaghetti, 2 ząbki czosnku", author_name: "kucharz" }));
    }
    return new Response("<html>brak danych</html>");
  };
  try {
    const r = await fetchTikTok("https://www.tiktok.com/@kucharz/video/123?is_from_webapp=1&sender_device=pc");
    assert.equal(r.url, "https://www.tiktok.com/@kucharz/video/123");
    assert.match(r.description, /spaghetti/);
    assert.equal(r.author, "kucharz");
    assert.equal(r.transcript, "");
    assert.ok(asked.some((u) => /oembed\?url=https%3A%2F%2Fwww\.tiktok\.com%2F%40kucharz%2Fvideo%2F123$/.test(u)));
  } finally {
    globalThis.fetch = realFetch;
  }
});

const VTT = `WEBVTT

1
00:00:00.000 --> 00:00:02.000
Dziś robimy placki ziemniaczane

2
00:00:02.000 --> 00:00:04.000
Dziś robimy placki ziemniaczane

3
00:00:04.000 --> 00:00:07.000
Trzemy <b>kilogram</b> ziemniaków i jedną cebulę`;

test("zamienia napisy WebVTT na tekst", () => {
  assert.equal(vttToText(VTT), "Dziś robimy placki ziemniaczane Trzemy kilogram ziemniaków i jedną cebulę");
});

test("wybiera najpierw napisy z oryginalnej mowy", () => {
  const item = { video: { subtitleInfos: [
    { Url: "https://x/en-mt.vtt", LanguageCodeName: "eng-US", Source: "MT", Format: "webvtt" },
    { Url: "https://x/pl-asr.vtt", LanguageCodeName: "pol-PL", Source: "ASR", Format: "webvtt" },
  ] } };
  assert.equal(subtitleCandidates(item)[0].url, "https://x/pl-asr.vtt");
});

test("gdy opis jest pusty, bierze transkrypcję z napisów filmiku", async () => {
  const realFetch = globalThis.fetch;
  const data = { __DEFAULT_SCOPE__: { "webapp.video-detail": { itemInfo: { itemStruct: {
    desc: "#foodtok #fyp", author: { uniqueId: "babcia" }, video: { cover: "https://img/cover.jpg",
      subtitleInfos: [{ Url: "https://sub/pl.vtt", LanguageCodeName: "pol-PL", Source: "ASR", Format: "webvtt" }] },
  } } } } };
  globalThis.fetch = async (u) => {
    u = String(u);
    if (u.includes("oembed")) return new Response("nope", { status: 400 });
    if (u.startsWith("https://sub/")) return new Response(VTT);
    return new Response(`<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">${JSON.stringify(data)}</script></html>`);
  };
  try {
    const r = await fetchTikTok("https://www.tiktok.com/@babcia/video/9");
    assert.equal(r.description, "#foodtok #fyp");
    assert.match(r.transcript, /kilogram ziemniaków/);
    assert.equal(r.author, "babcia");
    assert.equal(r.thumbnail, "https://img/cover.jpg");
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("odrzuca filmik bez opisu i bez napisów", async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (u) =>
    String(u).includes("oembed") ? new Response(JSON.stringify({ title: "" })) : new Response("<html></html>");
  try {
    await assert.rejects(fetchTikTok("https://www.tiktok.com/@x/video/1"), /ani napisów/);
  } finally {
    globalThis.fetch = realFetch;
  }
});

// ---- end-to-end: serwer aplikacji + atrapa API Claude ----
let mock, app, base, lastBody;
const fakeRecipe = {
  is_recipe: true, title: "Spaghetti aglio e olio", emoji: "🍝", summary: "Szybki makaron z czosnkiem.",
  servings: "2 porcje", servings_count: 2, prep_time: "15 min", cook_time: "10 min",
  ingredients: [{ group: "", name: "spaghetti", quantity: 200, unit: "g", note: "", category: "Makarony, ryż i kasze" }],
  steps: [{ text: "Ugotuj makaron.", minutes: 9 }, { text: "Podsmaż czosnek na oliwie i wymieszaj.", minutes: 0 }],
  tips: [], tags: ["makaron"],
};

before(async () => {
  mock = http.createServer(async (req, res) => {
    let raw = ""; for await (const c of req) raw += c;
    lastBody = JSON.parse(raw);
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
      id: "msg_1", type: "message", role: "assistant", model: lastBody.model,
      content: [{ type: "text", text: JSON.stringify(fakeRecipe) }],
      stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 },
    }));
  }).listen(0);
  await new Promise((r) => mock.once("listening", r));
  const port = 3900 + Math.floor(Math.random() * 90);
  base = `http://localhost:${port}`;
  app = spawn(process.execPath, ["src/server.js"], {
    env: { ...process.env, PORT: String(port), DATA_DIR: await mkdtemp(path.join(tmpdir(), "przepisy-")),
      ANTHROPIC_API_KEY: "test", ANTHROPIC_BASE_URL: `http://localhost:${mock.address().port}` },
    stdio: ["ignore", "pipe", "inherit"],
  });
  await new Promise((r) => app.stdout.once("data", r));
});
after(() => { app?.kill(); mock?.close(); });

test("zapisuje przepis z samych notatek, potem edycja i usuwanie", async () => {
  const res = await fetch(`${base}/api/recipes`, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ notes: "200g spaghetti, czosnek, oliwa, chili" }) });
  assert.equal(res.status, 201);
  const { recipe } = await res.json();
  assert.equal(recipe.title, "Spaghetti aglio e olio");
  assert.equal(lastBody.model, "claude-opus-5-5");
  assert.equal(lastBody.output_config.format.type, "json_schema");
  assert.equal(lastBody.fallbacks, "default");
  assert.match(lastBody.messages[0].content, /czosnek, oliwa/);

  const list = await (await fetch(`${base}/api/recipes`)).json();
  assert.equal(list.length, 1);

  assert.equal(recipe.emoji, "🍝");
  assert.equal(recipe.ingredients[0].per_portion, 100);
  assert.equal(lastBody.output_config.format.schema.properties.ingredients.items.properties.category.enum.length, 11);
  const patched = await (await fetch(`${base}/api/recipes/${recipe.id}`, { method: "PATCH",
    body: JSON.stringify({ favorite: true, notes: "więcej chili", title: "Makaron z czosnkiem", portions: 3 }) })).json();
  assert.equal(patched.portions, 3);
  assert.equal((await fetch(`${base}/api/recipes/${recipe.id}`, { method: "PATCH", body: JSON.stringify({ portions: 0 }) })).status, 400);

  // lista zakupów
  const shop = await (await fetch(`${base}/api/shopping`, { method: "PUT",
    body: JSON.stringify({
      recipes: { [recipe.id]: 3, zly: -1 }, checked: ["a", "a"],
      extras: [{ id: "s1", name: " sól ", amount: "1 opak.", category: "Przyprawy i sosy" }, { name: "" }, { id: "z", name: "x", category: "Zły dział" }],
      overrides: { "spaghetti|g": { amount: "1 opakowanie" }, "cebula|szt.": { removed: true }, "pusty": {} },
    }) })).json();
  assert.deepEqual(shop, {
    recipes: { [recipe.id]: 3 }, checked: ["a"],
    extras: [{ id: "s1", name: "sól", amount: "1 opak.", category: "Przyprawy i sosy" }, { id: "z", name: "x", amount: "", category: "Inne" }],
    overrides: { "spaghetti|g": { amount: "1 opakowanie" }, "cebula|szt.": { removed: true } },
  });
  assert.deepEqual(await (await fetch(`${base}/api/shopping`)).json(), shop);

  // kopia zapasowa: eksport, a potem import do pustej bazy nic nie dubluje
  const backupRes = await fetch(`${base}/api/backup`);
  assert.match(backupRes.headers.get("content-disposition"), /przepisy-\d{4}-\d{2}-\d{2}\.json/);
  const backup = await backupRes.json();
  assert.equal(backup.format, "przepisy-backup");
  assert.equal(backup.recipes.length, 1);
  const again = await (await fetch(`${base}/api/backup`, { method: "POST", body: JSON.stringify(backup) })).json();
  assert.deepEqual(again, { added: 0, skipped: 1 });
  const imported = await (await fetch(`${base}/api/backup`, { method: "POST", body: JSON.stringify({
    format: "przepisy-backup", version: 1,
    recipes: [{ id: "z-telefonu", title: "Placki", thumbnailFile: "../../recipes.json",
      thumbnail: { type: "image/png", data: Buffer.from("png").toString("base64") } }],
  }) })).json();
  assert.deepEqual(imported, { added: 1, skipped: 0 });
  const placki = await (await fetch(`${base}/api/recipes/z-telefonu`)).json();
  assert.equal(placki.thumbnailFile, "z-telefonu.png");
  assert.equal(await (await fetch(`${base}/thumbs/z-telefonu.png`)).text(), "png");
  assert.equal((await fetch(`${base}/api/backup`, { method: "POST", body: "{}" })).status, 400);
  await fetch(`${base}/api/recipes/z-telefonu`, { method: "DELETE" });
  assert.equal(patched.favorite, true);
  assert.equal(patched.title, "Makaron z czosnkiem");

  assert.equal((await fetch(`${base}/api/recipes/${recipe.id}`, { method: "DELETE" })).status, 200);
  assert.equal((await fetch(`${base}/api/recipes/${recipe.id}`)).status, 404);
});

test("odrzuca puste zapytanie", async () => {
  const res = await fetch(`${base}/api/recipes`, { method: "POST", body: "{}" });
  assert.equal(res.status, 400);
});

test("nie wystawia plików spoza katalogu miniaturek", async () => {
  assert.equal((await fetch(`${base}/thumbs/..%2Frecipes.json`)).status, 404);
});

test("serwuje stronę i manifest z share_target", async () => {
  assert.match(await (await fetch(base)).text(), /Przepisy z TikToka/);
  const m = await (await fetch(`${base}/manifest.webmanifest`)).json();
  assert.equal(m.share_target.action, "/");
});
