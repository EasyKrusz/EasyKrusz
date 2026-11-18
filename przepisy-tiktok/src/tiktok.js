// Pobieranie danych filmiku z TikToka: opis (caption), autor, miniaturka i - jeśli są -
// automatyczne napisy (transkrypcja mowy), z których da się ułożyć przepis, gdy opis jest pusty.
// Źródła: strona filmiku (dane osadzone w HTML) oraz oficjalny, publiczny endpoint oEmbed.

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
    author: data.author_unique_id || data.author_name || "",
    thumbnail: data.thumbnail_url || "",
  };
}

/** Lista dostępnych napisów filmiku: [{ url, lang, source }] */
export function subtitleCandidates(item) {
  const out = [];
  for (const s of item?.video?.subtitleInfos || []) {
    if (s?.Url && (!s.Format || /vtt/i.test(s.Format))) {
      out.push({ url: s.Url, lang: s.LanguageCodeName || "", source: s.Source || "" });
    }
  }
  for (const c of item?.video?.claInfo?.captionInfos || []) {
    if (c?.url) out.push({ url: c.url, lang: c.language || "", source: c.isAutoGen ? "ASR" : "" });
  }
  // Najpierw oryginalna mowa (ASR), potem polski, potem angielski, potem cokolwiek
  const score = (s) =>
    (/asr/i.test(s.source) ? 0 : 10) + (/^pol|^pl/i.test(s.lang) ? 0 : /^eng|^en/i.test(s.lang) ? 1 : 2);
  return out.sort((a, b) => score(a) - score(b));
}

/** Zamienia plik WebVTT na zwykły tekst (bez znaczników czasu i powtórzeń). */
export function vttToText(vtt) {
  const lines = [];
  for (const raw of String(vtt).split(/\r?\n/)) {
    const line = raw.replace(/<[^>]+>/g, "").trim();
    if (!line || line === "WEBVTT" || /^\d+$/.test(line) || line.includes("-->")) continue;
    if (/^(NOTE|STYLE|REGION|Kind:|Language:)/.test(line)) continue;
    if (lines[lines.length - 1] !== line) lines.push(line);
  }
  return lines.join(" ").replace(/\s+/g, " ").trim();
}

async function fetchTranscript(item) {
  for (const sub of subtitleCandidates(item)) {
    try {
      const res = await fetch(sub.url, { headers: { "User-Agent": UA, Referer: "https://www.tiktok.com/" } });
      if (!res.ok) continue;
      const text = vttToText(await res.text());
      if (text.length > 20) return text;
    } catch {
      // następne napisy
    }
  }
  return "";
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
    const item = json?.__DEFAULT_SCOPE__?.["webapp.video-detail"]?.itemInfo?.itemStruct;
    if (item) {
      return {
        description: item.desc || "",
        author: item.author?.uniqueId || "",
        thumbnail: item.video?.cover || item.video?.originCover || "",
        transcript: await fetchTranscript(item),
      };
    }
  }
  const og = html.match(/<meta property="og:description" content="([^"]*)"/);
  if (og) return { description: decodeEntities(og[1]), author: "", thumbnail: "", transcript: "" };
  throw new Error("nie znaleziono danych filmiku na stronie");
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
  const [page, oembed] = await Promise.all([
    viaPage(url).catch((e) => (errors.push(e.message), null)),
    viaOembed(url).catch((e) => (errors.push(e.message), null)),
  ]);
  if (!page && !oembed) {
    throw Object.assign(new Error(`Could not fetch the TikTok video (${errors.join("; ")})`), { code: "tiktok_failed" });
  }
  const pick = (a, b) => ((a || "").length >= (b || "").length ? a : b) || "";
  const result = {
    url,
    description: pick(page?.description, oembed?.description),
    author: page?.author || oembed?.author || "",
    thumbnail: oembed?.thumbnail || page?.thumbnail || "",
    transcript: page?.transcript || "",
  };
  if (!result.description && !result.transcript) {
    throw Object.assign(new Error("The video has no caption or subtitles to read a recipe from"), { code: "tiktok_empty" });
  }
  return result;
}

/** Pobiera miniaturkę (linki TikToka wygasają po kilku dniach, więc zapisujemy plik u siebie). */
export async function downloadImage(url) {
  if (!url) return null;
  try {
    const res = await fetch(url, { headers: { "User-Agent": UA, Referer: "https://www.tiktok.com/" } });
    const type = res.headers.get("content-type") || "";
    if (!res.ok || !type.startsWith("image/")) return null;
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length > 5_000_000) return null;
    const ext = type.includes("png") ? "png" : type.includes("webp") ? "webp" : "jpg";
    return { buf, ext };
  } catch {
    return null;
  }
}
