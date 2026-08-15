#!/usr/bin/env node
/**
 * ciqual-to-nightscout.mjs
 *
 * Importe la table Ciqual (ANSES) dans la base `food` de Nightscout,
 * lue ensuite par l'onglet Food d'AAPS.
 *
 * Usage :
 *   NS_BASE_URL="https://mon-ns.example.com" \
 *   NS_API_SECRET="monSecret" \
 *   node ciqual-to-nightscout.mjs --csv ciqual.csv --filter aliments.txt --dry-run
 *
 * Flags :
 *   --csv <path>      export Ciqual (CSV, séparateur ;)
 *   --filter <path>   liste de codes Ciqual ou fragments de nom, un par ligne (fortement recommandé)
 *   --dry-run         n'écrit rien, affiche ce qui serait envoyé
 *   --limit <n>       plafond de sécurité (défaut 500)
 *   --token <t>       auth par token NS plutôt que par API_SECRET
 */

import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

// ---------------------------------------------------------------------------
// Config : noms de colonnes Ciqual.
// VÉRIFIE l'en-tête de ton export — les libellés changent d'une version à l'autre.
// ---------------------------------------------------------------------------
const COLS = {
  code: "alim_code",
  name: "alim_nom_fr",
  group: "alim_grp_nom_fr",
  subgroup: "alim_ssgrp_nom_fr",
  carbs: "Glucides (g/100 g)",
  protein: "Protéines, N x facteur de Jones (g/100 g)",
  fat: "Lipides (g/100 g)",
  energy: "Energie, Règlement UE N° 1169/2011 (kJ/100 g)",
};

const PORTION = 100; // toutes les valeurs Ciqual sont pour 100 g
const UNIT = "g";

// ---------------------------------------------------------------------------
// Args
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const flag = (n) => args.includes(`--${n}`);
const val = (n, d) => {
  const i = args.indexOf(`--${n}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : d;
};

const CSV_PATH = val("csv");
const FILTER_PATH = val("filter");
const DRY_RUN = flag("dry-run");
const LIMIT = parseInt(val("limit", "500"), 10);
const TOKEN = val("token");

const NS_BASE_URL = (process.env.NS_BASE_URL || "").replace(/\/$/, "");
const NS_API_SECRET = process.env.NS_API_SECRET;

if (!CSV_PATH) fail("--csv est requis");
if (!DRY_RUN && !NS_BASE_URL) fail("NS_BASE_URL est requis (ou utilise --dry-run)");
if (!DRY_RUN && !NS_API_SECRET && !TOKEN) fail("NS_API_SECRET ou --token est requis");

function fail(msg) {
  console.error(`✗ ${msg}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Parsing CSV (séparateur ;, guillemets possibles)
// ---------------------------------------------------------------------------
function parseCsv(text) {
  const rows = [];
  let row = [], field = "", inQuotes = false;
  const src = text.replace(/^\uFEFF/, ""); // BOM

  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (inQuotes) {
      if (c === '"' && src[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') inQuotes = false;
      else field += c;
    } else if (c === '"') inQuotes = true;
    else if (c === ";") { row.push(field); field = ""; }
    else if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; }
    else if (c !== "\r") field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }

  const header = rows.shift().map((h) => h.trim());
  return rows
    .filter((r) => r.length === header.length)
    .map((r) => Object.fromEntries(header.map((h, i) => [h, r[i].trim()])));
}

/**
 * Ciqual utilise la virgule décimale et des marqueurs non numériques :
 * "traces", "-", "NC" (non communiqué), "< 0,5".
 * traces / < X  -> 0 ; NC / "-" -> null (donnée absente, on rejette la ligne si c'est les glucides)
 */
function parseCiqualNumber(raw) {
  if (raw == null) return null;
  const v = raw.trim().toLowerCase();
  if (v === "" || v === "-" || v === "nc") return null;
  if (v === "traces") return 0;
  const m = v.replace("<", "").replace(",", ".").trim();
  const n = parseFloat(m);
  return Number.isFinite(n) ? n : null;
}

// ---------------------------------------------------------------------------
// Auth Nightscout
// ---------------------------------------------------------------------------
function authHeaders() {
  if (TOKEN) return {};
  const hash = createHash("sha1").update(NS_API_SECRET).digest("hex");
  return { "API-SECRET": hash };
}

function endpoint(path) {
  const q = TOKEN ? `?token=${encodeURIComponent(TOKEN)}` : "";
  return `${NS_BASE_URL}/api/v1/${path}${q}`;
}

async function fetchExistingNames() {
  const res = await fetch(endpoint("food.json"), { headers: authHeaders() });
  if (!res.ok) fail(`GET /food a échoué : ${res.status} ${await res.text()}`);
  const list = await res.json();
  return new Set(list.map((f) => (f.name || "").toLowerCase()));
}

async function postFood(entry) {
  const form = new URLSearchParams({
    type: "food",
    category: entry.category,
    subcategory: entry.subcategory,
    name: entry.name,
    portion: String(entry.portion),
    unit: entry.unit,
    carbs: entry.carbs.toFixed(1),
    protein: (entry.protein ?? 0).toFixed(1),
    fat: (entry.fat ?? 0).toFixed(1),
    energy: (entry.energy ?? 0).toFixed(0),
  });

  const res = await fetch(endpoint("food/"), {
    method: "POST",
    headers: { ...authHeaders(), "Content-Type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const rows = parseCsv(readFileSync(CSV_PATH, "utf8"));
console.log(`→ ${rows.length} lignes lues depuis ${CSV_PATH}`);

const missing = Object.entries(COLS).filter(([, c]) => !(c in (rows[0] || {})));
if (missing.length) {
  console.error("✗ Colonnes introuvables :", missing.map(([k, c]) => `${k} → "${c}"`).join(", "));
  console.error("  En-tête réel :", Object.keys(rows[0] || {}).join(" | "));
  process.exit(1);
}

let filter = null;
if (FILTER_PATH) {
  filter = readFileSync(FILTER_PATH, "utf8")
    .split("\n").map((l) => l.trim().toLowerCase())
    .filter((l) => l && !l.startsWith("#"));
  console.log(`→ ${filter.length} critères de filtre chargés`);
}

const entries = [];
let rejected = 0;

for (const row of rows) {
  const name = row[COLS.name];
  const code = row[COLS.code];
  if (!name) continue;

  if (filter) {
    const hay = `${code} ${name}`.toLowerCase();
    if (!filter.some((f) => hay.includes(f))) continue;
  }

  const carbs = parseCiqualNumber(row[COLS.carbs]);
  if (carbs === null) { rejected++; continue; } // pas de glucides = inutilisable

  entries.push({
    code,
    name: name.slice(0, 60),
    category: row[COLS.group] || "Ciqual",
    subcategory: row[COLS.subgroup] || "",
    portion: PORTION,
    unit: UNIT,
    carbs,
    protein: parseCiqualNumber(row[COLS.protein]),
    fat: parseCiqualNumber(row[COLS.fat]),
    energy: parseCiqualNumber(row[COLS.energy]),
  });
}

console.log(`→ ${entries.length} aliments retenus (${rejected} rejetés : glucides non renseignés)`);

if (entries.length > LIMIT) {
  fail(
    `${entries.length} entrées > limite de ${LIMIT}.\n` +
    `  Un onglet Food d'AAPS avec des milliers d'entrées est inutilisable.\n` +
    `  Affine --filter, ou relève --limit en connaissance de cause.`
  );
}

if (DRY_RUN) {
  console.log("\n--- DRY RUN ---");
  for (const e of entries.slice(0, 20)) {
    console.log(
      `${e.name.padEnd(45)} ${String(e.carbs).padStart(5)}g gluc / 100g  ` +
      `[${e.category}${e.subcategory ? " › " + e.subcategory : ""}]`
    );
  }
  if (entries.length > 20) console.log(`... et ${entries.length - 20} autres`);
  process.exit(0);
}

const existing = await fetchExistingNames();
console.log(`→ ${existing.size} aliments déjà présents dans Nightscout`);

let ok = 0, skipped = 0, errors = 0;
for (const e of entries) {
  if (existing.has(e.name.toLowerCase())) { skipped++; continue; }
  try {
    await postFood(e);
    ok++;
    process.stdout.write(`\r  inséré ${ok}/${entries.length}`);
  } catch (err) {
    errors++;
    console.error(`\n  ✗ ${e.name} : ${err.message}`);
  }
  await sleep(200); // ménage l'instance NS
}

console.log(`\n\n✓ ${ok} insérés, ${skipped} déjà présents, ${errors} erreurs`);
console.log("→ Vérifie dans Nightscout : menu ☰ → Food Editor");
console.log("→ Puis dans AAPS : Config Builder → active le plugin Food, onglet Food");
