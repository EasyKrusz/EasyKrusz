// Pobieranie opisu (caption) filmiku z TikToka.
// 1) oficjalny, publiczny endpoint oEmbed (bez klucza API),
// 2) awaryjnie: parsowanie danych osadzonych w stronie filmiku.

const UA =
  "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36";

export function extractTikTokUrl(text) {
  if (!text) return null;
  const m = String(text).match(/https?:\/\/(?:[\w-]+\.)?tiktok\.com\/[^\s"'<>]+/i);
  return m ? m[0] : null;
}

// Krótkie linki (vm.tiktok.com / vt.tiktok.com / tiktok.com/t/...) -> pełny URL filmiku
async function resolveShortLink(url) {
  if (!/\/\/(vm|vt)\.tiktok\.com|tiktok\.com\/t\//i.test(url)) return url;
  try {
    const res = await fetch(url, { redirect: "follow", headers: { "User-Agent": UA } });
    return res.url || url;
  } catch {
    return url;
  }
}

function cleanUrl(url) {
  try {
    const u = new URL(url);
    return `${u.origin}${u.pathname}`;
  } catch {
    return url;
  }
}

async function viaOembed(url) {
  const res = await fetch(
    `https://www.tiktok.com/oembed?url=${encodeURIComponent(url)}`,
    { headers: { "User-Agent": UA } }
  );
  if (!res.ok) throw new Error(`oEmbed HTTP ${res.status}`);
  const data = await res.json();
  return {
    description: data.title || "",
    author: data.author_name || data.author_unique_id || "",
    thumbnail: data.thumbnail_url || "",
  };
}

async function viaPage(url) {
  const res = await fetch(url, { headers: { "User-Agent": UA, "Accept-Language": "pl,en;q=0.8" } });
  if (!res.ok) throw new Error(`strona HTTP ${res.status}`);
  const html = await res.text();
  const m = html.match(
    /<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>([\s\S]*?)<\/script>/
  );
  if (m) {
    const json = JSON.parse(m[1]);
    const item =
      json?.__DEFAULT_SCOPE__?.["webapp.video-detail"]?.itemInfo?.itemStruct;
    if (item?.desc) {
      return {
        description: item.desc,
        author: item.author?.uniqueId || "",
        thumbnail: item.video?.cover || "",
      };
    }
  }
  const og = html.match(/<meta property="og:description" content="([^"]*)"/);
  if (og) return { description: decodeEntities(og[1]), author: "", thumbnail: "" };
  throw new Error("nie znaleziono opisu na stronie");
}

function decodeEntities(s) {
  return s
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

export async function fetchTikTok(rawUrl) {
  const url = cleanUrl(await resolveShortLink(rawUrl));
  const errors = [];
  let best = null;
  for (const fn of [viaOembed, viaPage]) {
    try {
      const r = await fn(url);
      if (!best || r.description.length > best.description.length) best = r;
      // oEmbed potrafi skracać długie opisy - jeśli wygląda na ucięty, próbujemy dalej
      if (r.description.length > 0 && !/…$|\.\.\.$/.test(r.description.trim())) break;
    } catch (e) {
      errors.push(e.message);
    }
  }
  if (!best || !best.description) {
    throw new Error(`Nie udało się pobrać opisu z TikToka (${errors.join("; ") || "pusty opis"})`);
  }
  return { url, ...best };
}
