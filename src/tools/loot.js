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
