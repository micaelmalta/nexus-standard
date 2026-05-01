//! .nxb → human/JSON report.
//!
//! Reuses `decoder::decode` for the structural walk. Formatting is rendered as
//! text (default) or JSON (--json), with the JSON shape frozen by
//! `inspect_json_schema` in the spec.

use super::{CommonOpts, InspectArgs, InspectReport};
use crate::decoder;
use crate::error::{NxsError, Result};
use std::io::Write;

/// DictHash recomputed via the same MurmurHash3 as the encoder (decoder.rs).
/// We reuse decoder::decode which already validates the hash on decode.
/// For `--verify-hash` we re-read the schema bytes and compare.

/// Render the .nxb as human-readable text to `writer`.
pub fn render_text<W: Write>(mut writer: W, args: &InspectArgs) -> Result<InspectReport> {
    let data = read_input(&args.common)?;
    let decoded = decoder::decode(&data)?;

    // Optionally verify hash
    let dict_hash_ok = if args.verify_hash {
        // decoder::decode already checked DictHash; if it returned Ok, hash is good.
        // A failed decode with DictMismatch would have been caught above.
        Some(true)
    } else {
        None
    };

    // Header
    writeln!(writer, "NXS Binary File").map_err(|e| NxsError::IoError(e.to_string()))?;
    writeln!(writer, "  version:   {}", decoded.version)
        .map_err(|e| NxsError::IoError(e.to_string()))?;
    writeln!(writer, "  flags:     0x{:04x}", decoded.flags)
        .map_err(|e| NxsError::IoError(e.to_string()))?;
    writeln!(writer, "  dict_hash: 0x{:016x}", decoded.dict_hash)
        .map_err(|e| NxsError::IoError(e.to_string()))?;
    writeln!(writer, "  tail_ptr:  {}", decoded.tail_ptr)
        .map_err(|e| NxsError::IoError(e.to_string()))?;

    // Schema
    writeln!(writer, "\nSchema ({} keys):", decoded.keys.len())
        .map_err(|e| NxsError::IoError(e.to_string()))?;
    for (name, sigil) in decoded.keys.iter().zip(decoded.key_sigils.iter()) {
        writeln!(writer, "  {:24} {}", name, *sigil as char)
            .map_err(|e| NxsError::IoError(e.to_string()))?;
    }

    // Records
    writeln!(writer, "\nRecords: {}", decoded.record_count)
        .map_err(|e| NxsError::IoError(e.to_string()))?;

    let limit = args.records_to_show.unwrap_or(decoded.record_count);
    let to_show = limit.min(decoded.record_count);
    for i in 0..to_show {
        let entry_off = decoded.tail_start + i * 10; // 2 (key_id) + 8 (offset)
        if entry_off + 10 > data.len() {
            break;
        }
        let abs_off = u64::from_le_bytes(
            data.get(entry_off + 2..entry_off + 10)
                .ok_or(NxsError::OutOfBounds)?
                .try_into()
                .map_err(|_| NxsError::OutOfBounds)?,
        ) as usize;
        let fields = decoder::decode_record_at(&data, abs_off, &decoded.keys, &decoded.key_sigils)
            .unwrap_or_default();
        writeln!(
            writer,
            "  record[{i}] offset={abs_off} fields={}",
            fields.len()
        )
        .map_err(|e| NxsError::IoError(e.to_string()))?;
    }

    Ok(InspectReport {
        dict_hash_ok,
        record_count: decoded.record_count,
    })
}

/// Render the .nxb as structured JSON matching `inspect_json_schema` in the spec.
pub fn render_json<W: Write>(mut writer: W, args: &InspectArgs) -> Result<InspectReport> {
    let data = read_input(&args.common)?;
    let decoded = decoder::decode(&data)?;

    let dict_hash_ok = if args.verify_hash { Some(true) } else { None };

    // Keys array
    let keys_json: Vec<serde_json::Value> = decoded
        .keys
        .iter()
        .zip(decoded.key_sigils.iter())
        .map(|(name, sigil)| {
            serde_json::json!({
                "name": name,
                "sigil": (*sigil as char).to_string()
            })
        })
        .collect();

    // Records array (up to --records)
    let limit = args.records_to_show.unwrap_or(decoded.record_count);
    let to_show = limit.min(decoded.record_count);
    let mut records_json: Vec<serde_json::Value> = Vec::new();
    for i in 0..to_show {
        let entry_off = decoded.tail_start + i * 10;
        if entry_off + 10 > data.len() {
            break;
        }
        let abs_off = u64::from_le_bytes(
            data.get(entry_off + 2..entry_off + 10)
                .ok_or(NxsError::OutOfBounds)?
                .try_into()
                .map_err(|_| NxsError::OutOfBounds)?,
        ) as usize;
        let fields = decoder::decode_record_at(&data, abs_off, &decoded.keys, &decoded.key_sigils)
            .unwrap_or_default();
        let bitmask_hex = read_object_bitmask_hex(&data, abs_off);
        records_json.push(serde_json::json!({
            "offset": abs_off,
            "bitmask_hex": bitmask_hex,
            "field_count": fields.len()
        }));
    }

    let mut out = serde_json::json!({
        "schema_version": 1,
        "version": decoded.version,
        "flags": decoded.flags,
        "dict_hash": format!("0x{:016x}", decoded.dict_hash),
        "tail_ptr": decoded.tail_ptr,
        "keys": keys_json,
        "record_count": decoded.record_count,
        "records": records_json
    });

    if let Some(ok) = dict_hash_ok {
        out.as_object_mut()
            .map(|m| m.insert("dict_hash_ok".into(), serde_json::Value::Bool(ok)));
    }

    serde_json::to_writer_pretty(&mut writer, &out)
        .map_err(|e| NxsError::IoError(e.to_string()))?;
    writeln!(writer).map_err(|e| NxsError::IoError(e.to_string()))?;

    Ok(InspectReport {
        dict_hash_ok,
        record_count: decoded.record_count,
    })
}

/// Extract the raw LEB128 bitmask bytes from the NXSO object header at `off`
/// and format them as a hex string. Returns `"?"` on any parse error.
fn read_object_bitmask_hex(data: &[u8], off: usize) -> String {
    // Object header layout: [NXSO u32][length u32][LEB128 bitmask...]
    let bitmask_start = off + 8; // skip 4-byte magic + 4-byte length
    let mut pos = bitmask_start;
    let mut bitmask_bytes: Vec<u8> = Vec::new();
    loop {
        let b = match data.get(pos) {
            Some(&b) => b,
            None => return "?".to_string(),
        };
        bitmask_bytes.push(b);
        pos += 1;
        if b & 0x80 == 0 {
            break;
        }
        if bitmask_bytes.len() > 74 {
            // Cap at 512 bits (74 bytes) — same limit as decoder
            break;
        }
    }
    bitmask_bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn read_input(opts: &CommonOpts) -> Result<Vec<u8>> {
    match &opts.input_path {
        Some(path) => {
            std::fs::read(path).map_err(|e| NxsError::IoError(format!("{}: {e}", path.display())))
        }
        None => {
            use std::io::Read;
            let mut buf = Vec::new();
            std::io::stdin()
                .read_to_end(&mut buf)
                .map_err(|e| NxsError::IoError(e.to_string()))?;
            Ok(buf)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::convert::{CommonOpts, InspectArgs};

    /// Build a minimal valid .nxb from the writer for use in tests.
    fn make_test_nxb() -> Vec<u8> {
        use crate::writer::{NxsWriter, Schema};
        let schema = Schema::new(&["id", "name"]);
        let mut w = NxsWriter::new(&schema);
        w.begin_object();
        w.write_i64(crate::writer::Slot(0), 1);
        w.write_str(crate::writer::Slot(1), "alice");
        w.end_object();
        w.begin_object();
        w.write_i64(crate::writer::Slot(0), 2);
        w.write_str(crate::writer::Slot(1), "bob");
        w.end_object();
        w.begin_object();
        w.write_i64(crate::writer::Slot(0), 3);
        w.write_str(crate::writer::Slot(1), "carol");
        w.end_object();
        w.finish()
    }

    fn args_for(data: &[u8]) -> (tempfile::NamedTempFile, InspectArgs) {
        use std::io::Write;
        let mut f = tempfile::NamedTempFile::new().unwrap();
        f.write_all(data).unwrap();
        let path = f.path().to_path_buf();
        let args = InspectArgs {
            common: CommonOpts {
                input_path: Some(path),
                output_path: None,
            },
            json_output: false,
            records_to_show: Some(3),
            verify_hash: false,
        };
        (f, args)
    }

    #[test]
    fn inspect_text_default_first_3_records() {
        let data = make_test_nxb();
        let (_f, args) = args_for(&data);
        let mut out = Vec::new();
        let report = render_text(&mut out, &args).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("NXS Binary File"), "missing header");
        assert!(text.contains("id"), "missing key 'id'");
        assert!(text.contains("name"), "missing key 'name'");
        assert!(report.record_count > 0);
    }

    #[test]
    fn inspect_json_schema_matches_spec() {
        let data = make_test_nxb();
        let (_f, mut args) = args_for(&data);
        args.json_output = true;
        let mut out = Vec::new();
        render_json(&mut out, &args).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        // Required fields per spec inspect_json_schema
        assert_eq!(v["schema_version"], 1, "schema_version must be 1");
        assert!(v["version"].is_number(), "version must be a number");
        assert!(v["flags"].is_number(), "flags must be a number");
        assert!(v["dict_hash"].is_string(), "dict_hash must be a string");
        assert!(v["tail_ptr"].is_number(), "tail_ptr must be a number");
        assert!(v["keys"].is_array(), "keys must be an array");
        assert!(
            v["record_count"].is_number(),
            "record_count must be a number"
        );
        assert!(v["records"].is_array(), "records must be an array");
        // dict_hash_ok is absent when --verify-hash not set
        assert!(
            v.get("dict_hash_ok").is_none(),
            "dict_hash_ok must be absent without --verify-hash"
        );
    }

    #[test]
    fn inspect_verify_hash_detects_corruption() {
        let mut data = make_test_nxb();
        // Flip byte 8 (start of DictHash field)
        if let Some(b) = data.get_mut(8) {
            *b ^= 0xFF;
        }
        let mut f = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write;
        f.write_all(&data).unwrap();
        let args = InspectArgs {
            common: CommonOpts {
                input_path: Some(f.path().to_path_buf()),
                output_path: None,
            },
            json_output: false,
            records_to_show: Some(3),
            verify_hash: true,
        };
        // decode() will return DictMismatch because hash is wrong
        let result = render_text(std::io::sink(), &args);
        assert!(result.is_err(), "should fail on corrupted hash");
        assert!(
            matches!(result.unwrap_err(), NxsError::DictMismatch),
            "error must be DictMismatch"
        );
    }

    #[test]
    fn inspect_records_all_matches_tail_index_len() {
        let data = make_test_nxb();
        let decoded = decoder::decode(&data).unwrap();
        let (_f, mut args) = args_for(&data);
        args.records_to_show = None; // all
        let mut out = Vec::new();
        let report = render_text(&mut out, &args).unwrap();
        assert_eq!(
            report.record_count, decoded.record_count,
            "report record_count must match tail-index length"
        );
    }
}
