import {
  CATEGORIES, categoryLabel, normalizeRecipe, normalizeExtra, guessCategory, portionsOf, ingredientAmount,
  buildShoppingList, shoppingListText, formatClock, textIn, normName, langAttrs, truncate,
} from "./kitchen.js";
import { t, getLang, getRecipeLang, getLangSetting, setLangSetting, langName, uiDir, LANG_OPTIONS } from "./i18n.js";

// Pisanie przez IME (japoński, chiński, koreański): Enter zatwierdzający słowo nie może wysłać formularza
let composing = false;
document.addEventListener("compositionstart", () => { composing = true; }, true);
document.addEventListener("compositionend", () => { setTimeout(() => { composing = false; }, 80); }, true);

const app = document.getElementById("app");
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const $ = (sel, root = document) => root.querySelector(sel);

let recipes = [];
let shopping = { recipes: {}, checked: [], extras: [], overrides: {} };
let query = "";

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.error || `HTTP ${res.status}`), data, { status: res.status });
  return data;
}

/** Komunikat błędu w języku użytkownika (serwer przysyła kod błędu). */
function errorText(e) {
  if (e.code === "no_recipe") {
    return t(e.hasTranscript ? "err.no_recipe" : "err.no_recipe_no_subs", { summary: e.summary || "" }).replace(/\s+/g, " ").trim();
  }
  const key = `err.${e.code}`;
  const msg = t(key);
  return msg !== key ? msg : t("err.server_error");
}

const portionsLabel = (n) => t("portions", { n });

/** Tłumaczenie z wstawionymi fragmentami HTML (np. tekst w innym języku w <bdi>) – w dowolnym miejscu zdania. */
function tHtml(key, htmlVars) {
  const marks = Object.fromEntries(Object.keys(htmlVars).map((k, i) => [k, `\u0000${i}\u0000`]));
  let out = esc(t(key, marks));
  Object.entries(htmlVars).forEach(([, html], i) => { out = out.replace(`\u0000${i}\u0000`, html); });
  return out;
}
/** Język treści przepisów (nowe przepisy, tłumaczenia, lista zakupów). */
const contentLang = () => getRecipeLang();
/** Przepis z tekstem w języku użytkownika – albo w zapisanym języku, jeśli tłumaczenia jeszcze nie ma. */
const localized = (r) => textIn(r, contentLang()) || textIn(r);

// Miniaturka zapisana na serwerze, a gdy jej nie ma – kafelek z emoji dobranym do dania
function thumb(r, cls = "") {
  const tile = `<div class="ph ${cls}" style="background:${tileColor(r.title)}">${esc(r.emoji || "🍳")}</div>`;
  if (!r.thumbnailFile) return tile;
  return `<img class="${cls}" src="/thumbs/${encodeURIComponent(r.thumbnailFile)}" alt="" loading="lazy" onerror="this.outerHTML=${esc(JSON.stringify(tile))}">`;
}
function tileColor(text = "") {
  let h = 0;
  for (const c of text) h = (h * 31 + c.codePointAt(0)) % 360;
  return `hsl(${h} 70% 88%)`;
}

function updateNav() {
  const n = Object.keys(shopping.recipes).filter((id) => recipes.some((r) => r.id === id)).length + shopping.extras.length;
  $("#nav-shop").textContent = n ? t("nav.shoppingCount", { n }) : t("nav.shopping");
}

async function saveShopping() {
  shopping = await api("/api/shopping", { method: "PUT", body: JSON.stringify(shopping) });
  updateNav();
}

// ================= Lista + dodawanie =================
function renderHome(prefill = {}) {
  app.innerHTML = `
    <form class="card" id="add">
      <div class="row">
        <input class="grow" id="url" dir="auto" placeholder="${esc(t("add.placeholder"))}" inputmode="url" autocomplete="off" value="${esc(prefill.url)}">
        <button class="primary" id="go">${esc(t("add.save"))}</button>
      </div>
      <details ${prefill.notes ? "open" : ""}>
        <summary>${esc(t("add.notesSummary"))}</summary>
        <textarea id="notes" dir="auto" placeholder="${esc(t("add.notesPlaceholder"))}">${esc(prefill.notes)}</textarea>
      </details>
      <div class="msg" id="msg"></div>
    </form>
    <input class="search" id="q" type="search" dir="auto" placeholder="${esc(t("search.placeholder"))}" value="${esc(query)}">
    <div class="list" id="list"></div>
    <footer class="backup">
      <span>${esc(t("backup.label"))}</span>
      <a href="/api/backup" download><button type="button">${esc(t("backup.download"))}</button></a>
      <button type="button" id="import">${esc(t("backup.upload"))}</button>
      <input type="file" id="import-file" accept="application/json,.json" hidden>
      <div class="msg" id="backup-msg"></div>
      <label class="lang-select">${esc(t("settings.language"))}
        <select id="lang">${Object.entries(LANG_OPTIONS).map(([code, name]) =>
          `<option value="${code}" ${getLangSetting() === code ? "selected" : ""}>${esc(name || t("lang.auto"))}</option>`).join("")}
        </select>
      </label>
    </footer>`;
  $("#lang").onchange = (e) => { setLangSetting(e.target.value); applyStaticTexts(); updateNav(); renderHome(); };
  $("#add").onsubmit = (e) => { e.preventDefault(); if (!composing) submit(); };
  $("#q").oninput = (e) => { query = e.target.value; renderList(); };
  $("#import").onclick = () => $("#import-file").click();
  $("#import-file").onchange = (e) => importBackup(e.target.files[0]);
  renderList();
}

function matches(r, q) {
  if (!q) return true;
  const n = normalizeRecipe(r);
  const texts = [n, ...Object.values(n.translations)];
  const hay = texts.flatMap((x) => [x.title, x.summary, ...(x.tags || []), ...(x.ingredients || []).map((i) => i.name)])
    .concat(n.source?.author || "")
    .join(" ").toLowerCase();
  return q.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
}

function renderList() {
  const el = $("#list");
  if (!el) return;
  const shown = recipes.filter((r) => matches(r, query))
    .sort((a, b) => (b.favorite - a.favorite) || b.createdAt.localeCompare(a.createdAt));
  if (!recipes.length) { el.innerHTML = `<div class="empty">${t("list.empty")}</div>`; return; }
  if (!shown.length) { el.innerHTML = `<div class="empty">${esc(t("list.noMatch", { q: query }))}</div>`; return; }
  el.innerHTML = shown.map(localized).map((r) => `
    <a class="card item" href="#/r/${r.id}">
      ${thumb(r)}
      <div class="grow">
        <h3 ${langAttrs(r.shownLanguage)}>${r.favorite ? "★ " : ""}${esc(r.title)}</h3>
        <div class="meta">${[r.prep_time && "⏱ " + r.prep_time, r.servings, r.source?.author && "@" + r.source.author, shopping.recipes[r.id] && "🛒"].filter(Boolean).map((x) => `<bdi dir="auto">${esc(x)}</bdi>`).join(" · ")}</div>
        <div class="chips" ${langAttrs(r.shownLanguage)}>${(r.tags || []).slice(0, 4).map((x) => `<span class="chip">${esc(x)}</span>`).join("")}</div>
      </div>
    </a>`).join("");
}

async function submit(force = false) {
  const url = $("#url").value.trim();
  const notes = $("#notes").value.trim();
  const btn = $("#go");
  const msg = $("#msg");
  if (!url && !notes) { msg.className = "msg err"; msg.textContent = t("add.needInput"); return; }
  btn.disabled = true; msg.className = "msg";
  msg.innerHTML = `<span class="spinner"></span> ${esc(t("add.working"))}`;
  try {
    const { recipe, duplicate } = await api("/api/recipes", {
      method: "POST", body: JSON.stringify({ url, notes, force, language: contentLang() }),
    });
    if (duplicate) {
      const link = `<a href="#/r/${recipe.id}">${esc(localized(recipe).title)}</a>`;
      msg.innerHTML = `${t("add.duplicate", { link })} <button type="button" id="again">${esc(t("add.again"))}</button>`;
      $("#again").onclick = () => submit(true);
      return;
    }
    recipes.unshift(recipe);
    location.hash = `#/r/${recipe.id}`;
  } catch (e) {
    msg.className = "msg err";
    msg.innerHTML = esc(errorText(e)) + (e.description ? `<details><summary>${esc(t("add.fetchedDescription"))}</summary><div class="raw">${esc(e.description)}</div></details>` : "");
    if (["no_recipe", "tiktok_empty", "tiktok_failed"].includes(e.code)) $("#add details").open = true;
  } finally {
    btn.disabled = false;
  }
}

async function importBackup(file) {
  const msg = $("#backup-msg");
  if (!file) return;
  msg.className = "msg";
  msg.innerHTML = `<span class="spinner"></span> ${esc(t("backup.loading"))}`;
  try {
    const res = await api("/api/backup", { method: "POST", body: await file.text() });
    recipes = await api("/api/recipes");
    msg.textContent = t("backup.added", { n: res.added }) + (res.skipped ? t("backup.skipped", { n: res.skipped }) : ".");
    renderList();
  } catch (e) {
    msg.className = "msg err";
    msg.textContent = errorText(e);
  }
}

// ================= Szczegóły przepisu =================
function ingredientsHtml(r, portions, keyPrefix = "i") {
  let lastGroup = "";
  return r.ingredients.map((i, n) => {
    const head = i.group && i.group !== lastGroup ? `<li class="grp">${esc(i.group)}</li>` : "";
    lastGroup = i.group;
    return `${head}<li data-k="${keyPrefix}${n}"><span>${esc(i.name)}</span><span class="amt" dir="auto">${esc(ingredientAmount(i, portions, getLang()))}</span></li>`;
  }).join("") || "<li>—</li>";
}
/** Atrybuty języka i kierunku pisma dla treści przepisu. */
const contentAttrs = (r) => langAttrs(r.shownLanguage);

function stepper(id, value) {
  return `<span class="stepper" id="${id}">
    <button type="button" data-d="-1" aria-label="${esc(t("portions.less"))}">−</button>
    <b>${esc(portionsLabel(value))}</b>
    <button type="button" data-d="1" aria-label="${esc(t("portions.more"))}">+</button>
  </span>`;
}

function onStepper(el, get, set) {
  el.querySelectorAll("button").forEach((b) => {
    b.onclick = () => {
      const n = Math.min(99, Math.max(1, get() + Number(b.dataset.d)));
      if (n !== get()) set(n);
    };
  });
}

const showOriginal = new Set(); // przepisy, dla których użytkownik wybrał „Pokaż oryginał”
const translating = new Set();

async function translate(raw, lang) {
  translating.add(raw.id);
  renderIfOpen(raw);
  try {
    Object.assign(raw, await api(`/api/recipes/${raw.id}/translate`, { method: "POST", body: JSON.stringify({ language: lang }) }));
  } catch (e) {
    raw._translateError = errorText(e);
  } finally {
    translating.delete(raw.id);
    renderIfOpen(raw);
  }
}

function renderIfOpen(raw) {
  if (location.hash === `#/r/${raw.id}`) renderRecipe(raw);
}

function renderRecipe(raw) {
  if (!raw) { app.innerHTML = `<div class="empty">${esc(t("recipe.notFound"))} <a href="#/">${esc(t("back"))}</a></div>`; return; }
  const base = normalizeRecipe(raw);
  const pref = contentLang();
  const src = base.source_language;
  const hasOriginal = src && src !== pref;
  const wantOriginal = hasOriginal && showOriginal.has(base.id);
  const viewLang = wantOriginal ? src : pref;
  const shown = textIn(raw, viewLang);
  const r = shown || textIn(raw);
  const portions = portionsOf(raw);
  const inCart = shopping.recipes[r.id];
  const busy = translating.has(r.id);

  // Brak tekstu w wybranym języku: oryginał tłumaczymy od razu (użytkownik o to poprosił), resztę na przycisk
  if (!shown && wantOriginal && !busy && !raw._translateError) { translate(raw, src); return; }
  let langBar = "";
  if (busy) langBar = `<div class="lang-bar"><span class="spinner"></span> ${esc(t("lang.translating"))}</div>`;
  else if (raw._translateError) langBar = `<div class="lang-bar err">${esc(raw._translateError)}</div>`;
  else if (!shown) {
    langBar = `<div class="lang-bar">${esc(t("lang.recipeIn", { lang: langName(r.language) }))}
      <button type="button" id="translate">${esc(t("lang.translate", { lang: langName(viewLang) }))}</button></div>`;
  }
  const toggle = hasOriginal
    ? `<button type="button" class="lang-toggle" id="toggle-lang">${esc(wantOriginal
        ? t("lang.showTranslated", { lang: langName(pref) })
        : t("lang.showOriginal", { lang: langName(src) }))}</button>`
    : "";

  app.innerHTML = `
    <button class="back" onclick="location.hash='#/'">${esc(t("back"))}</button>
    <article class="card detail">
      ${thumb(r, "hero")}
      <div class="title-row"><h2 ${contentAttrs(r)}>${esc(r.title)}</h2><button class="icon-btn" id="rename" title="${esc(t("recipe.rename"))}">✏️</button></div>
      ${toggle}${langBar}
      <div class="meta" ${contentAttrs(r)}>${esc(r.summary)}</div>
      <div class="facts">
        ${r.prep_time ? `<span>${tHtml("recipe.prep", { t: `<bdi ${contentAttrs(r)}>${esc(r.prep_time)}</bdi>` })}</span>` : ""}
        ${r.cook_time ? `<span>${tHtml("recipe.cook", { t: `<bdi ${contentAttrs(r)}>${esc(r.cook_time)}</bdi>` })}</span>` : ""}
      </div>
      <div class="chips" ${contentAttrs(r)}>${(r.tags || []).map((x) => `<span class="chip">${esc(x)}</span>`).join("")}</div>
      <div class="row actions">
        <button class="primary" id="cook">${esc(t("recipe.cookMode"))}</button>
        <button id="cart">${esc(t(inCart ? "recipe.inCart" : "recipe.toCart"))}</button>
      </div>
      <div class="portions-row">
        <h4>${esc(t("recipe.ingredients"))}</h4>
        ${stepper("portions", portions)}
      </div>
      <div class="hint">${r.servings ? tHtml("recipe.inVideo", { s: `<bdi ${contentAttrs(r)}>${esc(r.servings)}</bdi>` }) : ""}${esc(t("recipe.perPortion"))}</div>
      <ul class="ing" ${contentAttrs(r)}>${ingredientsHtml(r, portions)}</ul>
      <h4>${esc(t("recipe.steps"))}</h4>
      <ol class="steps" ${contentAttrs(r)}>${r.steps.map((s, n) => `<li data-k="s${n}">${esc(s.text)}${s.minutes > 0 ? ` <button type="button" class="timer-chip" dir="${uiDir()}" data-step="${n}">⏲ ${esc(formatMinutes(s.minutes))}</button>` : ""}</li>`).join("")}</ol>
      ${r.tips?.length ? `<h4>${esc(t("recipe.tips"))}</h4><ul class="tips" ${contentAttrs(r)}>${r.tips.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>` : ""}
      <h4>${esc(t("recipe.myNotes"))}</h4>
      <textarea id="mynotes" dir="auto" placeholder="${esc(t("recipe.notesPlaceholder"))}">${esc(r.notes)}</textarea>
      <div class="msg" id="saved"></div>
      ${r.source?.description ? `<details><summary>${esc(t("recipe.originalDescription"))}</summary><div class="raw" dir="auto">${esc(r.source.description)}</div></details>` : ""}
      ${r.source?.transcript ? `<details><summary>${esc(t("recipe.transcript"))}</summary><div class="raw" dir="auto">${esc(r.source.transcript)}</div></details>` : ""}
      <div class="row actions">
        ${r.source?.url ? `<a href="${esc(r.source.url)}" target="_blank" rel="noopener"><button>${esc(t("recipe.openVideo"))}</button></a>` : ""}
        <button id="fav">${esc(t(r.favorite ? "recipe.favoriteOn" : "recipe.favoriteOff"))}</button>
        <button id="del">${esc(t("recipe.delete"))}</button>
      </div>
    </article>`;

  // odhaczanie składników i kroków (pamiętane lokalnie na tym urządzeniu)
  const done = loadDone(r.id);
  app.querySelectorAll("[data-k]").forEach((li) => {
    li.classList.toggle("done", !!done[li.dataset.k]);
    li.onclick = (e) => {
      if (e.target.closest("button")) return;
      done[li.dataset.k] = !done[li.dataset.k];
      li.classList.toggle("done", done[li.dataset.k]);
      saveDone(r.id, done);
    };
  });
  app.querySelectorAll(".timer-chip").forEach((b) => {
    b.onclick = () => startTimer(r.steps[b.dataset.step], r.title);
  });

  $("#toggle-lang")?.addEventListener("click", () => {
    delete raw._translateError;
    showOriginal.has(r.id) ? showOriginal.delete(r.id) : showOriginal.add(r.id);
    renderRecipe(raw);
  });
  $("#translate")?.addEventListener("click", () => translate(raw, viewLang));

  onStepper($("#portions"), () => portionsOf(raw), async (n) => {
    raw.portions = n;
    renderRecipe(raw);
    Object.assign(raw, await api(`/api/recipes/${r.id}`, { method: "PATCH", body: JSON.stringify({ portions: n }) }));
  });

  $("#cook").onclick = () => openCooking(raw, r);
  $("#cart").onclick = async () => {
    if (shopping.recipes[r.id]) { location.hash = "#/zakupy"; return; }
    shopping.recipes[r.id] = portionsOf(raw);
    await saveShopping();
    renderRecipe(raw);
  };

  let timer;
  $("#mynotes").oninput = (e) => {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      Object.assign(raw, await api(`/api/recipes/${r.id}`, { method: "PATCH", body: JSON.stringify({ notes: e.target.value }) }));
      $("#saved").textContent = t("recipe.notesSaved");
    }, 600);
  };
  $("#rename").onclick = async () => {
    const title = prompt(t("recipe.renamePrompt"), r.title)?.trim();
    if (!title || title === r.title) return;
    Object.assign(raw, await api(`/api/recipes/${r.id}`, {
      method: "PATCH", body: JSON.stringify({ title, language: r.shownLanguage }),
    }));
    renderRecipe(raw);
  };
  $("#fav").onclick = async () => {
    Object.assign(raw, await api(`/api/recipes/${r.id}`, { method: "PATCH", body: JSON.stringify({ favorite: !raw.favorite }) }));
    renderRecipe(raw);
  };
  $("#del").onclick = async () => {
    if (!confirm(t("recipe.confirmDelete", { title: r.title }))) return;
    await api(`/api/recipes/${r.id}`, { method: "DELETE" });
    recipes = recipes.filter((x) => x.id !== r.id);
    if (shopping.recipes[r.id]) { delete shopping.recipes[r.id]; await saveShopping(); }
    location.hash = "#/";
  };
}

function loadDone(id) {
  try { return JSON.parse(localStorage.getItem(`done:${id}`) || "{}"); } catch { return {}; }
}
function saveDone(id, done) {
  try { localStorage.setItem(`done:${id}`, JSON.stringify(done)); } catch {}
}

function formatMinutes(min) {
  if (min < 60) return t("time.min", { n: Math.round(min) });
  const h = Math.floor(min / 60), m = Math.round(min % 60);
  return m ? t("time.hmin", { h, m }) : t("time.h", { h });
}

// ================= Minutniki =================
const timers = []; // { id, label, endAt, total, done }
let audio;

function startTimer(step, recipeTitle) {
  try { audio ||= new AudioContext(); } catch {}
  if ("Notification" in window && Notification.permission === "default") Notification.requestPermission().catch(() => {});
  const label = truncate(step.text, 40);
  timers.push({ id: crypto.randomUUID(), label, recipeTitle, total: step.minutes * 60, endAt: Date.now() + step.minutes * 60_000, done: false });
  renderTimers();
}

function ring(timer) {
  timer.done = true;
  try {
    for (let i = 0; i < 3; i++) {
      const o = audio.createOscillator(), g = audio.createGain();
      o.frequency.value = 880;
      o.connect(g); g.connect(audio.destination);
      const at = audio.currentTime + i * 0.6;
      g.gain.setValueAtTime(0.3, at); g.gain.exponentialRampToValueAtTime(0.001, at + 0.5);
      o.start(at); o.stop(at + 0.5);
    }
  } catch {}
  navigator.vibrate?.([300, 150, 300, 150, 300]);
  if ("Notification" in window && Notification.permission === "granted" && document.hidden) {
    new Notification(t("timer.notification"), { body: `${timer.recipeTitle}: ${timer.label}` });
  }
}

function renderTimers() {
  const bar = $("#timers");
  bar.hidden = !timers.length;
  bar.innerHTML = timers.map((tm) => {
    const left = (tm.endAt - Date.now()) / 1000;
    return `<div class="timer ${tm.done ? "ringing" : ""}">
      <span class="t-time">${tm.done ? esc(t("timer.done")) : formatClock(left)}</span>
      <span class="t-label" dir="auto">${esc(tm.label)}</span>
      <button type="button" data-id="${tm.id}" aria-label="${esc(t("timer.remove"))}">✕</button>
    </div>`;
  }).join("");
  bar.querySelectorAll("button").forEach((b) => {
    b.onclick = () => { timers.splice(timers.findIndex((tm) => tm.id === b.dataset.id), 1); renderTimers(); };
  });
}

setInterval(() => {
  if (!timers.length) return;
  for (const tm of timers) if (!tm.done && Date.now() >= tm.endAt) ring(tm);
  renderTimers();
}, 500);

// ================= Tryb gotowania =================
let wakeLock = null;
async function keepAwake(on) {
  try {
    if (on && !wakeLock && "wakeLock" in navigator) {
      wakeLock = await navigator.wakeLock.request("screen");
      wakeLock.addEventListener("release", () => { wakeLock = null; });
    } else if (!on && wakeLock) {
      await wakeLock.release();
      wakeLock = null;
    }
  } catch {}
}
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && !$("#cooking").hidden) keepAwake(true);
});

function openCooking(raw, shownRecipe) {
  const r = shownRecipe || localized(raw);
  const overlay = $("#cooking");
  const total = r.steps.length + 1; // slajd 0 = składniki
  let index = 0;
  let portions = portionsOf(raw);
  const done = loadDone(r.id);

  const slide = () => {
    if (index === 0) {
      return `<div class="c-kicker">${esc(t("cook.ingredients"))}</div>
        <div class="c-portions">${stepper("c-portions", portions)}</div>
        <ul class="ing c-ing" ${contentAttrs(r)}>${ingredientsHtml(r, portions, "c")}</ul>`;
    }
    const s = r.steps[index - 1];
    return `<div class="c-kicker">${esc(t("cook.step", { i: index, n: r.steps.length }))}</div>
      <p class="c-step" ${contentAttrs(r)}>${esc(s.text)}</p>
      ${s.minutes > 0 ? `<button type="button" class="primary c-timer" dir="${uiDir()}">${esc(t("timer.start", { t: formatMinutes(s.minutes) }))}</button>` : ""}`;
  };

  const render = () => {
    overlay.innerHTML = `
      <div class="c-top">
        <button type="button" id="c-close" aria-label="${esc(t("cook.close"))}">✕</button>
        <div class="c-title" ${contentAttrs(r)}>${esc(r.title)}</div>
      </div>
      <div class="c-progress"><div style="width:${(index / (total - 1)) * 100}%"></div></div>
      <div class="c-body">${slide()}</div>
      <div class="c-nav">
        <button type="button" id="c-prev" ${index === 0 ? "disabled" : ""}>${esc(t("cook.prev"))}</button>
        <button type="button" class="primary" id="c-next">${esc(t(index === total - 1 ? "cook.finish" : "cook.next"))}</button>
      </div>`;
    $("#c-close").onclick = close;
    $("#c-prev").onclick = () => go(-1);
    $("#c-next").onclick = () => (index === total - 1 ? close() : go(1));
    const timerBtn = $(".c-timer", overlay);
    if (timerBtn) timerBtn.onclick = () => startTimer(r.steps[index - 1], r.title);
    const st = $("#c-portions");
    if (st) onStepper(st, () => portions, (n) => { portions = n; render(); });
    overlay.querySelectorAll(".c-ing [data-k]").forEach((li) => {
      const k = "i" + li.dataset.k.slice(1); // te same odhaczenia co na stronie przepisu
      li.classList.toggle("done", !!done[k]);
      li.onclick = () => { done[k] = !done[k]; li.classList.toggle("done", done[k]); saveDone(r.id, done); };
    });
  };

  const go = (d) => { index = Math.min(total - 1, Math.max(0, index + d)); render(); };
  const onKey = (e) => {
    const rtl = getComputedStyle(document.documentElement).direction === "rtl";
    if (e.key === (rtl ? "ArrowLeft" : "ArrowRight")) go(1);
    else if (e.key === (rtl ? "ArrowRight" : "ArrowLeft")) go(-1);
    else if (e.key === "Escape") close();
  };
  let touchX = null;
  const onTouchStart = (e) => { touchX = e.touches[0].clientX; };
  const onTouchEnd = (e) => {
    if (touchX == null) return;
    const dx = e.changedTouches[0].clientX - touchX;
    touchX = null;
    const rtl = getComputedStyle(document.documentElement).direction === "rtl";
    if (Math.abs(dx) > 60) go((dx < 0) !== rtl ? 1 : -1);
  };
  function close() {
    overlay.hidden = true;
    document.body.classList.remove("no-scroll");
    document.removeEventListener("keydown", onKey);
    overlay.removeEventListener("touchstart", onTouchStart);
    overlay.removeEventListener("touchend", onTouchEnd);
    keepAwake(false);
    if (location.hash === `#/r/${r.id}`) renderRecipe(raw);
  }

  overlay.hidden = false;
  document.body.classList.add("no-scroll");
  document.addEventListener("keydown", onKey);
  overlay.addEventListener("touchstart", onTouchStart, { passive: true });
  overlay.addEventListener("touchend", onTouchEnd);
  keepAwake(true);
  render();
}

// ================= Lista zakupów =================
function renderShopping() {
  const entries = Object.entries(shopping.recipes)
    .map(([id, portions]) => ({ recipe: recipes.find((r) => r.id === id), portions }))
    .filter((e) => e.recipe);
  const lang = contentLang();
  const { groups, removed } = buildShoppingList(entries, shopping.extras, shopping.overrides, lang);
  const checked = new Set(shopping.checked);
  const categoryOptions = (selected) =>
    CATEGORIES.map((c) => `<option value="${c}" ${c === selected ? "selected" : ""}>${esc(categoryLabel(c, getLang()))}</option>`).join("");

  app.innerHTML = `
    <button class="back" onclick="location.hash='#/'">${esc(t("back"))}</button>
    <section class="card">
      <h2 class="shop-title">${esc(t("shop.title"))}</h2>
      <form id="extra-form" class="add-item">
        <div class="row">
          <input class="grow" id="extra-name" dir="auto" placeholder="${esc(t("shop.addPlaceholder"))}" autocomplete="off" required>
          <input id="extra-amount" class="amount-input" dir="auto" placeholder="${esc(t("shop.amount"))}" autocomplete="off">
        </div>
        <div class="row">
          <select id="extra-category" class="grow" aria-label="${esc(t("shop.category"))}">${categoryOptions("other")}</select>
          <button type="submit" class="primary">${esc(t("shop.add"))}</button>
        </div>
        <div class="msg" id="shop-msg"></div>
      </form>
      ${entries.length ? `<h4>${esc(t("shop.fromRecipes"))}</h4><ul class="cart">${entries.map(({ recipe, portions }) => `
        <li>
          <a href="#/r/${recipe.id}" class="grow" ${langAttrs(localized(recipe).shownLanguage)}>${esc(recipe.emoji || "🍳")} ${esc(localized(recipe).title)}</a>
          ${stepper(`cart-${recipe.id}`, portions)}
          <button type="button" class="icon-btn" data-remove="${recipe.id}" aria-label="${esc(t("shop.removeRecipe"))}">✕</button>
        </li>`).join("")}</ul>` : `<p class="hint">${esc(t("shop.hint"))}</p>`}
    </section>
    ${groups.length ? `<section class="card shop">
      ${groups.map((g) => `<h4>${esc(g.label)}</h4><ul class="ing">${g.items.map((i) => `
        <li data-key="${esc(i.key)}" class="${checked.has(i.key) ? "done" : ""}">
          <span class="grow">
            <bdi dir="auto">${esc(i.name)}</bdi>
            ${i.extra ? `<span class="badge">${esc(t("shop.extraBadge"))}</span>` : i.edited ? `<span class="badge">${esc(t("shop.editedBadge"))}</span>` : ""}
            ${i.recipes.length > 1 ? `<span class="sub">${esc(i.recipes.join(", "))}</span>` : ""}
          </span>
          <span class="amt" dir="auto">${esc(i.amount)}</span>
          <button type="button" class="icon-btn edit" data-edit="${esc(i.key)}" aria-label="${esc(t("shop.edit", { name: i.name }))}">✏️</button>
        </li>`).join("")}</ul>`).join("")}
      <div class="row actions">
        <button type="button" class="primary" id="share-list">${esc(t("shop.share"))}</button>
        <button type="button" id="clear-all">${esc(t("shop.clear"))}</button>
      </div>
    </section>` : ""}
    ${removed.length ? `<details class="card removed">
      <summary>${esc(t("shop.removed", { n: removed.length }))}</summary>
      <ul class="ing">${removed.map((i) => `
        <li><span class="grow" dir="auto">${esc(i.name)}</span><span class="amt">${esc(i.amount)}</span>
          <button type="button" data-restore="${esc(i.key)}">${esc(t("shop.restore"))}</button></li>`).join("")}</ul>
    </details>` : ""}
    <dialog id="item-dialog">
      <form method="dialog" id="item-form">
        <h3 id="item-title"></h3>
        <label>${esc(t("shop.name"))}<input id="item-name" dir="auto" required autocomplete="off"></label>
        <label>${esc(t("shop.amount"))}<input id="item-amount" dir="auto" autocomplete="off" placeholder="${esc(t("shop.amountPh"))}"></label>
        <label id="item-category-label">${esc(t("shop.category"))}<select id="item-category">${categoryOptions("other")}</select></label>
        <p class="hint" id="item-original"></p>
        <div class="row actions">
          <button type="submit" class="primary" value="save">${esc(t("shop.save"))}</button>
          <button type="button" id="item-reset">${esc(t("shop.reset"))}</button>
          <button type="button" id="item-delete">${esc(t("shop.delete"))}</button>
          <button type="button" id="item-cancel">${esc(t("shop.cancel"))}</button>
        </div>
      </form>
    </dialog>`;

  const persist = async () => { renderShopping(); await saveShopping(); };
  const setOverride = (key, patch) => {
    const next = { ...(shopping.overrides[key] || {}), ...patch };
    for (const k of Object.keys(next)) if (next[k] === undefined) delete next[k];
    shopping.overrides = { ...shopping.overrides, [key]: next };
    if (!Object.keys(next).length) delete shopping.overrides[key];
  };

  for (const { recipe } of entries) {
    onStepper($(`#cart-${CSS.escape(recipe.id)}`), () => shopping.recipes[recipe.id], async (n) => {
      shopping.recipes[recipe.id] = n;
      await persist();
    });
  }
  app.querySelectorAll("[data-remove]").forEach((b) => {
    b.onclick = async () => { delete shopping.recipes[b.dataset.remove]; await persist(); };
  });
  app.querySelectorAll("[data-restore]").forEach((b) => {
    b.onclick = async () => { setOverride(b.dataset.restore, { removed: undefined }); await persist(); };
  });

  // Odhaczanie (stuknięcie w wiersz) i edycja (ołówek)
  app.querySelectorAll("li[data-key]").forEach((li) => {
    li.onclick = async (e) => {
      if (e.target.closest("button")) return;
      const k = li.dataset.key;
      shopping.checked = checked.has(k) ? shopping.checked.filter((x) => x !== k) : [...shopping.checked, k];
      checked.has(k) ? checked.delete(k) : checked.add(k);
      li.classList.toggle("done");
      await saveShopping();
    };
  });
  const allItems = groups.flatMap((g) => g.items);
  app.querySelectorAll("[data-edit]").forEach((b) => {
    b.onclick = () => openItemEditor(allItems.find((i) => i.key === b.dataset.edit));
  });

  function openItemEditor(item) {
    const dialog = $("#item-dialog");
    $("#item-title").textContent = t(item.extra ? "shop.dlgExtra" : "shop.dlgRecipe");
    $("#item-name").value = item.name;
    $("#item-amount").value = item.amount;
    $("#item-category-label").hidden = !item.extra;
    if (item.extra) $("#item-category").value = item.category;
    $("#item-reset").hidden = item.extra || !item.edited;
    $("#item-original").textContent = item.extra ? "" : t("shop.fromInfo", {
      recipes: item.recipes.join(", "),
      original: `${item.original.name}${item.original.amount ? " – " + item.original.amount : ""}`,
    });
    const close = () => dialog.close();
    $("#item-cancel").onclick = close;
    $("#item-delete").onclick = async () => {
      close();
      if (item.extra) shopping.extras = shopping.extras.filter((e) => normalizeExtra(e).id !== item.id);
      else setOverride(item.key, { removed: true });
      await persist();
    };
    $("#item-reset").onclick = async () => {
      close();
      setOverride(item.key, { name: undefined, amount: undefined });
      await persist();
    };
    $("#item-form").onsubmit = async (e) => {
      e.preventDefault();
      if (composing) return;
      const name = $("#item-name").value.trim();
      const amount = $("#item-amount").value.trim();
      if (!name) return;
      close();
      if (item.extra) {
        shopping.extras = shopping.extras.map((x, i) => {
          const n = normalizeExtra(x, i);
          return n.id === item.id ? { ...n, name, amount, category: $("#item-category").value } : n;
        });
      } else {
        setOverride(item.key, {
          name: name !== item.original.name ? name : undefined,
          amount: amount !== item.original.amount ? amount : undefined,
        });
      }
      await persist();
    };
    dialog.showModal();
    $("#item-amount").focus();
  }

  // Dopisywanie własnych pozycji; dział podpowiadany na podstawie składników z przepisów
  $("#extra-name").oninput = (e) => {
    const guess = guessCategory(e.target.value, recipes);
    if (guess !== "other") $("#extra-category").value = guess;
  };
  $("#extra-form").onsubmit = async (e) => {
    e.preventDefault();
    if (composing) return;
    const name = $("#extra-name").value.trim();
    const amount = $("#extra-amount").value.trim();
    if (!name) return;
    // To samo już jest na liście z przepisu (np. „sól do smaku”)? Zamiast duplikatu zmieniamy tamtą pozycję.
    const same = (i) => !i.extra && normName(i.name) === normName(name);
    const existing = allItems.find(same) || removed.find(same);
    if (existing) {
      setOverride(existing.key, { removed: undefined, ...(amount ? { amount } : {}) });
      shopping.checked = shopping.checked.filter((k) => k !== existing.key);
      await persist();
      $("#shop-msg").textContent = amount
        ? t("shop.merged", { name: existing.name, amount })
        : t("shop.mergedSame", { name: existing.name });
      return;
    }
    shopping.extras = [...shopping.extras.map(normalizeExtra), {
      id: crypto.randomUUID(), name, amount, category: $("#extra-category").value,
    }];
    await persist();
    $("#extra-name").focus();
  };

  if (!groups.length) return;
  $("#share-list").onclick = async () => {
    const text = `${t("shop.title")}\n\n` + shoppingListText(groups, shopping.checked);
    try {
      if (navigator.share) await navigator.share({ title: t("shop.title"), text });
      else { await navigator.clipboard.writeText(text); $("#shop-msg").textContent = t("shop.copied"); }
    } catch {}
  };
  $("#clear-all").onclick = async () => {
    if (!confirm(t("shop.clearConfirm"))) return;
    shopping = { recipes: {}, checked: [], extras: [], overrides: {} };
    await persist();
  };
}

// ================= Routing =================
async function route() {
  const m = location.hash.match(/^#\/r\/(.+)$/);
  document.querySelectorAll("nav a").forEach((a) => a.classList.toggle("active", a.getAttribute("href") === (location.hash.startsWith("#/zakupy") ? "#/zakupy" : "#/")));
  if (m) {
    const r = recipes.find((x) => x.id === m[1]) || await api(`/api/recipes/${m[1]}`).catch(() => null);
    renderRecipe(r);
  } else if (location.hash.startsWith("#/zakupy")) {
    renderShopping();
  } else {
    renderHome();
  }
  window.scrollTo(0, 0);
}

/** Teksty w stałej części strony (nagłówek, nawigacja). */
function applyStaticTexts() {
  document.documentElement.lang = getLang();
  document.documentElement.dir = uiDir();
  document.title = t("app.title");
  $("header h1").textContent = t("app.title");
  $("#nav-recipes").textContent = t("nav.recipes");
}

async function start() {
  applyStaticTexts();
  try {
    [recipes, shopping] = await Promise.all([api("/api/recipes"), api("/api/shopping")]);
  } catch (e) {
    app.innerHTML = `<div class="empty">${esc(e.message)}</div>`;
    return;
  }
  updateNav();

  // Udostępnienie z TikToka (Web Share Target) -> /?title=&text=&url=
  const p = new URLSearchParams(location.search);
  const shared = [p.get("url"), p.get("text"), p.get("title")].filter(Boolean).join(" ");
  if (shared) {
    history.replaceState(null, "", "/");
    const link = (shared.match(/https?:\/\/\S*tiktok\.com\/\S+/i) || [])[0];
    renderHome({ url: link || "", notes: link ? "" : shared });
    if (link) submit();
    return;
  }
  route();
}

window.addEventListener("hashchange", route);
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
start();
