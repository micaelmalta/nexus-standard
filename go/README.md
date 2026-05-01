# NXS — Go

Zero-copy `.nxb` reader for Go 1.21+. No external dependencies.

## Install

```bash
go get github.com/micaelmalta/nxs/go
```

## Requirements

Go 1.21+.

## Read a file

```go
import (
    "github.com/micaelmalta/nxs/go"
    "os"
)

data, _ := os.ReadFile("data.nxb")
r, err := nxs.NewReader(data)
if err != nil { panic(err) }

fmt.Println(r.RecordCount())       // instant — read from tail-index, no parse pass

obj := r.Record(42)                // O(1) seek
username, _ := obj.GetStr("username")
score, _    := obj.GetF64("score")
```

## Slot handles (hot path)

Resolve a key name to a slot index once, reuse it across every record:

```go
slot := r.Slot("score")
for i := 0; i < r.RecordCount(); i++ {
    v, _ := r.Record(i).GetF64BySlot(slot)
    _ = v
}
```

## Reducers

```go
// Safe — handles any bitmask layout
sum := r.SumF64("score")

// Fast — assumes uniform schema; bitmask computed once from record 0
sum = r.SumF64Fast("score")

// Parallel — fans out across GOMAXPROCS goroutines
sum = r.SumF64FastPar("score", 0)   // 0 = use GOMAXPROCS

min, _ := r.MinF64Fast("score")
max, _ := r.MaxF64Fast("score")
ages   := r.SumI64Fast("age")
```

At 1M records, `SumF64Fast` runs in ~10.9 ms vs ~1.05 s for `json.Unmarshal` (~105× faster).

## Write a file

```go
import "github.com/micaelmalta/nxs/go"

schema := nxs.NewSchema([]string{"id", "username", "score", "active"})
w := nxs.NewWriter(schema)

w.BeginObject()
w.WriteI64(0, 42)
w.WriteStr(1, "alice")
w.WriteF64(2, 9.5)
w.WriteBool(3, true)
w.EndObject()

bytes := w.Finish()   // []byte

// Convenience: write from a slice of maps
bytes2 := nxs.WriterFromRecords(
    []string{"id", "username", "score"},
    []map[string]any{{"id": int64(1), "username": "bob", "score": 8.2}},
)
```

## Tests

```bash
go test ./...
```

## Benchmarks

```bash
go build -o bench ./cmd/bench
./bench ../js/fixtures
```

Generate fixtures first if needed:

```bash
cargo run --release --bin gen_fixtures -- ../js/fixtures 1000000
```

## Files

| File | Purpose |
| :--- | :--- |
| `nxs.go` | Reader, schema parsing, tail-index, field accessors |
| `fast.go` | Uniform-schema fast path and parallel reducers |
| `writer.go` | `NxsWriter` / `NxsSchema` — direct binary writer |
| `nxs_test.go` | Test suite |
| `cmd/bench/main.go` | Benchmark binary |

---

For the format specification see [`SPEC.md`](../SPEC.md). For cross-language examples see [`GETTING_STARTED.md`](../GETTING_STARTED.md).
