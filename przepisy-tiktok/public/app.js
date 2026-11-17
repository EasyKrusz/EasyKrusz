import {
  normalizeRecipe, portionsOf, ingredientAmount, buildShoppingList, shoppingListText, formatClock,
} from "./kitchen.js";

const app = document.getElementById("app");
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const $ = (sel, root = document) => root.querySelector(sel);

let recipes = [];
let shopping = { recipes: {}, checked: [], extras: [] };
let query = "";

async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...opts });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.error || `Błąd ${res.status}`), data);
  return data;
}

const plural = (n, one, few, many) => {
  const d = n % 10, t = n % 100;
  return n === 1 ? one : d >= 2 && d <= 4 && (t < 12 || t > 14) ? few : many;
};
const portionsLabel = (n) => `${n} ${plural(n, "porcja", "porcje", "porcji")}`;

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
  $("#nav-shop").textContent = n ? `🛒 Zakupy (${n})` : "🛒 Zakupy";
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
        <input class="grow" id="url" placeholder="Wklej link do filmiku z TikToka" inputmode="url" autocomplete="off" value="${esc(prefill.url)}">
        <button class="primary" id="go">Zapisz przepis</button>
      </div>
      <details ${prefill.notes ? "open" : ""}>
        <summary>Notatki (opcjonalnie) – gdy przepisu nie ma ani w opisie, ani w napisach filmiku</summary>
        <textarea id="notes" placeholder="Np. 200 g makaronu, 2 ząbki czosnku… albo cały przepis, jeśli nie ma go w opisie">${esc(prefill.notes)}</textarea>
      </details>
      <div class="msg" id="msg"></div>
    </form>
    <input class="search" id="q" type="search" placeholder="Szukaj w przepisach, składnikach, tagach…" value="${esc(query)}">
    <div class="list" id="list"></div>
    <footer class="backup">
      <span>Kopia zapasowa:</span>
      <a href="/api/backup" download><button type="button">⬇ Pobierz plik</button></a>
      <button type="button" id="import">⬆ Wczytaj plik</button>
      <input type="file" id="import-file" accept="application/json,.json" hidden>
      <div class="msg" id="backup-msg"></div>
    </footer>`;
  $("#add").onsubmit = (e) => { e.preventDefault(); submit(); };
  $("#q").oninput = (e) => { query = e.target.value; renderList(); };
  $("#import").onclick = () => $("#import-file").click();
  $("#import-file").onchange = (e) => importBackup(e.target.files[0]);
  renderList();
}

function matches(r, q) {
  if (!q) return true;
  const hay = [r.title, r.summary, r.source?.author, ...(r.tags || []), ...(r.ingredients || []).map((i) => i.name)]
    .join(" ").toLowerCase();
  return q.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
}

function renderList() {
  const el = $("#list");
  if (!el) return;
  const shown = recipes.filter((r) => matches(r, query))
    .sort((a, b) => (b.favorite - a.favorite) || b.createdAt.localeCompare(a.createdAt));
  if (!recipes.length) { el.innerHTML = `<div class="empty">Nie masz jeszcze przepisów.<br>Wklej link do TikToka powyżej albo udostępnij filmik do tej aplikacji.</div>`; return; }
  if (!shown.length) { el.innerHTML = `<div class="empty">Nic nie pasuje do „${esc(query)}”.</div>`; return; }
  el.innerHTML = shown.map((r) => `
    <a class="card item" href="#/r/${r.id}">
      ${thumb(r)}
      <div class="grow">
        <h3>${r.favorite ? "★ " : ""}${esc(r.title)}</h3>
        <div class="meta">${[r.prep_time && "⏱ " + r.prep_time, r.servings, r.source?.author && "@" + r.source.author, shopping.recipes[r.id] && "🛒"].filter(Boolean).map(esc).join(" · ")}</div>
        <div class="chips">${(r.tags || []).slice(0, 4).map((t) => `<span class="chip">${esc(t)}</span>`).join("")}</div>
      </div>
    </a>`).join("");
}

async function submit(force = false) {
  const url = $("#url").value.trim();
  const notes = $("#notes").value.trim();
  const btn = $("#go");
  const msg = $("#msg");
  if (!url && !notes) { msg.className = "msg err"; msg.textContent = "Wklej link albo wpisz przepis w notatkach."; return; }
  btn.disabled = true; msg.className = "msg";
  msg.innerHTML = `<span class="spinner"></span> Pobieram opis i napisy filmiku, układam przepis…`;
  try {
    const { recipe, duplicate } = await api("/api/recipes", { method: "POST", body: JSON.stringify({ url, notes, force }) });
    if (duplicate) {
      msg.innerHTML = `Ten filmik jest już zapisany: <a href="#/r/${recipe.id}">${esc(recipe.title)}</a>. <button type="button" id="again">Przetwórz ponownie</button>`;
      $("#again").onclick = () => submit(true);
      return;
    }
    recipes.unshift(recipe);
    location.hash = `#/r/${recipe.id}`;
  } catch (e) {
    msg.className = "msg err";
    msg.innerHTML = esc(e.message) + (e.description ? `<details><summary>Pobrany opis</summary><div class="raw">${esc(e.description)}</div></details>` : "");
    if (e.status === 422 || /opisu/.test(e.message)) $("#add details").open = true;
  } finally {
    btn.disabled = false;
  }
}

async function importBackup(file) {
  const msg = $("#backup-msg");
  if (!file) return;
  msg.className = "msg";
  msg.innerHTML = `<span class="spinner"></span> Wczytuję…`;
  try {
    const res = await api("/api/backup", { method: "POST", body: await file.text() });
    recipes = await api("/api/recipes");
    msg.textContent = `Dodano ${res.added} ${plural(res.added, "przepis", "przepisy", "przepisów")}` +
      (res.skipped ? `, pominięto ${res.skipped} (już były zapisane).` : ".");
    renderList();
  } catch (e) {
    msg.className = "msg err";
    msg.textContent = e.message;
  }
}

// ================= Szczegóły przepisu =================
function ingredientsHtml(r, portions, keyPrefix = "i") {
  let lastGroup = "";
  return r.ingredients.map((i, n) => {
    const head = i.group && i.group !== lastGroup ? `<li class="grp">${esc(i.group)}</li>` : "";
    lastGroup = i.group;
    return `${head}<li data-k="${keyPrefix}${n}"><span>${esc(i.name)}</span><span class="amt">${esc(ingredientAmount(i, portions))}</span></li>`;
  }).join("") || "<li>—</li>";
}

function stepper(id, value) {
  return `<span class="stepper" id="${id}">
    <button type="button" data-d="-1" aria-label="Mniej porcji">−</button>
    <b>${esc(portionsLabel(value))}</b>
    <button type="button" data-d="1" aria-label="Więcej porcji">+</button>
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

function renderRecipe(raw) {
  if (!raw) { app.innerHTML = `<div class="empty">Nie ma takiego przepisu. <a href="#/">Wróć</a></div>`; return; }
  const r = normalizeRecipe(raw);
  const portions = portionsOf(raw);
  const inCart = shopping.recipes[r.id];

  app.innerHTML = `
    <button class="back" onclick="location.hash='#/'">← Wszystkie przepisy</button>
    <article class="card detail">
      ${thumb(r, "hero")}
      <div class="title-row"><h2>${esc(r.title)}</h2><button class="icon-btn" id="rename" title="Zmień nazwę">✏️</button></div>
      <div class="meta">${esc(r.summary)}</div>
      <div class="facts">
        ${r.prep_time ? `<span>⏱ przygotowanie: ${esc(r.prep_time)}</span>` : ""}
        ${r.cook_time ? `<span>🔥 gotowanie: ${esc(r.cook_time)}</span>` : ""}
      </div>
      <div class="chips">${(r.tags || []).map((t) => `<span class="chip">${esc(t)}</span>`).join("")}</div>
      <div class="row actions">
        <button class="primary" id="cook">👩‍🍳 Gotuj krok po kroku</button>
        <button id="cart">${inCart ? "🛒 Na liście zakupów ✓" : "🛒 Do listy zakupów"}</button>
      </div>
      <div class="portions-row">
        <h4>Składniki</h4>
        ${stepper("portions", portions)}
      </div>
      <div class="hint">${r.servings ? `W filmiku: ${esc(r.servings)}. ` : ""}Ilości są liczone z 1 porcji × liczba porcji.</div>
      <ul class="ing">${ingredientsHtml(r, portions)}</ul>
      <h4>Przygotowanie</h4>
      <ol class="steps">${r.steps.map((s, n) => `<li data-k="s${n}">${esc(s.text)}${s.minutes > 0 ? ` <button type="button" class="timer-chip" data-step="${n}">⏲ ${esc(formatMinutes(s.minutes))}</button>` : ""}</li>`).join("")}</ol>
      ${r.tips?.length ? `<h4>Wskazówki</h4><ul class="tips">${r.tips.map((t) => `<li>${esc(t)}</li>`).join("")}</ul>` : ""}
      <h4>Moje notatki</h4>
      <textarea id="mynotes" placeholder="Np. następnym razem mniej soli">${esc(r.notes)}</textarea>
      <div class="msg" id="saved"></div>
      ${r.source?.description ? `<details><summary>Oryginalny opis z TikToka</summary><div class="raw">${esc(r.source.description)}</div></details>` : ""}
      ${r.source?.transcript ? `<details><summary>Transkrypcja z napisów filmiku</summary><div class="raw">${esc(r.source.transcript)}</div></details>` : ""}
      <div class="row actions">
        ${r.source?.url ? `<a href="${esc(r.source.url)}" target="_blank" rel="noopener"><button>▶ Otwórz filmik</button></a>` : ""}
        <button id="fav">${r.favorite ? "★ Ulubiony" : "☆ Do ulubionych"}</button>
        <button id="del">Usuń</button>
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

  onStepper($("#portions"), () => portionsOf(raw), async (n) => {
    raw.portions = n;
    renderRecipe(raw);
    Object.assign(raw, await api(`/api/recipes/${r.id}`, { method: "PATCH", body: JSON.stringify({ portions: n }) }));
  });

  $("#cook").onclick = () => openCooking(raw);
  $("#cart").onclick = async () => {
    if (shopping.recipes[r.id]) { location.hash = "#/zakupy"; return; }
    shopping.recipes[r.id] = portionsOf(raw);
    await saveShopping();
    renderRecipe(raw);
  };

  let t;
  $("#mynotes").oninput = (e) => {
    clearTimeout(t);
    t = setTimeout(async () => {
      Object.assign(raw, await api(`/api/recipes/${r.id}`, { method: "PATCH", body: JSON.stringify({ notes: e.target.value }) }));
      $("#saved").textContent = "Zapisano notatki ✓";
    }, 600);
  };
  $("#rename").onclick = async () => {
    const title = prompt("Nazwa przepisu", r.title)?.trim();
    if (!title || title === r.title) return;
    Object.assign(raw, await api(`/api/recipes/${r.id}`, { method: "PATCH", body: JSON.stringify({ title }) }));
    renderRecipe(raw);
  };
  $("#fav").onclick = async () => {
    Object.assign(raw, await api(`/api/recipes/${r.id}`, { method: "PATCH", body: JSON.stringify({ favorite: !raw.favorite }) }));
    renderRecipe(raw);
  };
  $("#del").onclick = async () => {
    if (!confirm(`Usunąć „${r.title}”?`)) return;
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
  if (min < 60) return `${Math.round(min)} min`;
  const h = Math.floor(min / 60), m = Math.round(min % 60);
  return m ? `${h} h ${m} min` : `${h} h`;
}

// ================= Minutniki =================
const timers = []; // { id, label, endAt, total, done }
let audio;

function startTimer(step, recipeTitle) {
  try { audio ||= new AudioContext(); } catch {}
  if ("Notification" in window && Notification.permission === "default") Notification.requestPermission().catch(() => {});
  const label = step.text.length > 40 ? step.text.slice(0, 40) + "…" : step.text;
  timers.push({ id: crypto.randomUUID(), label, recipeTitle, total: step.minutes * 60, endAt: Date.now() + step.minutes * 60_000, done: false });
  renderTimers();
}

function ring(t) {
  t.done = true;
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
    new Notification("⏰ Minutnik", { body: `${t.recipeTitle}: ${t.label}` });
  }
}

function renderTimers() {
  const bar = $("#timers");
  bar.hidden = !timers.length;
  bar.innerHTML = timers.map((t) => {
    const left = (t.endAt - Date.now()) / 1000;
    return `<div class="timer ${t.done ? "ringing" : ""}">
      <span class="t-time">${t.done ? "Gotowe!" : formatClock(left)}</span>
      <span class="t-label">${esc(t.label)}</span>
      <button type="button" data-id="${t.id}" aria-label="Usuń minutnik">✕</button>
    </div>`;
  }).join("");
  bar.querySelectorAll("button").forEach((b) => {
    b.onclick = () => { timers.splice(timers.findIndex((t) => t.id === b.dataset.id), 1); renderTimers(); };
  });
}

setInterval(() => {
  if (!timers.length) return;
  for (const t of timers) if (!t.done && Date.now() >= t.endAt) ring(t);
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

function openCooking(raw) {
  const r = normalizeRecipe(raw);
  const overlay = $("#cooking");
  const total = r.steps.length + 1; // slajd 0 = składniki
  let index = 0;
  let portions = portionsOf(raw);
  const done = loadDone(r.id);

  const slide = () => {
    if (index === 0) {
      return `<div class="c-kicker">Przygotuj składniki</div>
        <div class="c-portions">${stepper("c-portions", portions)}</div>
        <ul class="ing c-ing">${ingredientsHtml(r, portions, "c")}</ul>`;
    }
    const s = r.steps[index - 1];
    return `<div class="c-kicker">Krok ${index} z ${r.steps.length}</div>
      <p class="c-step">${esc(s.text)}</p>
      ${s.minutes > 0 ? `<button type="button" class="primary c-timer">⏲ Włącz minutnik: ${esc(formatMinutes(s.minutes))}</button>` : ""}`;
  };

  const render = () => {
    overlay.innerHTML = `
      <div class="c-top">
        <button type="button" id="c-close" aria-label="Zamknij">✕</button>
        <div class="c-title">${esc(r.title)}</div>
      </div>
      <div class="c-progress"><div style="width:${(index / (total - 1)) * 100}%"></div></div>
      <div class="c-body">${slide()}</div>
      <div class="c-nav">
        <button type="button" id="c-prev" ${index === 0 ? "disabled" : ""}>← Wstecz</button>
        <button type="button" class="primary" id="c-next">${index === total - 1 ? "Gotowe 🎉" : "Dalej →"}</button>
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
    if (e.key === "ArrowRight") go(1);
    else if (e.key === "ArrowLeft") go(-1);
    else if (e.key === "Escape") close();
  };
  let touchX = null;
  const onTouchStart = (e) => { touchX = e.touches[0].clientX; };
  const onTouchEnd = (e) => {
    if (touchX == null) return;
    const dx = e.changedTouches[0].clientX - touchX;
    touchX = null;
    if (Math.abs(dx) > 60) go(dx < 0 ? 1 : -1);
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
  const groups = buildShoppingList(entries, shopping.extras);
  const checked = new Set(shopping.checked);

  app.innerHTML = `
    <button class="back" onclick="location.hash='#/'">← Wszystkie przepisy</button>
    <section class="card">
      <h2 class="shop-title">Lista zakupów</h2>
      ${entries.length ? `<ul class="cart">${entries.map(({ recipe, portions }) => `
        <li>
          <a href="#/r/${recipe.id}" class="grow">${esc(recipe.emoji || "🍳")} ${esc(recipe.title)}</a>
          ${stepper(`cart-${recipe.id}`, portions)}
          <button type="button" class="icon-btn" data-remove="${recipe.id}" aria-label="Usuń z listy">✕</button>
        </li>`).join("")}</ul>` : `<p class="hint">Dodaj przepisy przyciskiem „🛒 Do listy zakupów” na stronie przepisu.</p>`}
      <form class="row" id="extra-form">
        <input class="grow" id="extra" placeholder="Dopisz coś jeszcze, np. papier do pieczenia" autocomplete="off">
        <button type="submit">Dodaj</button>
      </form>
    </section>
    ${groups.length ? `<section class="card shop">
      ${groups.map((g) => `<h4>${esc(g.category)}</h4><ul class="ing">${g.items.map((i) => `
        <li data-key="${esc(i.key)}" class="${checked.has(i.key) ? "done" : ""}" title="${esc(i.recipes.join(", "))}">
          <span>${esc(i.name)}${i.extra ? ` <button type="button" class="link" data-extra="${esc(i.name)}">usuń</button>` : ""}</span>
          <span class="amt">${esc(i.amount)}</span>
        </li>`).join("")}</ul>`).join("")}
      <div class="row actions">
        <button type="button" class="primary" id="share-list">📤 Wyślij / kopiuj listę</button>
        <button type="button" id="clear-all">Wyczyść listę</button>
      </div>
      <div class="msg" id="shop-msg"></div>
    </section>` : ""}`;

  for (const { recipe } of entries) {
    onStepper($(`#cart-${CSS.escape(recipe.id)}`), () => shopping.recipes[recipe.id], async (n) => {
      shopping.recipes[recipe.id] = n;
      renderShopping();
      await saveShopping();
    });
  }
  app.querySelectorAll("[data-remove]").forEach((b) => {
    b.onclick = async () => { delete shopping.recipes[b.dataset.remove]; renderShopping(); await saveShopping(); };
  });
  app.querySelectorAll("[data-extra]").forEach((b) => {
    b.onclick = async (e) => {
      e.stopPropagation();
      shopping.extras = shopping.extras.filter((x) => x !== b.dataset.extra);
      renderShopping(); await saveShopping();
    };
  });
  app.querySelectorAll("li[data-key]").forEach((li) => {
    li.onclick = async () => {
      const k = li.dataset.key;
      shopping.checked = checked.has(k) ? shopping.checked.filter((x) => x !== k) : [...shopping.checked, k];
      checked.has(k) ? checked.delete(k) : checked.add(k);
      li.classList.toggle("done");
      await saveShopping();
    };
  });
  $("#extra-form").onsubmit = async (e) => {
    e.preventDefault();
    const text = $("#extra").value.trim();
    if (!text) return;
    shopping.extras.push(text);
    renderShopping(); await saveShopping();
    $("#extra").focus();
  };
  if (!groups.length) return;
  $("#share-list").onclick = async () => {
    const text = "Lista zakupów\n\n" + shoppingListText(groups, shopping.checked);
    try {
      if (navigator.share) await navigator.share({ title: "Lista zakupów", text });
      else { await navigator.clipboard.writeText(text); $("#shop-msg").textContent = "Skopiowano listę do schowka ✓"; }
    } catch {}
  };
  $("#clear-all").onclick = async () => {
    if (!confirm("Wyczyścić całą listę zakupów?")) return;
    shopping = { recipes: {}, checked: [], extras: [] };
    renderShopping(); await saveShopping();
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

async function start() {
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
