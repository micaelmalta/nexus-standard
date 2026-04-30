"""Smoke tests for the Python NXS reader.

Run: python3 test_nxs.py [fixtures_dir]
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from nxs import NxsReader, NxsError


def main() -> int:
    fixture_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "../js/fixtures")
    nxb_path = fixture_dir / "records_1000.nxb"
    json_path = fixture_dir / "records_1000.json"

    if not nxb_path.exists():
        print(f"fixtures not found at {fixture_dir}")
        print("generate them first:  cargo run --release --bin gen_fixtures -- js/fixtures")
        return 1

    buf = nxb_path.read_bytes()
    js = json.loads(json_path.read_text())

    passed = failed = 0
    print("\nNXS Python Reader — Tests\n")

    def case(name, fn):
        nonlocal passed, failed
        try:
            fn()
            print(f"  ✓ {name}")
            passed += 1
        except Exception as e:
            print(f"  ✗ {name}\n      {e}")
            failed += 1

    # ── Tests ──────────────────────────────────────────────────────────────
    def opens():
        NxsReader(buf)

    def count():
        r = NxsReader(buf)
        assert r.record_count == 1000, r.record_count

    def keys():
        r = NxsReader(buf)
        for k in ("id", "username", "email", "score", "active"):
            assert k in r.keys, f"missing key {k}"

    def record_0_id():
        r = NxsReader(buf)
        assert r.record(0).get_i64("id") == js[0]["id"]

    def record_42_username():
        r = NxsReader(buf)
        assert r.record(42).get_str("username") == js[42]["username"]

    def record_500_score():
        r = NxsReader(buf)
        got = r.record(500).get_f64("score")
        assert math.isclose(got, js[500]["score"], rel_tol=1e-6), (got, js[500]["score"])

    def record_999_active():
        r = NxsReader(buf)
        assert r.record(999).get_bool("active") == js[999]["active"]

    def oob_raises():
        r = NxsReader(buf)
        try:
            r.record(10_000)
        except NxsError:
            return
        raise AssertionError("expected NxsError")

    def iter_count():
        r = NxsReader(buf)
        assert sum(1 for _ in r.records()) == 1000

    def sum_matches():
        r = NxsReader(buf)
        nxs_sum = sum(rec.get_f64("score") for rec in r.records())
        json_sum = sum(rec["score"] for rec in js)
        assert math.isclose(nxs_sum, json_sum, rel_tol=1e-6), (nxs_sum, json_sum)

    case("opens without error", opens)
    case("reads correct record count", count)
    case("reads schema keys", keys)
    case("record(0) matches JSON[0].id", record_0_id)
    case("record(42) matches JSON[42].username", record_42_username)
    case("record(500) matches JSON[500].score", record_500_score)
    case("record(999) matches JSON[999].active", record_999_active)
    case("out-of-bounds raises NxsError", oob_raises)
    case("iteration visits every record", iter_count)
    case("iteration sum matches JSON sum", sum_matches)

    # ── Security tests ───────────────────────────────────────────────────────
    def bad_magic():
        bad = bytearray(buf); bad[0] = 0x00
        try: NxsReader(bytes(bad))
        except NxsError as e:
            assert "ERR_BAD_MAGIC" in e.args[0]; return
        raise AssertionError("expected ERR_BAD_MAGIC")

    def truncated():
        try: NxsReader(buf[:16])
        except NxsError: return
        raise AssertionError("expected error on truncated file")

    def dict_mismatch():
        bad = bytearray(buf); bad[8] ^= 0xFF
        try: NxsReader(bytes(bad))
        except NxsError as e:
            assert "ERR_DICT_MISMATCH" in e.args[0]; return
        raise AssertionError("expected ERR_DICT_MISMATCH")

    case("bad magic raises ERR_BAD_MAGIC", bad_magic)
    case("truncated file raises NxsError", truncated)
    case("corrupt DictHash raises ERR_DICT_MISMATCH", dict_mismatch)

    print(f"\n{passed} passed, {failed} failed\n")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
