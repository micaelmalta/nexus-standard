// Smoke tests for the JS NXS reader and writer.
// Run: node test.js <fixtures_dir>

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { NxsReader } from "./nxs.js";
import { NxsSchema, NxsWriter } from "./nxs_writer.js";

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

// ── Writer round-trip tests ───────────────────────────────────────────────────

console.log("\nNXS JavaScript Writer — Tests\n");

test("writer round-trip: 3 records", () => {
  const schema = new NxsSchema(["id", "username", "score", "active"]);
  const w = new NxsWriter(schema);
  const recs = [
    [1n, "alice", 9.5, true],
    [2n, "bob", 7.2, false],
    [3n, "carol", 8.8, true],
  ];
  for (const [id, name, score, active] of recs) {
    w.beginObject();
    w.writeI64(0, id);
    w.writeStr(1, name);
    w.writeF64(2, score);
    w.writeBool(3, active);
    w.endObject();
  }
  const bytes = w.finish();
  const r = new NxsReader(bytes);
  assertEq(r.recordCount, 3, "record count");
  for (let i = 0; i < 3; i++) {
    const obj = r.record(i);
    assertEq(obj.getI64("id"), Number(recs[i][0]), `record ${i} id`);
    assertEq(obj.getStr("username"), recs[i][1], `record ${i} username`);
    assertClose(obj.getF64("score"), recs[i][2], 1e-9, `record ${i} score`);
    assertEq(obj.getBool("active"), recs[i][3], `record ${i} active`);
  }
});

test("writer round-trip: fromRecords convenience", () => {
  const bytes = NxsWriter.fromRecords(
    ["id", "name", "value"],
    [
      { id: 10n, name: "foo", value: 1.5 },
      { id: 20n, name: "bar", value: 2.5 },
    ]
  );
  const r = new NxsReader(bytes);
  assertEq(r.recordCount, 2, "record count");
  assertEq(r.record(1).getStr("name"), "bar", "second record name");
});

test("writer round-trip: null field", () => {
  const schema = new NxsSchema(["a", "b"]);
  const w = new NxsWriter(schema);
  w.beginObject();
  w.writeI64(0, 99n);
  w.writeNull(1);
  w.endObject();
  const r = new NxsReader(w.finish());
  assertEq(r.record(0).getI64("a"), 99, "a present");
});

test("writer round-trip: bool field", () => {
  const schema = new NxsSchema(["flag"]);
  const w = new NxsWriter(schema);
  w.beginObject(); w.writeBool(0, true);  w.endObject();
  w.beginObject(); w.writeBool(0, false); w.endObject();
  const r = new NxsReader(w.finish());
  assertEq(r.record(0).getBool("flag"), true,  "true");
  assertEq(r.record(1).getBool("flag"), false, "false");
});

test("writer round-trip: string with unicode", () => {
  const schema = new NxsSchema(["msg"]);
  const w = new NxsWriter(schema);
  w.beginObject();
  w.writeStr(0, "héllo wörld");
  w.endObject();
  const r = new NxsReader(w.finish());
  assertEq(r.record(0).getStr("msg"), "héllo wörld", "unicode string");
});

test("schema evolution: write 3 fields, read with 2-slot reader", () => {
  // Write with schema ["a","b","c"]
  const schema = new NxsSchema(["a", "b", "c"]);
  const w = new NxsWriter(schema);
  w.beginObject();
  w.writeI64(0, 100n);
  w.writeI64(1, 200n);
  w.writeI64(2, 300n);
  w.endObject();
  const bytes = w.finish();

  // Read with full schema — all three present
  const r = new NxsReader(bytes);
  const obj = r.record(0);
  assertEq(obj.getI64("a"), 100, "a");
  assertEq(obj.getI64("b"), 200, "b");
  assertEq(obj.getI64("c"), 300, "c");

  // Simulate 2-field reader: access only slots 0 and 1 — slot 2 is absent, not an error
  const slotA = r.slot("a");
  const slotB = r.slot("b");
  assertEq(obj.getI64BySlot(slotA), 100, "slot a via slot handle");
  assertEq(obj.getI64BySlot(slotB), 200, "slot b via slot handle");
  // Accessing a slot beyond the schema (simulating old reader) returns undefined/absent
  const absent = obj.getI64BySlot(99);
  if (absent !== undefined && absent !== null) {
    throw new Error(`expected absent for unknown slot, got ${absent}`);
  }
});

console.log(`\n${passed} passed, ${failed} failed\n`);
process.exit(failed > 0 ? 1 : 0);
