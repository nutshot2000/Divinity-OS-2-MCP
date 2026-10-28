// Builds data/recipes.json from the game's own recipe table (ItemCombos.txt in the installed paks), for dos2_craft.
// The file is generated on each machine and not committed: it is Larian's game data.
//   node scripts/build-recipes.mjs [gameDir]      (DIVINE_EXE and DOS2_GAME_DIR are honoured)
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, statSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const gameDir = process.argv[2] ?? process.env.DOS2_GAME_DIR ?? "D:\\SteamLibrary\\steamapps\\common\\Divinity Original Sin 2";
const data = join(gameDir, "DefEd", "Data");
const divine = process.env.DIVINE_EXE ?? join(root, "tools", "lslib", "Packed", "Tools", "Divine.exe");
if (!existsSync(divine)) throw new Error(`Divine.exe not found at ${divine}: set DIVINE_EXE`);
if (!existsSync(data)) throw new Error(`Game data not found at ${data}: pass the game folder or set DOS2_GAME_DIR`);

// Base game first, then patches in release order: a later definition of the same recipe replaces the earlier one.
// Only the game's own modules (Shared, DivinityOrigins); optional gift-bag mods in the patches are left out.
const paks = ["Shared", "Origins", "Patch1", "Patch2", "Patch3", "Patch4", "Patch4-1", "Patch5", "Patch6", "Patch7",
  "Patch7_Hotfix", "Patch8", "Patch9", "Patch10"];
const work = join(tmpdir(), "dos2-bridge-recipes");
rmSync(work, { recursive: true, force: true });
const files = [];
for (const p of paks) {
  const pak = join(data, `${p}.pak`);
  if (!existsSync(pak)) continue;
  const out = join(work, p);
  mkdirSync(out, { recursive: true });
  execFileSync(divine, ["-g", "dos2de", "-a", "extract-package", "-s", pak, "-d", out, "--expression", "ItemCombos\\.txt$",
    "--use-regex"], { stdio: "ignore" });
  const walk = (d) => { for (const f of readdirSync(d)) { const q = join(d, f); if (statSync(q).isDirectory()) walk(q); else if (f === "ItemCombos.txt") files.push(q); } };
  walk(out);
}
const own = files.filter((f) => /[\\/]Public[\\/](Shared|DivinityOrigins_[^\\/]+)[\\/]/.test(f));

const combos = new Map();
for (const f of own) {
  for (const block of readFileSync(f, "utf8").split(/\r?\n(?=new )/)) {
    const head = block.match(/^new (\w+) "([^"]+)"/);
    if (!head) continue;
    const d = {};
    for (const m of block.matchAll(/data "([^"]+)" "([^"]*)"/g)) d[m[1]] = m[2];
    if (head[1] === "ItemCombination") {
      const ingredients = [];
      for (let i = 1; d[`Object ${i}`]; i++) ingredients.push({ type: d[`Type ${i}`], object: d[`Object ${i}`], transform: d[`Transform ${i}`] });
      combos.set(head[2], { id: head[2], category: d.RecipeCategory, station: d.CraftingStation || null, ingredients,
        ...(combos.get(head[2])?.results ? { results: combos.get(head[2]).results } : {}) });
    } else if (head[1] === "ItemCombinationResult") {
      const base = head[2].replace(/_\d+$/, "");
      const c = combos.get(base) ?? { id: base };
      const results = [];
      for (let i = 1; d[`Result ${i}`]; i++) results.push({ stats: d[`Result ${i}`], amount: Number(d[`ResultAmount ${i}`] ?? 1) });
      Object.assign(c, { results, name: d.PreviewTooltip || null, preview: d.PreviewStatsID || null,
        boost: Object.keys(d).some((k) => k.startsWith("Boost")) });
      combos.set(base, c);
    }
  }
}
const list = [...combos.values()].filter((c) => c.ingredients?.length && c.results?.length && !c.boost);
mkdirSync(join(root, "data"), { recursive: true });
writeFileSync(join(root, "data", "recipes.json"), JSON.stringify(list));
console.log(`data/recipes.json: ${list.length} recipes from ${own.length} files`);
