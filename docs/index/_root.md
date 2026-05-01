# LOI Index

Generated: 2026-05-01
Source paths: rust/src/, rust/src/convert/, rust/src/bin/, rust/tests/convert/, rust/fuzz/, js/, py/, go/, c/, ruby/, php/, kotlin/, csharp/, swift/, conformance/, .github/workflows/, SPEC.md, RFC.md

## TASK → LOAD

| Task | Load |
|------|------|
| Understand the NXS binary format (preamble, schema, tail-index, bitmask) | spec/format.md |
| Implement a new language reader | spec/format.md → implementations/_root.md |
| Work on the Rust compiler (.nxs → .nxb text pipeline) | implementations/rust.md |
| Work on the Rust binary writer (hot path, gen_fixtures) | implementations/rust.md |
| Work on the converter pipeline (nxs-import, nxs-export, nxs-inspect) | implementations/rust_convert.md |
| Import JSON, CSV, or XML into .nxb | implementations/rust_convert.md |
| Export .nxb to JSON or CSV | implementations/rust_convert.md |
| Work on schema inference (type lattice, conflict policies) | implementations/rust_convert.md |
| Work on the JS/Browser/Node reader or WASM reducers | implementations/javascript.md |
| Work on the Python reader or C extension | implementations/python.md |
| Work on Go reader or parallel fast-path reducers | implementations/go.md |
| Work on the C99 reader (nxs.h / nxs.c) | implementations/c.md |
| Work on the Ruby reader or C extension | implementations/ruby.md |
| Work on the PHP reader or C extension | implementations/php.md |
| Work on the Kotlin/JVM reader | implementations/kotlin.md |
| Work on the C# / .NET reader | implementations/csharp.md |
| Work on the Swift reader | implementations/swift.md |
| Debug or add a GitHub Actions CI workflow | ci/workflows.md |
| Understand fixture generation for tests | ci/workflows.md |
| Run or extend the cross-language conformance suite | conformance/runners.md |
| Generate new conformance test vectors | conformance/runners.md |
| Compare bulk reducer implementations across languages | implementations/_root.md |

## PATTERN → LOAD

| Pattern | Load |
|---------|------|
| Zero-copy binary reader (tail-index → bitmask → offset-table) | spec/format.md, implementations/rust.md, implementations/go.md |
| LEB128 bitmask presence encoding | spec/format.md, implementations/rust.md, implementations/c.md |
| Slot-based hot-path field access | implementations/javascript.md, implementations/go.md, implementations/rust.md |
| Bulk columnar reducer (sum/min/max f64, sum i64) | implementations/go.md, implementations/c.md, implementations/javascript.md |
| C extension for interpreter languages | implementations/python.md, implementations/ruby.md, implementations/php.md |
| WASM reducer (no libc, freestanding C) | implementations/javascript.md |
| Uniform-schema fast path (skip per-record bitmask walk) | implementations/go.md, implementations/rust.md |
| Reusable workflow + artifact-passing in CI | ci/workflows.md |
| Benchmark harness with JSON/CSV baseline comparison | implementations/rust.md, implementations/go.md, implementations/javascript.md |
| Two-pass import / schema inference | implementations/rust_convert.md |
| Entity-expansion guard / XML depth limit | implementations/rust_convert.md |
| Conformance test vector generation + multi-language runners | conformance/runners.md |

## GOVERNANCE WATCHLIST

No rooms currently flagged. All implementations have `architectural_health: normal` and `security_tier: normal`.

## Buildings

| Subdomain | Description | Rooms |
|-----------|-------------|-------|
| spec/ | Binary format specification and RFC | format.md |
| implementations/ | All 11 language readers/writers, converter pipeline, tests, benchmarks | rust.md, rust_convert.md, javascript.md, python.md, go.md, c.md, ruby.md, php.md, kotlin.md, csharp.md, swift.md |
| conformance/ | Cross-language conformance test vectors and runners | runners.md |
| ci/ | GitHub Actions workflows for all languages and publish pipelines | workflows.md |
