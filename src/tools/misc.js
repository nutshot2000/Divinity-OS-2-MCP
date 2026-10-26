// Tools: help, connection check, raw Lua, screenshot.
import { tool, modTool, call, text, json, z, INSTRUCTIONS } from "../core.js";
import { heartbeat, dataDir } from "../bridge.js";
import { captureScreenshot } from "../screenshot.js";

tool("dos2_help", "The playbook: how to explore and play through this bridge.", {}, () => text(INSTRUCTIONS));

tool("dos2_ping", "Check the connection: where the bridge looks for the game's Osiris Data folder, the mod's last " +
  "heartbeat, and a round trip to the mod.",
  {},
  async () => {
    const beat = heartbeat();
    let round = null;
    try { round = await call("ping", {}, 5000); }
    catch (e) { round = { error: String(e.message || e) }; }
    return text(json({ data_dir: dataDir(), heartbeat: beat, ping: round }));
  });

// Raw Lua can read anything in the game, so it is for debugging the bridge only and off during play.
if (process.env.DOS2_DEV === "1") {
  tool("dos2_lua", "Debug only (DOS2_DEV=1): run Lua in the game's server context; the chunk's return value comes back " +
    "as JSON. Never use it to learn things a player could not see.",
    { code: z.string().min(1) },
    (a) => modTool("lua", a));
}

tool("dos2_screenshot", "Capture the game window as an image. Costly: use dos2_look and dos2_grid first and take a " +
  "picture only to check something they cannot show.",
  { max_width: z.number().int().min(640).max(2560).optional().describe("Default 1280") },
  async (a) => {
    const { metadata, image } = await captureScreenshot(a.max_width ?? 1280);
    return { content: [{ type: "text", text: json(metadata) }, image] };
  });

tool("dos2_minimap", "What the minimap in the corner shows: the people marked on it (also behind walls, as the " +
  "minimap draws them) with name, GUID, position and distance. Use it to find who is around before dos2_look, " +
  "which only lists what is in line of sight.",
  {}, async () => {
    const icons = await call("minimap", {}, 5000, "client");
    const me = icons.find((i) => i.kind === "you");
    const r1 = (v) => Math.round(v * 10) / 10;
    const lines = icons.filter((i) => i.kind !== "you" && i.name).map((i) => `  ${i.kind}: ${i.name} [${i.guid}] at ` +
      `${r1(i.x)},${r1(i.z)}` + (me ? `, ${r1(Math.hypot(i.x - me.x, i.z - me.z))}m away` : ""));
    // Markers with no character behind them (stairs and other exits) only have minimap coordinates. The minimap turns
    // with the camera and changes scale, but it is always a rotation plus a scale (y axis flipped), which one person
    // with a known position pins down: K = their minimap offset / conj(their offset on the ground).
    const anchor = me && icons.find((i) => i.kind !== "you" && i.name && i.mx != null);
    const marks = icons.filter((i) => i.kind !== "you" && !i.name).map((i) => {
      if (!anchor) return "  marker without a name (position unknown: no one else on the minimap to measure by)";
      const vx = anchor.x - me.x, vz = anchor.z - me.z; // the anchor's offset on the ground
      const d2 = vx * vx + vz * vz;
      if (d2 < 1) return "  marker without a name (position unknown: the person marked is standing on you)";
      const kr = (anchor.mx * vx - anchor.my * vz) / d2, ki = (anchor.my * vx + anchor.mx * vz) / d2;
      const k2 = kr * kr + ki * ki;
      const ur = (i.mx * kr + i.my * ki) / k2, ui = (i.my * kr - i.mx * ki) / k2;
      return `  marker (exit or point of interest, no name) at about ${r1(me.x + ur)},${r1(me.z - ui)}`;
    });
    return text((lines.join("\n") || "  nobody marked") + (marks.length ? "\n" + marks.join("\n") : "") +
      (me ? `\nyou: ${r1(me.x)},${r1(me.z)}` : ""));
  });

tool("dos2_camera", "Move the game camera for the watcher: point it at a visible character or item (target) or at " +
  "explored ground (x,z), zoom (metres, the game allows up to about 19), set rotation (degrees) or turn (degrees, " +
  "relative). reset=true points it back at your character. It follows your character again once they move.",
  {
    target: z.string().optional(), x: z.number().optional(), z: z.number().optional(),
    zoom: z.number().min(3).max(30).optional(), rotation: z.number().optional(), turn: z.number().optional(),
    reset: z.boolean().optional(),
  },
  async (a) => {
    const point = a.target != null || (a.x != null && a.z != null) || a.reset
      ? await call("camera_point", a.reset ? {} : { target: a.target, x: a.x, z: a.z }) : {};
    const r = await call("camera", { ...point, zoom: a.zoom, rotation: a.rotation, turn: a.turn }, 15000, "client");
    return text(`Camera looking at ${r.look_at.map((v) => Math.round(v * 10) / 10).join(",")}, zoom ${r.zoom}m, rotation ${Math.round(r.rotation)}.`);
  });
