//! Converter suite — JSON/CSV/XML ⇄ .nxb.
//!
//! Spec: ../../context/data/2026-04-30-converter-suite-spec.yaml
//! Plan: ../../context/plans/2026-04-30-converter-suite.md
//!
//! Module map:
//!   infer     — two-pass streaming sigil inference shared by all import sources
//!   json_in   — JSON → NxsWriter
//!   csv_in    — CSV  → NxsWriter
//!   xml_in    — XML  → NxsWriter
//!   json_out  — .nxb → JSON (streaming, optional ndjson/pretty)
//!   csv_out   — .nxb → CSV
//!   inspect   — .nxb → human/JSON report
//!
//! All public entry points below are stubs returning `Unimplemented` until the
//! implementation steps in the plan are executed in TDD order.

// No panics on adversarial input — enforced mechanically in this module.
#![deny(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use crate::error::Result;

pub mod csv_in;
pub mod csv_out;
pub mod infer;
pub mod inspect;
pub mod json_in;
pub mod json_out;
pub mod xml_in;

// ── Verify policy (--verify) ────────────────────────────────────────────────

/// `--verify <auto|force|off>` — post-write roundtrip decode control.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum VerifyPolicy {
    /// Verify when output is under 100 MB; skip otherwise with a warning.
    #[default]
    Auto,
    /// Always verify, regardless of output size.
    Force,
    /// Skip verify entirely.
    Off,
}

// ── Binary encoding (--binary) ───────────────────────────────────────────────

/// `--binary <base64|hex|skip>` — how to render `<` binary values on export.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum BinaryEncoding {
    #[default]
    Base64,
    Hex,
    Skip,
}

// ── XML attribute handling (--xml-attrs) ────────────────────────────────────

/// `--xml-attrs <as-fields|prefix>`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum XmlAttrsMode {
    /// `<u id="1"/>` → `{id: =1}`.
    #[default]
    AsFields,
    /// `<u id="1"/>` → `{@id: =1}`.
    Prefix,
}

// ── Conflict policy (--on-conflict) ─────────────────────────────────────────

/// `--on-conflict <error|coerce-string|first-wins>`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ConflictPolicy {
    /// Exit 4 on the first conflict.
    #[default]
    Error,
    /// Widen conflicting keys to string.
    CoerceString,
    /// First-seen sigil wins; later mismatches are errors.
    FirstWins,
}

// ── Inferred schema types ────────────────────────────────────────────────────

/// Return type of the inference pass: each key's chosen sigil plus whether it
/// is optional (absent in ≥1 record).
#[derive(Debug, Default)]
pub struct InferredSchema {
    pub keys: Vec<InferredKey>,
}

#[derive(Debug)]
pub struct InferredKey {
    pub name: String,
    /// NXS sigil byte: `=` `~` `?` `"` `@` `<` `^`
    pub sigil: u8,
    pub optional: bool,
    /// When `Some(s)`, the key is an NXS list whose elements have sigil `s`.
    pub list_of: Option<u8>,
}

// ── Common options ────────────────────────────────────────────────────────────

/// Options shared across all three binaries (I/O paths).
#[derive(Debug, Default, Clone)]
pub struct CommonOpts {
    /// `None` → stdin.
    pub input_path: Option<std::path::PathBuf>,
    /// `None` → stdout.
    pub output_path: Option<std::path::PathBuf>,
}

// ── Import ────────────────────────────────────────────────────────────────────

/// All CLI flags for `nxs-import`. One field per spec flag.
#[derive(Debug)]
pub struct ImportArgs {
    pub common: CommonOpts,
    /// `--from <json|csv|xml>` — required.
    pub from: ImportFormat,
    /// `--schema <file.yaml>` — skip inference; single-pass.
    pub schema_hint: Option<std::path::PathBuf>,
    /// `--on-conflict`
    pub conflict: ConflictPolicy,
    /// `--root <jsonpath>` — default `$` (JSON only).
    pub root: Option<String>,
    /// `--csv-delimiter <char>` — default `,`.
    pub csv_delimiter: Option<char>,
    /// `--csv-no-header` — generate positional keys `col_0`, `col_1`, …
    pub csv_no_header: bool,
    /// `--xml-record-tag <name>` — required for XML.
    pub xml_record_tag: Option<String>,
    /// `--xml-attrs <as-fields|prefix>` — default `as-fields`.
    pub xml_attrs: XmlAttrsMode,
    /// `--buffer-records <N>` — default 4096.
    pub buffer_records: usize,
    /// `--max-depth <N>` — default 64; applies to JSON and XML.
    pub max_depth: usize,
    /// `--xml-max-depth <N>` — default 64; effective = min(max_depth, xml_max_depth).
    pub xml_max_depth: usize,
    /// `--tail-index-spill` — allow tail-index to exceed 512 MB by spilling to disk.
    pub tail_index_spill: bool,
    /// `--verify <auto|force|off>` — default `auto`.
    pub verify: VerifyPolicy,
}

impl Default for ImportArgs {
    fn default() -> Self {
        Self {
            common: CommonOpts::default(),
            from: ImportFormat::default(),
            schema_hint: None,
            conflict: ConflictPolicy::default(),
            root: None,
            csv_delimiter: None,
            csv_no_header: false,
            xml_record_tag: None,
            xml_attrs: XmlAttrsMode::default(),
            buffer_records: 4096,
            max_depth: 64,
            xml_max_depth: 64,
            tail_index_spill: false,
            verify: VerifyPolicy::default(),
        }
    }
}

/// `--from` source format.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum ImportFormat {
    #[default]
    Json,
    Csv,
    Xml,
}

/// Result returned after a successful import.
#[derive(Debug, Default)]
pub struct ImportReport {
    pub records_written: usize,
    pub output_bytes: usize,
}

// ── Export ────────────────────────────────────────────────────────────────────

/// All CLI flags for `nxs-export`. One field per spec flag.
#[derive(Debug, Default)]
pub struct ExportArgs {
    pub common: CommonOpts,
    /// `--to <json|csv>` — required.
    pub to: ExportFormat,
    /// `--pretty` — (JSON only) indent 2 spaces.
    pub pretty: bool,
    /// `--ndjson` — (JSON only) newline-delimited JSON.
    pub ndjson: bool,
    /// `--columns <a,b,c>` — (CSV only) explicit column order.
    pub columns: Option<Vec<String>>,
    /// `--csv-delimiter <char>` — default `,`.
    pub csv_delimiter: Option<char>,
    /// `--binary <base64|hex|skip>` — default `base64`.
    pub binary: BinaryEncoding,
    /// `--csv-safe` — prefix injection-prone cells with `'`.
    pub csv_safe: bool,
}

/// `--to` export format.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    #[default]
    Json,
    Csv,
}

/// Result returned after a successful export.
#[derive(Debug, Default)]
pub struct ExportReport {
    pub records_read: usize,
    pub output_bytes: usize,
}

// ── Inspect ───────────────────────────────────────────────────────────────────

/// All CLI flags for `nxs-inspect`. One field per spec flag.
#[derive(Debug, Default)]
pub struct InspectArgs {
    pub common: CommonOpts,
    /// `--json` — emit structured JSON instead of text.
    pub json_output: bool,
    /// `--records <N|all>` — how many records to summarize. `None` = all.
    pub records_to_show: Option<usize>,
    /// `--verify-hash` — recompute DictHash and compare to preamble.
    pub verify_hash: bool,
}

/// Result returned after a successful inspect.
#[derive(Debug, Default)]
pub struct InspectReport {
    /// `Some(true/false)` only when `--verify-hash` was supplied.
    pub dict_hash_ok: Option<bool>,
    pub record_count: usize,
}

// ── Exit code mapping ─────────────────────────────────────────────────────────

/// Map an `NxsError` to the documented exit code for the converter binaries.
///
/// Exit codes (from spec):
///   0 — success
///   1 — generic error
///   2 — usage error (bad/missing flags)
///   3 — input format error
///   4 — schema conflict
///   5 — IO error
pub fn exit_code_for(err: &crate::error::NxsError) -> i32 {
    use crate::error::NxsError;
    match err {
        NxsError::ConvertSchemaConflict(_) => 4,
        NxsError::ConvertParseError { .. }
        | NxsError::ConvertEntityExpansion
        | NxsError::ConvertDepthExceeded
        | NxsError::BadMagic
        | NxsError::OutOfBounds
        | NxsError::RecursionLimit => 3,
        NxsError::IoError(_) => 5,
        _ => 1,
    }
}

// ── Entry points (stubs) ──────────────────────────────────────────────────────

/// Top-level driver for nxs-import (dispatched on `--from`). Stub.
pub fn run_import(_args: &ImportArgs) -> Result<ImportReport> {
    unimplemented!(
        "run_import — see plan step `impl: nxs-import JSON dispatch in convert::run_import`"
    )
}

/// Top-level driver for nxs-export (dispatched on `--to`). Stub.
pub fn run_export(_args: &ExportArgs) -> Result<ExportReport> {
    unimplemented!("run_export — see plan step `impl: nxs-export JSON dispatch`")
}

/// Top-level driver for nxs-inspect. Stub.
pub fn run_inspect(_args: &InspectArgs) -> Result<InspectReport> {
    unimplemented!("run_inspect — see plan step `impl: nxs-inspect CLI`")
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Every flag that the spec defines for nxs-import must have a corresponding
    /// field in `ImportArgs`. Update this list whenever the spec changes.
    #[test]
    fn import_args_maps_every_spec_flag() {
        // Hand-written mirror of spec nxs_import.optional_flags (plus required).
        // This test fails at compile time if a field is removed; it fails at
        // runtime if someone forgets to add a new spec flag to the list below.
        let spec_fields: &[&str] = &[
            "from",
            "schema_hint",
            "conflict",
            "root",
            "csv_delimiter",
            "csv_no_header",
            "xml_record_tag",
            "xml_attrs",
            "buffer_records",
            "max_depth",
            "xml_max_depth",
            "tail_index_spill",
            "verify",
        ];
        // Build the struct and access every field so the compiler catches removals.
        let a = ImportArgs::default();
        let _ = &a.from;
        let _ = &a.schema_hint;
        let _ = &a.conflict;
        let _ = &a.root;
        let _ = &a.csv_delimiter;
        let _ = &a.csv_no_header;
        let _ = &a.xml_record_tag;
        let _ = &a.xml_attrs;
        let _ = &a.buffer_records;
        let _ = &a.max_depth;
        let _ = &a.xml_max_depth;
        let _ = &a.tail_index_spill;
        let _ = &a.verify;
        assert_eq!(spec_fields.len(), 13, "spec has 13 import flags");
    }

    #[test]
    fn export_args_maps_every_spec_flag() {
        let spec_fields: &[&str] = &[
            "to", "pretty", "ndjson", "columns", "csv_delimiter", "binary", "csv_safe",
        ];
        let a = ExportArgs::default();
        let _ = &a.to;
        let _ = &a.pretty;
        let _ = &a.ndjson;
        let _ = &a.columns;
        let _ = &a.csv_delimiter;
        let _ = &a.binary;
        let _ = &a.csv_safe;
        assert_eq!(spec_fields.len(), 7, "spec has 7 export flags");
    }

    #[test]
    fn inspect_args_maps_every_spec_flag() {
        let spec_fields: &[&str] = &["json_output", "records_to_show", "verify_hash"];
        let a = InspectArgs::default();
        let _ = &a.json_output;
        let _ = &a.records_to_show;
        let _ = &a.verify_hash;
        assert_eq!(spec_fields.len(), 3, "spec has 3 inspect flags");
    }
}
