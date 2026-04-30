This is the formal, exhaustive specification for the **Nexus Standard (NXS)**. This document is designed to be the "Ground Truth" for developers implementing NXS compilers, parsers, and runtime engines.

---

# RFC 001: The Nexus Standard (NXS) Specification v1.0

**Date:** April 30, 2026  
**Status:** Final Specification  
**Editors:** Gemini AI & Collaborator  
**MIME Types:** `application/nxb` (Binary), `application/nxs` (Text)

---

## 1. Abstract
NXS is a high-performance, bi-modal data serialization format that prioritizes **CPU-native memory alignment** and **O(1) random access**. By utilizing a sigil-based type system in text and a bitmask-driven, zero-copy architecture in binary, NXS eliminates the "parsing tax" common in JSON and the "rigidity tax" common in Protobuf.

## 2. Terminology
The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**, **SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** in this document are to be interpreted as described in **RFC 2119**.

---

## 3. The Source Format (.nxs)
The source format is a human-readable UTF-8 representation.

### 3.1 Sigils and Data Types
Every value **MUST** be prefixed with a Sigil to define its machine representation.

| Sigil | Type | Description | Binary Encoding |
| :--- | :--- | :--- | :--- |
| `=` | **Int64** | Signed 64-bit integer | `int64_t` (Little-Endian) |
| `~` | **Float64** | 64-bit floating point | `double` (IEEE 754, Little-Endian) |
| `?` | **Bool** | Truth value | `uint8_t` (0x01 or 0x00) |
| `$` | **Keyword** | Dictionary-interned key | `uint16_t` (Dict Index, Little-Endian) |
| `"` | **String** | UTF-8 Text | `uint32_t` (Len, LE) + Bytes |
| `@` | **Time** | Unix Nanoseconds | `int64_t` (Little-Endian) |
| `<>` | **Binary** | Raw Byte Stream | `uint32_t` (Len, LE) + Bytes |
| `&` | **Link** | Relative pointer | `int32_t` (Byte offset, LE) |
| `!` | **Macro** | Compile-time formula | (Resolved to base type) |
| `^` | **Null** | Explicit absent value | No payload (bitmask bit set, zero-width) |

### 3.2 String Literals and Escape Sequences
String values (sigil `"`) are enclosed in double-quote characters. The following escape sequences **MUST** be supported:

| Sequence | Meaning |
| :--- | :--- |
| `\\` | Literal backslash |
| `\"` | Literal double-quote |
| `\n` | Newline (U+000A) |
| `\r` | Carriage return (U+000D) |
| `\t` | Horizontal tab (U+0009) |
| `\0` | Null byte (U+0000) |
| `\uXXXX` | Unicode code point (4 hex digits) |
| `\UXXXXXXXX` | Unicode code point (8 hex digits) |

Any other character following `\` is a parse error. Parsers **MUST NOT** silently ignore unknown escape sequences.

### 3.3 Macro Expressions (`!`)
A Macro value is a compile-time expression resolved by the NXS compiler before binary output is produced. The expression language is a restricted arithmetic and string subset:

* **Literals:** Any base sigil value (e.g., `=10`, `~3.14`, `"hello"`).
* **Arithmetic:** `+`, `-`, `*`, `/`, `%` over numeric types.
* **String concatenation:** `+` over two String operands.
* **References:** `@key` dereferences another key in the same object scope.
* **Built-ins:** `now()` (current Unix nanoseconds as Int64), `len(@key)` (byte length of a String or Binary value).

**Example:**
```text
config {
    base_url: "https://api.example.com"
    version: =2
    endpoint: !"@base_url/v" + @version
}
```

Macros **MUST** be fully resolved at compile time. A Macro that cannot be statically resolved (e.g., references a runtime value) is a compile error. The resolved value is encoded using its resulting base type.

### 3.4 Structure
* **Objects:** Defined by `{}`. Keys do not require quotes unless they contain whitespace or the characters `{}[]:"`.
* **Lists:** Defined by `[]`. Elements are comma-separated and **MUST** be of a uniform sigil type within a single list.
* **Null:** The `^` sigil stands alone with no following value token.
* **Scope:** Objects can be nested indefinitely, subject to the recursion limit defined in Section 9.

---

## 4. The Binary Format (.nxb)
The binary representation is designed for **Zero-Copy Memory Mapping**. All multi-byte integer fields use **Little-Endian** byte order unless otherwise noted.

### 4.1 Memory Alignment (The Rule of 8)
All atomic values (Int64, Float64, Temporal) **MUST** start at a file offset that satisfies the following condition:

$$Offset \equiv 0 \pmod{8}$$

The compiler **MUST** insert null bytes (`0x00`) as padding to maintain this alignment. Strings and Binary blobs are length-prefixed and **MUST** also be padded at their tail to ensure the *next* value is aligned.

Bool values are 1 byte; the compiler **MUST** insert 7 bytes of padding after each Bool.

### 4.2 File Layout
A `.nxb` file consists of four segments in order:

```
[Preamble 32B][Schema Header][Data Sector][Tail-Index]
```

#### 4.2.1 Preamble (exactly 32 bytes)

| Offset | Size | Field | Description |
| :--- | :--- | :--- | :--- |
| 0 | 4 | `Magic` | `0x4E585342` (`NXSB`) |
| 4 | 2 | `Version` | `0x0100` (major=1, minor=0) |
| 6 | 2 | `Flags` | Bit 0: Jumbo Offsets; Bit 1: Schema Embedded; Bits 2–15: reserved (MUST be 0) |
| 8 | 8 | `DictHash` | 64-bit MurmurHash3 of the Schema Header bytes |
| 16 | 8 | `TailPtr` | Absolute byte offset to the start of the Tail-Index |
| 24 | 8 | `Reserved` | MUST be `0x00` |

#### 4.2.2 Schema Header
Present when `Flags` Bit 1 is set. Immediately follows the Preamble.

| Field | Type | Description |
| :--- | :--- | :--- |
| `KeyCount` | `u16` | Number of keys in the dictionary |
| `TypeManifest` | `u8[KeyCount]` | Sigil byte for each key, in dictionary order |
| `StringPool` | UTF-8 bytes | Null-terminated key name strings, concatenated |

The `StringPool` **MUST** be padded to an 8-byte boundary after the last null terminator.

---

### 4.3 Schema Evolution

NXS uses an **additive-only** schema evolution model. Writers may add new fields to the schema at any time. Existing readers that were compiled against an older schema with fewer fields will continue to work correctly without modification.

**How it works:**

When a reader accesses a field by key name or slot index, it checks the per-object bitmask to determine whether that field is present. If the bit for a requested slot is `0` (absent) or the slot index is beyond the bitmask range, the reader MUST return the language-appropriate "absent" sentinel (e.g., `null`, `None`, `undefined`, `(zero, false)`) rather than raising an error.

**Rules:**
1. Writers MAY add new keys to the end of the schema. Existing slot indices are unchanged.
2. Writers MUST NOT reorder or remove keys from an existing schema.
3. Readers MUST treat a missing bitmask bit (field not present in this record) as absent, not as an error.
4. A file written with an N-field schema is readable by any reader that knows about slots `0` through `M` (M ≤ N); fields `M+1` through `N-1` will simply appear absent.

**Example:** A file written with schema `["a", "b", "c"]` can be read by a reader that only queries `"a"` and `"b"`. Field `"c"` will be absent for that reader — no error is raised, and no schema version negotiation is required.

---

## 5. Object Anatomy
Objects are the primary data container. To support sparse data (missing fields) without wasting space, objects use a **Bitmask + Offset Table** approach.

### 5.1 Object Header

| Field | Size | Description |
| :--- | :--- | :--- |
| `Magic` | 4 bytes | `0x4E58534F` (NXSO) |
| `Length` | 4 bytes | Total byte length of this object including header |
| `Bitmask` | Variable | LEB128-encoded presence mask (see 5.2) |
| `OffsetTable` | Variable | Per-present-field offsets (see 5.3) |

### 5.2 Variable-Width Bitmask
To support more than 64 keys, the bitmask uses a continuation-bit encoding (LEB128):
* The 7 least significant bits of each byte are data bits.
* The Most Significant Bit (MSB) is the **Continuation Bit**.
* If MSB = 1, the next byte is part of the mask.
* The bitmask encodes one bit per dictionary key, in dictionary order (key 0 = LSB of first byte).

### 5.3 The Offset Table
Immediately following the bitmask is the Offset Table.
* Each bit set to `1` in the mask corresponds to one entry in the Offset Table, in dictionary key order.
* **Normal Mode** (Flags Bit 0 = 0): `uint16_t` offsets (max object size 64KB).
* **Jumbo Mode** (Flags Bit 0 = 1): `uint32_t` offsets (max object size 4GB).
* Offsets are **relative to the first byte of the object header** (i.e., the `Magic` field).

### 5.4 Null Fields
A `^` (Null) field has its bitmask bit set to `1` and an entry in the Offset Table. The offset points to a single `0x00` byte. Parsers **MUST** distinguish a missing bit (field absent/unknown) from a Null entry (field explicitly set to null).

---

## 6. List Encoding
Lists are encoded as a typed array immediately within the Data Sector or an enclosing Object's data region.

### 6.1 List Header

| Field | Size | Description |
| :--- | :--- | :--- |
| `Magic` | 4 bytes | `0x4E58534C` (NXSL) |
| `Length` | 4 bytes | Total byte length of this list including header |
| `ElemSigil` | 1 byte | Sigil byte of all elements (uniform type enforced) |
| `ElemCount` | 4 bytes | Number of elements (`uint32_t`) |
| `Padding` | 3 bytes | `0x00` (aligns data to 8-byte boundary from Magic) |

### 6.2 List Data
Immediately follows the header. Elements are laid out contiguously, each obeying the Rule of 8 (Section 4.1). For variable-length types (String, Binary), elements are length-prefixed and tail-padded individually.

---

## 7. The Tail-Index (O(1) Access)
The Tail-Index is located at the end of the file at the offset given by `TailPtr` in the Preamble. It allows a reader to locate top-level records without a linear scan.

| Field | Size | Description |
| :--- | :--- | :--- |
| `EntryCount` | 4 bytes | `uint32_t` total number of indexed records |
| `RecordArray` | Variable | Pairs of `KeyID (u16)` and `AbsoluteOffset (u64)`, Little-Endian |
| `FooterPtr` | 4 bytes | `uint32_t` offset back to the start of the Tail-Index |
| `MagicFooter` | 4 bytes | `0x2153584E` (`NXS!`) |

The final 8 bytes of the file are always `FooterPtr` + `MagicFooter`, allowing a reader to locate the Tail-Index by seeking to `EOF - 8`.

---

## 8. Advanced Operations

### 8.1 Delta Patching
Because NXS uses fixed-width cells for atomic types and length-prefixes for blobs, clients **MAY** perform in-place updates. To update a value:
1. Locate the object via the Tail-Index.
2. Identify the value offset via the Object's Offset Table.
3. Overwrite the specific bytes.
4. **Note:** If a String/Binary update exceeds the original length, the entire object **MUST** be relocated to the end of the file and the Tail-Index updated.

### 8.2 Linking (`&`)
The Link sigil `&` stores a signed 32-bit Little-Endian integer. This value is a **relative byte offset from the first byte of the `&` field's own encoded value** to the first byte of the target object's Magic header. A positive value points forward in the file; a negative value points backward.

Circular links (a chain of `&` references that resolves back to its origin) **MUST** be detected and rejected by parsers. Parsers **SHOULD** limit link-chain depth to 16 hops.

---

## 9. Security and Constraints
1. **Recursion Limit:** Conformant parsers **MUST** support at least 64 levels of nesting but **SHOULD** reject files exceeding this limit to prevent stack exhaustion.
2. **Bounds Checking:** All offsets **MUST** be validated against the total buffer size before memory access. An out-of-bounds offset is a parse error; the parser **MUST NOT** attempt recovery.
3. **Dictionary Drift:** If the `DictHash` in the Preamble does not match the expected local schema, the parser **MUST** prioritize the **Embedded Schema Header** or fail with error `ERR_DICT_MISMATCH` if none is present.
4. **Integer Overflow:** Arithmetic in Macro expressions **MUST** be performed in 64-bit signed arithmetic. Overflow is a compile error.
5. **Circular Links:** See Section 8.2.

---

## 10. Appendix A: Error Codes

| Code | Meaning |
| :--- | :--- |
| `ERR_BAD_MAGIC` | Magic bytes do not match expected value |
| `ERR_UNKNOWN_SIGIL` | Unrecognized sigil byte encountered |
| `ERR_BAD_ESCAPE` | Invalid escape sequence in string literal |
| `ERR_OUT_OF_BOUNDS` | Offset points outside the buffer |
| `ERR_DICT_MISMATCH` | DictHash does not match and no embedded schema present |
| `ERR_CIRCULAR_LINK` | Link chain resolves back to its origin |
| `ERR_RECURSION_LIMIT` | Nesting depth exceeds conformance limit |
| `ERR_MACRO_UNRESOLVED` | Macro expression cannot be statically resolved |
| `ERR_LIST_TYPE_MISMATCH` | List contains elements of mixed sigil types |
| `ERR_OVERFLOW` | Arithmetic overflow in Macro expression |

---

## 11. Appendix B: Example Encoding
**Input (.nxs):**
```text
user {
    id: =1024
    active: ?true
    name: "Alex"
}
```

**Binary Structure (.nxb):**
1. **Preamble (32B):** Magic `NXSB`, Version `0x0100`, Flags `0x0002` (Schema Embedded), DictHash, TailPtr, Reserved.
2. **Schema Header:** KeyCount `0x0003`, TypeManifest `[0x3D, 0x3F, 0x22]` (`=`, `?`, `"`), StringPool `"id\0active\0name\0"` + padding.
3. **Object Header:** Magic `NXSO`, Length, Bitmask `0x07` (bits 0–2 set), OffsetTable `[0x10, 0x18, 0x20]`.
4. **Data Cell 0 (id):** `0x0000000000000400` (Int64 1024, LE).
5. **Data Cell 1 (active):** `0x01` + 7 bytes `0x00` padding.
6. **Data Cell 2 (name):** Length `0x00000004` + `Alex` + 4 bytes `0x00` padding.
7. **Tail-Index:** EntryCount `0x00000001`, Record `[KeyID=0x0000, Offset=<object start>]`, FooterPtr, Magic `NXS!`.

---

**End of Specification**
