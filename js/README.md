# NXS — JavaScript

Zero-copy `.nxb` reader for Node.js and the browser. Single ES module file, no dependencies, no build step.

## Requirements

Node.js 18+ or any modern browser. No npm install required.

## Read a file

```js
import { NxsReader } from "./nxs.js";

// Node.js
import { readFileSync } from "node:fs";
const reader = new NxsReader(readFileSync("data.nxb"));

// Browser
const reader = new NxsReader(new Uint8Array(await fetch("data.nxb").then(r => r.arrayBuffer())));

console.log(reader.recordCount);       // instant — read from tail-index, no parse pass
const obj = reader.record(42);         // O(1) seek
console.log(obj.getStr("username"));
console.log(obj.getF64("score"));
console.log(obj.getBool("active"));
```

## Columnar scan

```js
const sum = reader.sumF64("score");
const min = reader.minF64("score");
const max = reader.maxF64("score");
```

## Slot handles (hot path)

Resolve a key name to a slot index once, reuse it across every record:

```js
const slot = reader.slot("score");
for (let i = 0; i < reader.recordCount; i++) {
    const v = reader.record(i).getF64BySlot(slot);
}
```

## Optional: WASM-accelerated reducers

```js
import { loadWasm } from "./wasm.js";

const wasm = await loadWasm("./wasm/nxs_reducers.wasm");
reader.useWasm(wasm);
const sum = reader.sumF64("score");   // ~1.3× faster at 1M records
```

Build the WASM module from source:

```bash
bash wasm/build.sh
```

## Web Workers / SharedArrayBuffer

```js
// main thread — serve with python3 server.py (sets required COOP/COEP headers)
const wasm = await loadWasm("./wasm/nxs_reducers.wasm");
const buf = wasm.allocBuffer(nxbBytes.length);
buf.set(nxbBytes);   // copy once into WASM memory

for (let i = 0; i < 4; i++) {
    new Worker("./nxs_worker.js", { type: "module" })
        .postMessage({ buffer: wasm.memory.buffer, size: buf.length });
}
// Workers share the buffer — 0 bytes copied between threads
```

## Browser demos

```bash
python3 server.py   # required for SharedArrayBuffer (COOP/COEP headers)
```

| Demo | URL | Description |
| :--- | :--- | :--- |
| `bench.html` | `http://localhost:8000/bench.html` | NXS vs JSON vs CSV, up to 14M records |
| `ticker.html` | `http://localhost:8000/ticker.html` | 60 FPS in-place byte patch vs full JSON re-parse |
| `workers.html` | `http://localhost:8000/workers.html` | 4 workers, SharedArrayBuffer, 0 bytes copied |
| `explorer.html` | `http://localhost:8000/explorer.html` | 10M-line log explorer with virtual scroll |

## Write a file

```js
import { NxsSchema, NxsWriter } from "./nxs_writer.js";

const schema = new NxsSchema(["id", "username", "score", "active"]);
const w = new NxsWriter(schema);

w.beginObject();
w.writeI64(0, 42n);
w.writeStr(1, "alice");
w.writeF64(2, 9.5);
w.writeBool(3, true);
w.endObject();

const bytes = w.finish();   // Uint8Array

// Convenience: write from an array of objects
const bytes2 = NxsWriter.fromRecords(
    ["id", "username", "score"],
    [{ id: 1n, username: "bob", score: 8.2 }]
);
```

## Tests

```bash
node test.js
```

## Files

| File | Purpose |
| :--- | :--- |
| `nxs.js` | Pure-JS reader (Node + browser) |
| `nxs_writer.js` | Pure-JS writer (Node + browser) |
| `wasm.js` | WASM loader and zero-copy Node helper |
| `nxs_worker.js` | Web Worker that runs reducers on a shared buffer |
| `json_worker.js` | JSON baseline worker for benchmark comparison |
| `wasm/nxs_reducers.c` | C source for the WASM reducer module |
| `wasm/build.sh` | Compiles `nxs_reducers.c` → `nxs_reducers.wasm` via Emscripten |

---

For the format specification see [`SPEC.md`](../SPEC.md). For cross-language examples see [`GETTING_STARTED.md`](../GETTING_STARTED.md).
