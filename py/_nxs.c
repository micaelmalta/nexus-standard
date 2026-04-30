/*
 * _nxs.c — CPython C extension for the NXS binary format reader.
 *
 * Exposes two types:
 *   _nxs.Reader(buffer)       — parses preamble/schema/tail-index
 *   _nxs.Object               — returned by Reader.record(i); decodes fields
 *
 * Design:
 *   - Reader holds the raw bytes pointer; no per-call struct.unpack.
 *   - Schema is precomputed into a key→slot HashMap (via PyDict).
 *   - Bitmask bits are eagerly counted into an offset-table index on object
 *     construction — so get_str/get_i64/etc. are O(1) after first access.
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdint.h>
#include <string.h>

/* ── Format constants (must match writer.rs) ─────────────────────────────── */

#define MAGIC_FILE    0x4E585342u   /* NXSB */
#define MAGIC_OBJ     0x4E58534Fu   /* NXSO */
#define MAGIC_LIST    0x4E58534Cu   /* NXSL */
#define MAGIC_FOOTER  0x2153584Eu   /* NXS! */

/* ── Unaligned little-endian readers ─────────────────────────────────────── */

static inline uint16_t rd_u16(const uint8_t *p) {
    uint16_t v; memcpy(&v, p, 2); return v;
}
static inline uint32_t rd_u32(const uint8_t *p) {
    uint32_t v; memcpy(&v, p, 4); return v;
}
static inline uint64_t rd_u64(const uint8_t *p) {
    uint64_t v; memcpy(&v, p, 8); return v;
}
static inline int64_t rd_i64(const uint8_t *p) {
    int64_t v; memcpy(&v, p, 8); return v;
}
static inline double rd_f64(const uint8_t *p) {
    double v; memcpy(&v, p, 8); return v;
}

/* ── Reader type ─────────────────────────────────────────────────────────── */

typedef struct {
    PyObject_HEAD
    PyObject *buffer_obj;            /* Holds a reference keeping bytes alive */
    Py_buffer view;                  /* Actual byte pointer */
    const uint8_t *data;             /* view.buf */
    Py_ssize_t size;                 /* view.len */
    uint64_t tail_ptr;
    uint32_t record_count;
    Py_ssize_t tail_start;           /* Offset of first record entry */
    PyObject *key_index;             /* dict: str → int (slot) */
    PyObject *keys;                  /* list of str, for introspection */
    int schema_embedded;
} ReaderObject;

static PyTypeObject ReaderType;
static PyTypeObject ObjectType;

static int
Reader_parse_schema_and_tail(ReaderObject *self)
{
    const uint8_t *data = self->data;
    Py_ssize_t size = self->size;
    Py_ssize_t p = 32;

    if (self->schema_embedded) {
        if (p + 2 > size) {
            PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: schema header");
            return -1;
        }
        uint16_t key_count = rd_u16(data + p);
        p += 2;
        p += key_count; /* skip TypeManifest */

        self->keys = PyList_New(key_count);
        self->key_index = PyDict_New();
        if (!self->keys || !self->key_index) return -1;

        for (uint16_t i = 0; i < key_count; i++) {
            Py_ssize_t start = p;
            while (p < size && data[p] != 0) p++;
            if (p >= size) {
                PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: string pool");
                return -1;
            }
            PyObject *s = PyUnicode_DecodeUTF8((const char *)(data + start),
                                                p - start, "strict");
            if (!s) return -1;
            PyList_SET_ITEM(self->keys, i, s); /* steals ref */

            PyObject *idx = PyLong_FromLong(i);
            if (!idx) return -1;
            if (PyDict_SetItem(self->key_index, s, idx) < 0) {
                Py_DECREF(idx);
                return -1;
            }
            Py_DECREF(idx);
            p++; /* skip null terminator */
        }
    }

    /* Tail-index */
    if ((Py_ssize_t)self->tail_ptr + 4 > size) {
        PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: tail index");
        return -1;
    }
    self->record_count = rd_u32(data + self->tail_ptr);
    self->tail_start = self->tail_ptr + 4;
    return 0;
}

static int
Reader_init(ReaderObject *self, PyObject *args, PyObject *kwds)
{
    PyObject *buf_obj;
    if (!PyArg_ParseTuple(args, "O", &buf_obj)) return -1;

    if (PyObject_GetBuffer(buf_obj, &self->view, PyBUF_SIMPLE) < 0) return -1;

    self->buffer_obj = buf_obj;
    Py_INCREF(buf_obj);
    self->data = (const uint8_t *)self->view.buf;
    self->size = self->view.len;

    if (self->size < 32) {
        PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: file too small");
        return -1;
    }

    uint32_t magic = rd_u32(self->data);
    if (magic != MAGIC_FILE) {
        PyErr_SetString(PyExc_ValueError, "ERR_BAD_MAGIC: preamble");
        return -1;
    }

    uint16_t flags = rd_u16(self->data + 6);
    self->tail_ptr = rd_u64(self->data + 16);
    self->schema_embedded = (flags & 0x0002) ? 1 : 0;

    if (rd_u32(self->data + self->size - 4) != MAGIC_FOOTER) {
        PyErr_SetString(PyExc_ValueError, "ERR_BAD_MAGIC: footer");
        return -1;
    }

    if (Reader_parse_schema_and_tail(self) < 0) return -1;
    return 0;
}

static void
Reader_dealloc(ReaderObject *self)
{
    if (self->buffer_obj) {
        PyBuffer_Release(&self->view);
        Py_DECREF(self->buffer_obj);
    }
    Py_XDECREF(self->keys);
    Py_XDECREF(self->key_index);
    Py_TYPE(self)->tp_free((PyObject *)self);
}

/* ── Object type ─────────────────────────────────────────────────────────── */

typedef struct {
    PyObject_HEAD
    ReaderObject *reader;            /* strong ref */
    Py_ssize_t offset;               /* byte offset of NXSO magic */
    Py_ssize_t offset_table_start;
    /* Expanded bitmask: 1 byte per slot (0 or 1). NULL if unparsed. */
    uint8_t *present;
    uint16_t present_len;
    /* Precomputed prefix sum: present_count[s] = count of set bits in slots [0, s) */
    uint16_t *rank;
    int parsed;
} ObjectView;

static ObjectView *
make_object(ReaderObject *reader, Py_ssize_t offset)
{
    ObjectView *obj = PyObject_New(ObjectView, &ObjectType);
    if (!obj) return NULL;
    Py_INCREF(reader);
    obj->reader = reader;
    obj->offset = offset;
    obj->parsed = 0;
    obj->present = NULL;
    obj->rank = NULL;
    obj->present_len = 0;
    obj->offset_table_start = 0;
    return obj;
}

static void
Object_dealloc(ObjectView *self)
{
    if (self->present) PyMem_Free(self->present);
    if (self->rank) PyMem_Free(self->rank);
    Py_XDECREF(self->reader);
    PyObject_Free(self);
}

static int
Object_parse_header(ObjectView *self)
{
    if (self->parsed) return 0;
    const uint8_t *data = self->reader->data;
    Py_ssize_t size = self->reader->size;
    Py_ssize_t p = self->offset;

    if (p + 8 > size) {
        PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: object header");
        return -1;
    }
    if (rd_u32(data + p) != MAGIC_OBJ) {
        PyErr_SetString(PyExc_ValueError, "ERR_BAD_MAGIC: object");
        return -1;
    }
    p += 8; /* skip magic + length */

    /* Read LEB128 bitmask into a sized array of single-bit values */
    uint16_t key_count = (uint16_t)PyList_GET_SIZE(self->reader->keys);
    self->present = (uint8_t *)PyMem_Calloc(key_count + 8, 1);
    if (!self->present) { PyErr_NoMemory(); return -1; }
    self->rank = (uint16_t *)PyMem_Calloc(key_count + 1, sizeof(uint16_t));
    if (!self->rank) { PyErr_NoMemory(); return -1; }

    uint16_t slot = 0;
    uint8_t byte;
    do {
        if (p >= size) {
            PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: bitmask");
            return -1;
        }
        byte = data[p++];
        uint8_t data_bits = byte & 0x7F;
        for (int b = 0; b < 7 && slot < key_count; b++, slot++) {
            self->present[slot] = (data_bits >> b) & 1;
        }
    } while ((byte & 0x80) && slot < key_count);

    /* Build rank prefix-sum so slot-index → table-index is O(1) */
    uint16_t acc = 0;
    for (uint16_t s = 0; s < key_count; s++) {
        self->rank[s] = acc;
        acc += self->present[s];
    }
    self->rank[key_count] = acc;
    self->present_len = key_count;

    self->offset_table_start = p;
    self->parsed = 1;
    return 0;
}

/* Returns absolute byte offset of the value for `slot`, or -1 if absent. */
static Py_ssize_t
Object_field_offset(ObjectView *self, int slot)
{
    if (!self->parsed && Object_parse_header(self) < 0) return -1;
    if (slot < 0 || slot >= self->present_len) return -1;
    if (!self->present[slot]) return -1;

    uint16_t entry_idx = self->rank[slot];
    Py_ssize_t ofpos = self->offset_table_start + entry_idx * 2;
    uint16_t rel = rd_u16(self->reader->data + ofpos);
    return self->offset + rel;
}

/* ── Per-type accessors ──────────────────────────────────────────────────── */

/* Look up the slot index for a given key. Returns -1 if not found. */
static int
resolve_slot(ObjectView *self, PyObject *key)
{
    PyObject *idx_obj = PyDict_GetItemWithError(self->reader->key_index, key);
    if (!idx_obj) {
        if (PyErr_Occurred()) return -2;
        return -1;
    }
    return (int)PyLong_AsLong(idx_obj);
}

static PyObject *
Object_get_i64(ObjectView *self, PyObject *key)
{
    int slot = resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) Py_RETURN_NONE;

    Py_ssize_t off = Object_field_offset(self, slot);
    if (off < 0) {
        if (PyErr_Occurred()) return NULL;
        Py_RETURN_NONE;
    }
    if (off + 8 > self->reader->size) {
        PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: i64"); return NULL;
    }
    return PyLong_FromLongLong(rd_i64(self->reader->data + off));
}

static PyObject *
Object_get_f64(ObjectView *self, PyObject *key)
{
    int slot = resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) Py_RETURN_NONE;

    Py_ssize_t off = Object_field_offset(self, slot);
    if (off < 0) {
        if (PyErr_Occurred()) return NULL;
        Py_RETURN_NONE;
    }
    if (off + 8 > self->reader->size) {
        PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: f64"); return NULL;
    }
    return PyFloat_FromDouble(rd_f64(self->reader->data + off));
}

static PyObject *
Object_get_bool(ObjectView *self, PyObject *key)
{
    int slot = resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) Py_RETURN_NONE;

    Py_ssize_t off = Object_field_offset(self, slot);
    if (off < 0) {
        if (PyErr_Occurred()) return NULL;
        Py_RETURN_NONE;
    }
    if (off >= self->reader->size) {
        PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: bool"); return NULL;
    }
    if (self->reader->data[off]) Py_RETURN_TRUE; else Py_RETURN_FALSE;
}

static PyObject *
Object_get_str(ObjectView *self, PyObject *key)
{
    int slot = resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) Py_RETURN_NONE;

    Py_ssize_t off = Object_field_offset(self, slot);
    if (off < 0) {
        if (PyErr_Occurred()) return NULL;
        Py_RETURN_NONE;
    }
    if (off + 4 > self->reader->size) {
        PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: str len"); return NULL;
    }
    uint32_t n = rd_u32(self->reader->data + off);
    if (off + 4 + n > (uint64_t)self->reader->size) {
        PyErr_SetString(PyExc_ValueError, "ERR_OUT_OF_BOUNDS: str bytes"); return NULL;
    }
    return PyUnicode_DecodeUTF8((const char *)(self->reader->data + off + 4),
                                n, "strict");
}

static PyMethodDef Object_methods[] = {
    {"get_i64",  (PyCFunction)Object_get_i64,  METH_O, "Read i64 field."},
    {"get_f64",  (PyCFunction)Object_get_f64,  METH_O, "Read f64 field."},
    {"get_bool", (PyCFunction)Object_get_bool, METH_O, "Read bool field."},
    {"get_str",  (PyCFunction)Object_get_str,  METH_O, "Read UTF-8 string field."},
    {"get_time", (PyCFunction)Object_get_i64,  METH_O, "Read time field (unix ns)."},
    {NULL, NULL, 0, NULL}
};

static PyTypeObject ObjectType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "_nxs.Object",
    .tp_basicsize = sizeof(ObjectView),
    .tp_dealloc = (destructor)Object_dealloc,
    .tp_flags = Py_TPFLAGS_DEFAULT,
    .tp_doc = "NXS object view (lazy).",
    .tp_methods = Object_methods,
};

/* ── Bulk scan helpers ───────────────────────────────────────────────────── */

/*
 * Locate the absolute byte offset of a given slot's value in an object at
 * `obj_offset`. Returns -1 on absent/out-of-bounds. No allocation.
 *
 * This is the same algorithm as Object_field_offset but inlined and without
 * caching — optimised for a hot linear scan where we call it once per record.
 */
static inline Py_ssize_t
scan_field_offset(const uint8_t *data, Py_ssize_t size,
                  Py_ssize_t obj_offset, int slot)
{
    Py_ssize_t p = obj_offset + 8; /* skip NXSO magic + length */
    if (p > size) return -1;

    /* Walk LEB128 bitmask while:
     *   - checking whether target slot bit is set
     *   - counting present bits before it to get the offset-table index */
    int cur_slot = 0;
    int table_idx = 0;
    int found = 0;
    uint8_t byte;
    do {
        if (p >= size) return -1;
        byte = data[p++];
        uint8_t data_bits = byte & 0x7F;
        for (int b = 0; b < 7; b++) {
            if (cur_slot == slot) {
                if ((data_bits >> b) & 1) found = 1;
                else return -1;
            } else if (cur_slot < slot && ((data_bits >> b) & 1)) {
                table_idx++;
            }
            cur_slot++;
        }
        if (found && (byte & 0x80) == 0) break;
        if (cur_slot > slot && found) break;
    } while (byte & 0x80);

    if (!found) return -1;

    /* Skip the rest of the bitmask if we stopped mid-way — we need p at
     * offset_table_start */
    while (byte & 0x80) {
        if (p >= size) return -1;
        byte = data[p++];
    }

    Py_ssize_t ofpos = p + table_idx * 2;
    if (ofpos + 2 > size) return -1;
    uint16_t rel = rd_u16(data + ofpos);
    return obj_offset + rel;
}

/* Resolve a key name → slot index or return error with -2 / absent with -1 */
static int
reader_resolve_slot(ReaderObject *self, PyObject *key)
{
    PyObject *idx_obj = PyDict_GetItemWithError(self->key_index, key);
    if (!idx_obj) {
        if (PyErr_Occurred()) return -2;
        return -1;
    }
    return (int)PyLong_AsLong(idx_obj);
}

/* ── Reader methods ──────────────────────────────────────────────────────── */

static PyObject *
Reader_record(ReaderObject *self, PyObject *arg)
{
    long i = PyLong_AsLong(arg);
    if (i == -1 && PyErr_Occurred()) return NULL;
    if (i < 0 || (uint32_t)i >= self->record_count) {
        PyErr_Format(PyExc_IndexError, "record %ld out of [0, %u)",
                     i, self->record_count);
        return NULL;
    }
    Py_ssize_t entry = self->tail_start + i * 10;
    uint64_t abs_offset = rd_u64(self->data + entry + 2);
    return (PyObject *)make_object(self, (Py_ssize_t)abs_offset);
}

/*
 * Columnar scan: return a list of all values for `key` across all top-level
 * records. The key name and slot are resolved once; the LEB128 walk runs in C
 * with no Python overhead per record.
 */
static PyObject *
Reader_scan_f64(ReaderObject *self, PyObject *key)
{
    int slot = reader_resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) {
        PyErr_SetString(PyExc_KeyError, "key not in schema");
        return NULL;
    }

    uint32_t n = self->record_count;
    PyObject *list = PyList_New(n);
    if (!list) return NULL;

    const uint8_t *data = self->data;
    Py_ssize_t size = self->size;
    Py_ssize_t tail = self->tail_start;

    for (uint32_t i = 0; i < n; i++) {
        uint64_t abs = rd_u64(data + tail + i * 10 + 2);
        Py_ssize_t off = scan_field_offset(data, size, (Py_ssize_t)abs, slot);
        PyObject *v;
        if (off < 0 || off + 8 > size) {
            Py_INCREF(Py_None);
            v = Py_None;
        } else {
            v = PyFloat_FromDouble(rd_f64(data + off));
            if (!v) { Py_DECREF(list); return NULL; }
        }
        PyList_SET_ITEM(list, i, v);
    }
    return list;
}

static PyObject *
Reader_scan_i64(ReaderObject *self, PyObject *key)
{
    int slot = reader_resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) {
        PyErr_SetString(PyExc_KeyError, "key not in schema");
        return NULL;
    }

    uint32_t n = self->record_count;
    PyObject *list = PyList_New(n);
    if (!list) return NULL;

    const uint8_t *data = self->data;
    Py_ssize_t size = self->size;
    Py_ssize_t tail = self->tail_start;

    for (uint32_t i = 0; i < n; i++) {
        uint64_t abs = rd_u64(data + tail + i * 10 + 2);
        Py_ssize_t off = scan_field_offset(data, size, (Py_ssize_t)abs, slot);
        PyObject *v;
        if (off < 0 || off + 8 > size) {
            Py_INCREF(Py_None);
            v = Py_None;
        } else {
            v = PyLong_FromLongLong(rd_i64(data + off));
            if (!v) { Py_DECREF(list); return NULL; }
        }
        PyList_SET_ITEM(list, i, v);
    }
    return list;
}

/* In-native reducers: sum / min / max / count over an f64 field. */
static PyObject *
Reader_sum_f64(ReaderObject *self, PyObject *key)
{
    int slot = reader_resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) {
        PyErr_SetString(PyExc_KeyError, "key not in schema"); return NULL;
    }
    const uint8_t *data = self->data;
    Py_ssize_t size = self->size;
    Py_ssize_t tail = self->tail_start;
    uint32_t n = self->record_count;
    double sum = 0.0;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t abs = rd_u64(data + tail + i * 10 + 2);
        Py_ssize_t off = scan_field_offset(data, size, (Py_ssize_t)abs, slot);
        if (off < 0 || off + 8 > size) continue;
        sum += rd_f64(data + off);
    }
    return PyFloat_FromDouble(sum);
}

static PyObject *
Reader_min_f64(ReaderObject *self, PyObject *key)
{
    int slot = reader_resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) {
        PyErr_SetString(PyExc_KeyError, "key not in schema"); return NULL;
    }
    const uint8_t *data = self->data;
    Py_ssize_t size = self->size;
    Py_ssize_t tail = self->tail_start;
    uint32_t n = self->record_count;
    double m = 0; int have = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t abs = rd_u64(data + tail + i * 10 + 2);
        Py_ssize_t off = scan_field_offset(data, size, (Py_ssize_t)abs, slot);
        if (off < 0 || off + 8 > size) continue;
        double v = rd_f64(data + off);
        if (!have || v < m) { m = v; have = 1; }
    }
    if (!have) Py_RETURN_NONE;
    return PyFloat_FromDouble(m);
}

static PyObject *
Reader_max_f64(ReaderObject *self, PyObject *key)
{
    int slot = reader_resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) {
        PyErr_SetString(PyExc_KeyError, "key not in schema"); return NULL;
    }
    const uint8_t *data = self->data;
    Py_ssize_t size = self->size;
    Py_ssize_t tail = self->tail_start;
    uint32_t n = self->record_count;
    double m = 0; int have = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t abs = rd_u64(data + tail + i * 10 + 2);
        Py_ssize_t off = scan_field_offset(data, size, (Py_ssize_t)abs, slot);
        if (off < 0 || off + 8 > size) continue;
        double v = rd_f64(data + off);
        if (!have || v > m) { m = v; have = 1; }
    }
    if (!have) Py_RETURN_NONE;
    return PyFloat_FromDouble(m);
}

static PyObject *
Reader_sum_i64(ReaderObject *self, PyObject *key)
{
    int slot = reader_resolve_slot(self, key);
    if (slot == -2) return NULL;
    if (slot == -1) {
        PyErr_SetString(PyExc_KeyError, "key not in schema"); return NULL;
    }
    const uint8_t *data = self->data;
    Py_ssize_t size = self->size;
    Py_ssize_t tail = self->tail_start;
    uint32_t n = self->record_count;
    int64_t sum = 0;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t abs = rd_u64(data + tail + i * 10 + 2);
        Py_ssize_t off = scan_field_offset(data, size, (Py_ssize_t)abs, slot);
        if (off < 0 || off + 8 > size) continue;
        sum += rd_i64(data + off);
    }
    return PyLong_FromLongLong(sum);
}

static PyObject *
Reader_get_record_count(ReaderObject *self, void *closure)
{
    return PyLong_FromUnsignedLong(self->record_count);
}

static PyObject *
Reader_get_keys(ReaderObject *self, void *closure)
{
    Py_INCREF(self->keys);
    return self->keys;
}

static PyMethodDef Reader_methods[] = {
    {"record",   (PyCFunction)Reader_record,   METH_O, "Get the object at index i."},
    {"scan_f64", (PyCFunction)Reader_scan_f64, METH_O, "List of all f64 values for key."},
    {"scan_i64", (PyCFunction)Reader_scan_i64, METH_O, "List of all i64 values for key."},
    {"sum_f64",  (PyCFunction)Reader_sum_f64,  METH_O, "Sum of an f64 field across all records."},
    {"min_f64",  (PyCFunction)Reader_min_f64,  METH_O, "Min of an f64 field across all records."},
    {"max_f64",  (PyCFunction)Reader_max_f64,  METH_O, "Max of an f64 field across all records."},
    {"sum_i64",  (PyCFunction)Reader_sum_i64,  METH_O, "Sum of an i64 field across all records."},
    {NULL, NULL, 0, NULL}
};

static PyGetSetDef Reader_getset[] = {
    {"record_count", (getter)Reader_get_record_count, NULL, "Total top-level records.", NULL},
    {"keys",         (getter)Reader_get_keys,         NULL, "Schema keys.", NULL},
    {NULL}
};

static PyTypeObject ReaderType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "_nxs.Reader",
    .tp_basicsize = sizeof(ReaderObject),
    .tp_dealloc = (destructor)Reader_dealloc,
    .tp_flags = Py_TPFLAGS_DEFAULT,
    .tp_doc = "NXS binary file reader (C accelerated).",
    .tp_init = (initproc)Reader_init,
    .tp_new = PyType_GenericNew,
    .tp_methods = Reader_methods,
    .tp_getset = Reader_getset,
};

/* ── Module setup ────────────────────────────────────────────────────────── */

static PyModuleDef nxs_module = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_nxs",
    .m_doc = "NXS binary format reader (C extension).",
    .m_size = -1,
};

PyMODINIT_FUNC
PyInit__nxs(void)
{
    if (PyType_Ready(&ReaderType) < 0) return NULL;
    if (PyType_Ready(&ObjectType) < 0) return NULL;

    PyObject *m = PyModule_Create(&nxs_module);
    if (!m) return NULL;

    Py_INCREF(&ReaderType);
    if (PyModule_AddObject(m, "Reader", (PyObject *)&ReaderType) < 0) {
        Py_DECREF(&ReaderType);
        Py_DECREF(m);
        return NULL;
    }
    return m;
}
