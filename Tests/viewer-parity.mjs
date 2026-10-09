// Proves the viewer's JavaScript geometry matches the Swift geometry exactly.
// usage: node Tests/viewer-parity.mjs viewer/index.html city.json scene.json [atUnixSeconds] [full|reduced|massing]
import fs from "node:fs";

const [, , htmlPath, cityPath, scenePath, atArg, reducedArg] = process.argv;
const html = fs.readFileSync(htmlPath, "utf8");
const start = html.indexOf("// <geometry>"), end = html.indexOf("// </geometry>");
if (start < 0 || end < 0) throw new Error("geometry markers not found in viewer");
const api = new Function(html.slice(start, end) + "\nreturn { buildScene };")();

const city = JSON.parse(fs.readFileSync(cityPath, "utf8"));
const expected = JSON.parse(fs.readFileSync(scenePath, "utf8"));
const at = atArg ? Number(atArg) : city.generatedAt;
const actual = api.buildScene(city, at, reducedArg || "full", null);

let compared = 0;
const fail = (where, what) => { console.error(`MISMATCH at ${where}: ${what}`); process.exit(1); };
const close = (a, b) => Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));

if (actual.buildingCount !== expected.buildingCount) fail("scene", `buildingCount ${actual.buildingCount} vs ${expected.buildingCount}`);
if (actual.items.length !== expected.items.length) fail("scene", `item count ${actual.items.length} vs ${expected.items.length}`);
actual.items.forEach((item, i) => {
  const want = expected.items[i];
  const where = `item ${i} (district ${want.district}, building ${want.building})`;
  if (item.district !== want.district || (item.building ? item.building.id : null) !== want.building) fail(where, "order differs");
  if (!close(item.look.structureAlpha, want.look[0]) || !close(item.look.windowAlpha, want.look[1])) fail(where, "look alpha differs");
  if (JSON.stringify(item.look.dash) !== JSON.stringify(want.look[2]) && !(item.look.dash && want.look[2] && item.look.dash.every((v, k) => close(v, want.look[2][k])))) fail(where, "dash differs");
  if (item.prims.length !== want.prims.length) fail(where, `primitive count ${item.prims.length} vs ${want.prims.length}`);
  item.prims.forEach((p, j) => {
    const q = want.prims[j];
    if (p.k !== q.k || (p.k !== "o" && p.ink !== q.ink) || (p.k === "l" && p.c !== q.c) || (p.k === "d" && !close(p.r, q.r))) fail(`${where} prim ${j}`, `${JSON.stringify(p).slice(0, 120)} vs ${JSON.stringify(q).slice(0, 120)}`);
    if (p.p.length !== q.p.length) fail(`${where} prim ${j}`, "point count");
    p.p.forEach((v, k) => { for (let a = 0; a < 3; a++) if (!close(v[a], q.p[k][a])) fail(`${where} prim ${j} point ${k}`, `${v} vs ${q.p[k]}`); compared++; });
  });
});
console.log(`viewer parity OK: ${actual.items.length} items, ${compared} points identical`);
