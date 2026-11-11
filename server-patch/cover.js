// أغلفة الألعاب: يطابق CRC أو اسم الملف مع قاعدة No-Intro ثم يجلب الغلاف من libretro-thumbnails
import INDEX from "./snes_index.js";
import PS1_INDEX from "./ps1_index.js";
import PS2_INDEX from "./ps2_index.js";

// system=snes (الافتراضي): المفتاح CRC من No-Intro.  system=ps1 / ps2: المفتاح رقم القرص (SLUS-00665) من Redump
const SYSTEMS = {
  snes: { index: INDEX, thumbs: "https://raw.githubusercontent.com/libretro-thumbnails/Nintendo_-_Super_Nintendo_Entertainment_System/master/" },
  ps1: { index: PS1_INDEX, thumbs: "https://raw.githubusercontent.com/libretro-thumbnails/Sony_-_PlayStation/master/" },
  ps2: { index: PS2_INDEX, thumbs: "https://raw.githubusercontent.com/libretro-thumbnails/Sony_-_PlayStation_2/master/" },
};
const ROMAN = { 1: "i", 2: "ii", 3: "iii", 4: "iv", 5: "v", 6: "vi", 7: "vii", 8: "viii", 9: "ix", 10: "x" };
const JUNK = new Set(["arabic", "arab", "ar", "english", "eng", "en", "translated", "translation", "translate",
  "patch", "patched", "hack", "hacked", "fix", "fixed", "sfc", "smc", "fig", "swc", "rom", "snes", "super",
  "nintendo", "final", "full", "the", "a", "of", "and", "rev", "beta", "jp", "jap", "japan", "usa", "us", "eu",
  "europe", "fr", "de", "es", "it", "by", "ver", "version", "new", "edition", "cruyfford", "عربي", "معرب", "مترجم",
  "cue", "chd", "pbp", "m3u", "iso", "img", "ccd", "bin", "ps1", "psx", "playstation", "sony", "disc", "track",
  "ps2", "cso", "zso", "gz", "ciso", "dvd"]);
const BAD = /\((Beta|Proto|Pirate|Sample|Demo|Hack|Unl|Aftermarket)[^)]*\)/i;

const loaded = {};
function load(system) {
  if (loaded[system]) return loaded[system];
  const byCrc = new Map();
  const games = [];
  const seen = new Set();
  for (const line of SYSTEMS[system].index.split("\n")) {
    const tab = line.indexOf("\t");
    const crc = line.slice(0, tab), name = line.slice(tab + 1);
    if (crc && !byCrc.has(crc)) byCrc.set(crc, name);
    if (seen.has(name)) continue;
    seen.add(name);
    games.push({ name, toks: new Set(tokens(name.replace(/\(.*$/, ""), false)), bad: BAD.test(name),
                 jp: /\(Japan\)/.test(name), us: /\(USA/.test(name) });
  }
  games.byCrc = byCrc;
  loaded[system] = games;
  return games;
}

function tokens(s, dropJunk = true) {
  const t = s.toLowerCase()
    .replace(/\[[^\]]*\]|\([^)]*\)/g, " ")
    .replace(/([a-z])(\d)/g, "$1 $2").replace(/(\d)([a-z])/g, "$1 $2")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .split(" ").filter(Boolean)
    .map((w) => ROMAN[w] || w);
  return dropJunk ? t.filter((w) => !JUNK.has(w) && !/^v\d/.test(w)) : t;
}

function candidates(system, crc, file) {
  const g = load(system);
  const out = [];
  if (crc && g.byCrc.has(crc)) out.push(g.byCrc.get(crc));
  const q = [...new Set(tokens(file))];
  if (!q.length) return out;
  const scored = [];
  for (const x of g) {
    let hit = 0;
    for (const w of q) if (x.toks.has(w)) hit++;
    if (!hit) continue;
    const miss = x.toks.size - hit;
    const s = hit / q.length - miss * 0.03 - (x.bad ? 0.5 : 0) + (x.us ? 0.02 : 0) + (x.jp ? 0.01 : 0);
    scored.push([s, hit, x.name]);
  }
  scored.sort((a, b) => b[0] - a[0]);
  for (const [s, hit, name] of scored.slice(0, 4)) {
    if (s >= 0.6 && hit >= Math.min(2, q.length) && !out.includes(name)) out.push(name);
  }
  return out;
}

const fileName = (n) => n.replace(/[&*\/:`<>?\\|"]/g, "_");

export async function handleCover(request, url) {
  const system = SYSTEMS[url.searchParams.get("system")] ? url.searchParams.get("system") : "snes";
  const name = (url.searchParams.get("name") || "").slice(0, 200);
  let key;
  if (system === "ps1" || system === "ps2") {
    const m = (url.searchParams.get("serial") || "").toUpperCase().match(/([A-Z]{4})[-_ ]?(\d{3})\.?(\d{2})/);
    key = m ? `${m[1]}-${m[2]}${m[3]}` : "";
  } else {
    const crc = (url.searchParams.get("crc") || "").toUpperCase().replace(/[^0-9A-F]/g, "").padStart(8, "0");
    key = crc === "00000000" ? "" : crc;
  }
  const list = candidates(system, key, name);
  if (url.searchParams.get("debug")) return Response.json({ system, key, name, candidates: list });
  for (const game of list.slice(0, 3)) {
    for (const kind of ["Named_Boxarts", "Named_Titles"]) {
      const r = await fetch(SYSTEMS[system].thumbs + kind + "/" + encodeURIComponent(fileName(game)) + ".png",
                            { cf: { cacheEverything: true, cacheTtl: 2592000 } });
      if (r.ok) {
        return new Response(r.body, { headers: { "content-type": "image/png", "x-game": encodeURIComponent(game),
                                                 "cache-control": "public, max-age=2592000" } });
      }
    }
  }
  return new Response("no cover", { status: 404 });
}
