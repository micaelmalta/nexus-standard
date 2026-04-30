// Smoke tests for the JS NXS reader.
// Run: node test.js <fixtures_dir>

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { NxsReader } from "./nxs.js";

const fixtureDir = process.argv[2] || "./fixtures";
let passed = 0, failed = 0;

function test(name, fn) {
  try { fn(); console.log(`  ✓ ${name}`); passed++; }
  catch (e) { console.log(`  ✗ ${name}\n      ${e.message}`); failed++; }
}

function assertEq(actual, expected, msg = "") {
  if (actual !== expected) {
    throw new Error(`${msg} — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertClose(actual, expected, eps = 0.001, msg = "") {
  if (Math.abs(actual - expected) > eps) {
    throw new Error(`${msg} — expected ~${expected}, got ${actual}`);
  }
}

console.log("\nNXS JavaScript Reader — Tests\n");

const buf = readFileSync(join(fixtureDir, "records_1000.nxb"));
const json = JSON.parse(readFileSync(join(fixtureDir, "records_1000.json"), "utf8"));

test("opens without error", () => {
  new NxsReader(buf);
});

test("reads correct record count", () => {
  const r = new NxsReader(buf);
  assertEq(r.recordCount, 1000);
});

test("reads schema keys", () => {
  const r = new NxsReader(buf);
  assertEq(r.keys.includes("id"), true, "missing 'id'");
  assertEq(r.keys.includes("username"), true, "missing 'username'");
  assertEq(r.keys.includes("score"), true, "missing 'score'");
});

test("record(0) matches JSON[0].id", () => {
  const r = new NxsReader(buf);
  assertEq(r.record(0).getI64("id"), json[0].id);
});

test("record(42) matches JSON[42].username", () => {
  const r = new NxsReader(buf);
  assertEq(r.record(42).getStr("username"), json[42].username);
});

test("record(500) matches JSON[500].score", () => {
  const r = new NxsReader(buf);
  assertClose(r.record(500).getF64("score"), json[500].score);
});

test("record(999) last record active flag matches", () => {
  const r = new NxsReader(buf);
  assertEq(r.record(999).getBool("active"), json[999].active);
});

test("out-of-bounds record throws", () => {
  const r = new NxsReader(buf);
  let threw = false;
  try { r.record(10000); } catch (e) { threw = true; }
  assertEq(threw, true);
});

test("iteration visits every record", () => {
  const r = new NxsReader(buf);
  let count = 0;
  for (const _ of r.records()) count++;
  assertEq(count, 1000);
});

test("iteration sum matches JSON sum", () => {
  const r = new NxsReader(buf);
  let nxsSum = 0;
  for (const rec of r.records()) nxsSum += rec.getF64("score");
  let jsonSum = 0;
  for (const rec of json) jsonSum += rec.score;
  assertClose(nxsSum, jsonSum, 0.01, "score sums");
});

test("cursor scan matches JSON sum", () => {
  const r = new NxsReader(buf);
  const slot = r.slot("score");
  let nxsSum = 0;
  r.scan(cur => { nxsSum += cur.getF64BySlot(slot); });
  let jsonSum = 0;
  for (const rec of json) jsonSum += rec.score;
  assertClose(nxsSum, jsonSum, 0.01, "cursor scan sums");
});

test("cursor.seek(k) reads same value as record(k)", () => {
  const r = new NxsReader(buf);
  const cur = r.cursor();
  for (const k of [0, 42, 500, 999]) {
    cur.seek(k);
    assertEq(cur.getStr("username"), r.record(k).getStr("username"),
             `record ${k} mismatch`);
  }
});

// ── Security tests ────────────────────────────────────────────────────────────

test("bad magic throws ERR_BAD_MAGIC", () => {
  const bad = new Uint8Array(buf.length);
  bad.set(buf); bad[0] = 0x00;
  let threw = false;
  try { new NxsReader(bad); } catch (e) { threw = e.code === "ERR_BAD_MAGIC"; }
  if (!threw) throw new Error("expected ERR_BAD_MAGIC");
});

test("truncated file throws ERR_OUT_OF_BOUNDS", () => {
  const bad = buf.slice(0, 16);
  let threw = false;
  try { new NxsReader(bad); } catch (e) { threw = true; }
  if (!threw) throw new Error("expected error on truncated file");
});

test("corrupt DictHash throws ERR_DICT_MISMATCH", () => {
  const bad = new Uint8Array(buf.length);
  bad.set(buf); bad[8] ^= 0xFF;
  let threw = false;
  try { new NxsReader(bad); } catch (e) { threw = e.code === "ERR_DICT_MISMATCH"; }
  if (!threw) throw new Error("expected ERR_DICT_MISMATCH");
});

console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed > 0 ? 1 : 0);
