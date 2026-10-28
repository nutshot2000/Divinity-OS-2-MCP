// Tools: containers and loot.
import { tool, call, text, z, guid, inCombat } from "../core.js";
import { showInventory, holdInventory, caption } from "../director.js";
import { markUsed } from "../done.js";

const line = (i) => `  ${i.name}${i.amount > 1 ? ` x${i.amount}` : ""} [${i.guid}]` + (i.owned_by ? ` (owned by ${i.owned_by})` : "");

tool("dos2_loot", "List what is in a container the active character has opened and stands next to (open it with " +
  "dos2_use first), or on a dead body next to you (walk to it with dos2_move; bodies need no opening). " +
  "Pass take=\"all\" or take=[GUIDs] to move items into the character's inventory. Items owned by " +
  "someone else are listed but never taken: that would be stealing.",
  { container: guid, take: z.union([z.literal("all"), z.array(z.string())]).optional() },
  async (a) => {
    if (a.take == null) {
      const r = await call("loot_list", { container: a.container });
      return text(`${r.container}:\n${r.items.map(line).join("\n") || "  empty"}`);
    }
    if (await inCombat()) return text("Not looting: you are in combat. Take loot after the fight (call dos2_combat).");
    // Let a body that has only just died finish settling before its items are touched (taking them straight away crashed
    // the game once).
    await new Promise((res) => setTimeout(res, 1500));
    const r = await call("loot_take", { container: a.container, items: a.take === "all" ? undefined : a.take });
    if (a.take === "all") markUsed(a.container); // looted bodies and containers are done
    if (r.taken.length) await caption(`Took ${r.taken.slice(0, 3).map((i) => i.name + (i.amount > 1 ? ` x${i.amount}` : "")).join(", ")}${r.taken.length > 3 ? " and more" : ""}`);
    return text(`${r.container}: took\n${r.taken.map(line).join("\n") || "  nothing"}` +
      (r.skipped_owned.length ? `\nleft (owned):\n${r.skipped_owned.map(line).join("\n")}` : ""));
  });

tool("dos2_equip", "Equip a weapon, shield or armour from your inventory by GUID (from dos2_loot). Refuses if you do " +
  "not meet its attribute requirements, as the game would.",
  { item: guid },
  async (a) => {
    const hint = await showInventory();
    const r = await call("equip", a);
    await caption(`Equipping ${r.equipped}`);
    await holdInventory();
    return text(`Equipped ${r.equipped}.${hint}`);
  });

tool("dos2_identify", "Identify carried items with an Identifying Glass (it must be in the acting character's inventory; it is " +
  "not used up), as using the glass on them does in game. Pass items=[GUIDs], or nothing for every unidentified item the " +
  "party carries. Then dos2_inventory shows their real stats.",
  { items: z.array(guid).optional() },
  async (a) => {
    const hint = await showInventory();
    const r = await call("identify", a);
    if (r.identified.length) await caption(`Identified ${r.identified.slice(0, 3).map((i) => i.name).join(", ")}${r.identified.length > 3 ? " and more" : ""}`);
    await holdInventory();
    return text(`${r.glass}: identified\n${r.identified.map((i) => `  ${i.name} [${i.guid}] (${i.holder})`).join("\n") || "  nothing (all already identified)"}` + hint);
  });

tool("dos2_trade", "Buy from a trader you are standing next to (talk to them first). Without item: lists their stock " +
  "with prices and the party's gold. With item (GUID from that list) and optional amount: buys it. Prices are the " +
  "game's item values; the in-game trade window can differ a little (Barter, attitude). Do not open the game's trade " +
  "window with the bridge: it crashed the game.",
  { trader: guid, item: guid.optional(), amount: z.number().int().min(1).optional() },
  async (a) => {
    if (await inCombat()) return text("Not trading: you are in combat.");
    if (!a.item) {
      const r = await call("trade_list", { trader: a.trader });
      return text(`${r.trader} sells (party gold ${r.party_gold}):\n` +
        (r.stock.map((i) => `  ${i.name}${i.amount > 1 ? ` x${i.amount}` : ""} [${i.guid}] ${i.price_each} gold each`).join("\n") || "  nothing"));
    }
    const r = await call("trade_buy", a);
    await caption(`Bought ${r.bought}${r.amount > 1 ? ` x${r.amount}` : ""} for ${r.price} gold`);
    return text(`Bought ${r.bought}${r.amount > 1 ? ` x${r.amount}` : ""} from ${r.trader} for ${r.price} gold (${r.gold_left} left).`);
  });

// Crafting goes through the game's own crafting screen (UI 102), as clicks would: selectRecipe(n) makes the screen show
// recipe n (name, ingredients with counts, how many can be made), craftRecipe(n, amount) is what its Combine button sends.
// Recorded from a hand-made Knife On A Stick (2026-10-28). The screen must exist: the player opens it once with K.
const CRAFT_UI = 102;
const client = (cmd, args = {}) => call(cmd, args, 15000, "client");

async function readRecipe(id) {
  const mark = (await client("ping")).log;
  await client("ui_call", { ui: CRAFT_UI, fn: "selectRecipe", args: [id] });
  await new Promise((res) => setTimeout(res, 300));
  const es = (await client("ui_log", { ui: CRAFT_UI, since: mark, limit: 60 })).entries.filter((e) => e.when !== "After");
  const name = es.find((e) => e.fn === "setRecipeResult");
  if (!name) return null;
  const max = es.find((e) => e.fn === "setRecipeMaxCraftAmount");
  const ingredients = es.filter((e) => e.fn === "setIngredient" && e.args[2] !== "Select an ingredient")
    .map((e) => `${e.args[2]} (${e.args[3]})`);
  return { id, name: name.args[0], max: max ? Number(max.args[0]) : 0, ingredients };
}

tool("dos2_craft", "Craft through the game's crafting screen, as its buttons do. The screen must have been opened once " +
  "with K (it crafts for the character shown in it). Without recipe: lists the recipes the character knows, each with its " +
  "number, ingredients (how many you have) and how many you can make now. With recipe=<number> and optional amount: " +
  "crafts it, if the screen says it can be made.",
  { recipe: z.number().int().min(0).max(80).optional(), amount: z.number().int().min(1).max(20).optional() },
  async (a) => {
    if (await inCombat()) return text("Not crafting: you are in combat.");
    try { await client("ui_call", { ui: CRAFT_UI, fn: "selectRecipe", args: [0] }); }
    catch { return text("The crafting screen is not available: press K in the game once (it stays usable after closing)."); }
    if (a.recipe == null) {
      const out = [];
      for (let id = 0, misses = 0; id <= 80 && misses < 5; id++) {
        const r = await readRecipe(id);
        if (!r) { misses++; continue; }
        misses = 0;
        out.push(`  ${r.id}. ${r.name}: ${r.ingredients.join(" + ")}${r.max > 0 ? ` -> can make ${r.max}` : ""}`);
      }
      return text(`Known recipes (dos2_craft recipe=<number>):\n${out.join("\n") || "  none"}`);
    }
    const r = await readRecipe(a.recipe);
    if (!r) return text(`No recipe number ${a.recipe}: call dos2_craft without recipe for the list.`);
    const amount = a.amount ?? 1;
    if (r.max < amount) return text(`Cannot make ${amount} ${r.name}: the screen says ${r.max} (needs ${r.ingredients.join(" + ")}).`);
    await caption(`Crafting ${r.name}${amount > 1 ? ` x${amount}` : ""}`);
    await client("ui_call", { ui: CRAFT_UI, fn: "craftRecipe", args: [a.recipe, amount] });
    await new Promise((res) => setTimeout(res, 1500));
    return text(`Crafted ${r.name}${amount > 1 ? ` x${amount}` : ""} (it is in the crafter's inventory; dos2_identify then dos2_inventory shows it).`);
  });

tool("dos2_inventory", "Your character's inventory as the inventory screen shows it: name, amount, what is equipped, " +
  "and for gear its slot, rarity and (once identified) armour or damage, plus descriptions. Use dos2_use on an item's GUID to " +
  "drink, eat or read it, dos2_equip to wear it. equipment=true lists only weapons, armour and jewellery.",
  { equipment: z.boolean().optional().describe("Only gear (default: everything)") },
  async (a) => {
    const hint = await showInventory();
    const items = await call("inventory", { equipment: a.equipment });
    await holdInventory();
    const gear = (g) => !g ? "" : ` [${g.slot}${g.rarity && g.rarity !== "Common" ? `, ${g.rarity}` : ""}` +
      (g.armour ? `, armour ${g.armour}` : "") + (g.magic_armour ? `, magic armour ${g.magic_armour}` : "") +
      (g.damage ? `, ${g.damage} ${String(g.damage_type).toLowerCase()} damage, ${g.ap} AP, range ${g.range}m` : "") + "]";
    return text((items.map((i) => `  ${i.name}${i.amount > 1 ? ` x${i.amount}` : ""} [${i.guid}]${i.equipped ? " (equipped)" : ""}` +
      gear(i.gear) + (i.gear && !i.identified ? " (unidentified: stats hidden)" : "") +
      (i.description ? `\n      ${i.description.replace(/<[^>]*>/g, "")}` : "")).join("\n") || "  empty") + hint);
  });
