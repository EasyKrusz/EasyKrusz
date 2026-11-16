import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { extractTikTokUrl, fetchTikTok } from "../src/tiktok.js";

test("wyciąga link z tekstu udostępnienia", () => {
  assert.equal(
    extractTikTokUrl("Zobacz ten filmik! https://vm.tiktok.com/ZMabc123/ #tiktok"),
    "https://vm.tiktok.com/ZMabc123/"
  );
  assert.equal(extractTikTokUrl("brak linku"), null);
});

test("pobiera opis przez oEmbed, z czyszczeniem parametrów URL", async () => {
  const realFetch = globalThis.fetch;
  let asked;
  globalThis.fetch = async (u) => {
    asked = String(u);
    return new Response(JSON.stringify({ title: "Makaron: 200g spaghetti, 2 ząbki czosnku", author_name: "kucharz" }));
  };
  try {
    const r = await fetchTikTok("https://www.tiktok.com/@kucharz/video/123?is_from_webapp=1&sender_device=pc");
    assert.equal(r.url, "https://www.tiktok.com/@kucharz/video/123");
    assert.match(r.description, /spaghetti/);
    assert.equal(r.author, "kucharz");
    assert.match(asked, /oembed\?url=https%3A%2F%2Fwww\.tiktok\.com%2F%40kucharz%2Fvideo%2F123$/);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("gdy oEmbed nie działa, czyta opis ze strony", async () => {
  const realFetch = globalThis.fetch;
  const data = { __DEFAULT_SCOPE__: { "webapp.video-detail": { itemInfo: { itemStruct: { desc: "Placki: mąka, mleko", author: { uniqueId: "babcia" } } } } } };
  globalThis.fetch = async (u) =>
    String(u).includes("oembed")
      ? new Response("nope", { status: 400 })
      : new Response(`<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">${JSON.stringify(data)}</script></html>`);
  try {
    const r = await fetchTikTok("https://www.tiktok.com/@babcia/video/9");
    assert.equal(r.description, "Placki: mąka, mleko");
    assert.equal(r.author, "babcia");
  } finally {
    globalThis.fetch = realFetch;
  }
});

// ---- end-to-end: serwer aplikacji + atrapa API Claude ----
let mock, app, base, lastBody;
const fakeRecipe = {
  is_recipe: true, title: "Spaghetti aglio e olio", summary: "Szybki makaron z czosnkiem.",
  servings: "2 porcje", prep_time: "15 min", cook_time: "10 min",
  ingredients: [{ group: "", name: "spaghetti", amount: "200 g" }],
  steps: ["Ugotuj makaron.", "Podsmaż czosnek na oliwie i wymieszaj."], tips: [], tags: ["makaron"],
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

  const patched = await (await fetch(`${base}/api/recipes/${recipe.id}`, { method: "PATCH",
    body: JSON.stringify({ favorite: true, notes: "więcej chili" }) })).json();
  assert.equal(patched.favorite, true);

  assert.equal((await fetch(`${base}/api/recipes/${recipe.id}`, { method: "DELETE" })).status, 200);
  assert.equal((await fetch(`${base}/api/recipes/${recipe.id}`)).status, 404);
});

test("odrzuca puste zapytanie", async () => {
  const res = await fetch(`${base}/api/recipes`, { method: "POST", body: "{}" });
  assert.equal(res.status, 400);
});

test("serwuje stronę i manifest z share_target", async () => {
  assert.match(await (await fetch(base)).text(), /Przepisy z TikToka/);
  const m = await (await fetch(`${base}/manifest.webmanifest`)).json();
  assert.equal(m.share_target.action, "/");
});
