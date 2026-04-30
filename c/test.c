// NXS C reader smoke tests
// Build: cc -std=c99 -O2 -o test test.c nxs.c -lm && ./test ../js/fixtures
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "nxs.h"

// Minimal JSON parser for the fixture — just enough to validate numbers/strings.
// We read the JSON ourselves rather than pulling in a library.
typedef struct { int64_t id; double score; int active; char username[64]; } Record;

static uint8_t *read_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *out_size = (size_t)ftell(f);
    rewind(f);
    uint8_t *buf = malloc(*out_size);
    if (buf) fread(buf, 1, *out_size, f);
    fclose(f);
    return buf;
}

static int passed = 0, failed = 0;

#define CHECK(name, expr) do { \
    if (expr) { printf("  ✓ %s\n", name); passed++; } \
    else      { printf("  ✗ %s\n", name); failed++; } \
} while(0)

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "../js/fixtures";
    char nxb_path[512], json_path[512];
    snprintf(nxb_path,  sizeof(nxb_path),  "%s/records_1000.nxb",  dir);
    snprintf(json_path, sizeof(json_path), "%s/records_1000.json", dir);

    size_t nxb_size = 0;
    uint8_t *nxb_data = read_file(nxb_path, &nxb_size);
    if (!nxb_data) {
        printf("fixtures not found at %s\n", dir);
        printf("generate them: cargo run --release --bin gen_fixtures -- js/fixtures\n");
        return 1;
    }

    printf("\nNXS C Reader — Tests\n\n");

    nxs_reader_t r;
    nxs_err_t err = nxs_open(&r, nxb_data, nxb_size);
    CHECK("opens without error", err == NXS_OK);
    CHECK("reads correct record count", r.record_count == 1000);

    int has_id = 0, has_username = 0, has_score = 0;
    for (int i = 0; i < r.key_count; i++) {
        if (strcmp(r.keys[i], "id")       == 0) has_id = 1;
        if (strcmp(r.keys[i], "username") == 0) has_username = 1;
        if (strcmp(r.keys[i], "score")    == 0) has_score = 1;
    }
    CHECK("reads schema keys", has_id && has_username && has_score);

    // record(0) id reads without error
    {
        nxs_object_t obj;
        nxs_record(&r, 0, &obj);
        int64_t id = -1;
        nxs_err_t e = nxs_get_i64(&obj, "id", &id);
        CHECK("record(0) id reads without error", e == NXS_OK);
    }

    // record(42) has a non-empty username
    {
        nxs_object_t obj;
        nxs_record(&r, 42, &obj);
        char uname[64] = {0};
        nxs_get_str(&obj, "username", uname, sizeof(uname));
        CHECK("record(42) username non-empty", uname[0] != '\0');
    }

    // record(500) score is a finite float
    {
        nxs_object_t obj;
        nxs_record(&r, 500, &obj);
        double score = 0.0;
        nxs_get_f64(&obj, "score", &score);
        CHECK("record(500) score is finite", isfinite(score));
    }

    // record(999) active is 0 or 1
    {
        nxs_object_t obj;
        nxs_record(&r, 999, &obj);
        int active = -1;
        nxs_get_bool(&obj, "active", &active);
        CHECK("record(999) active is bool", active == 0 || active == 1);
    }

    // out-of-bounds returns error
    {
        nxs_object_t obj;
        nxs_err_t e = nxs_record(&r, 10000, &obj);
        CHECK("out-of-bounds record returns error", e == NXS_ERR_OUT_OF_BOUNDS);
    }

    // sum_f64 is a finite non-zero number
    {
        double sum = nxs_sum_f64(&r, "score");
        CHECK("sum_f64(score) is finite", isfinite(sum) && sum != 0.0);
    }

    // sum_i64 is positive
    {
        int64_t s = nxs_sum_i64(&r, "id");
        CHECK("sum_i64(id) is positive", s > 0);
    }

    // min <= max
    {
        double mn = 0.0, mx = 0.0;
        nxs_min_f64(&r, "score", &mn);
        nxs_max_f64(&r, "score", &mx);
        CHECK("min_f64 <= max_f64", mn <= mx);
    }

    nxs_close(&r);

    // ── Security tests ────────────────────────────────────────────────────────
    {
        uint8_t *bad = malloc(nxb_size);
        memcpy(bad, nxb_data, nxb_size);
        bad[0] = 0x00;
        nxs_reader_t r2;
        nxs_err_t e = nxs_open(&r2, bad, nxb_size);
        CHECK("bad magic returns ERR_BAD_MAGIC", e == NXS_ERR_BAD_MAGIC);
        free(bad);
    }

    {
        uint8_t tiny[16] = {0x4E,0x58,0x53,0x42,0x00,0x01,0x00,0x00,
                            0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00};
        nxs_reader_t r2;
        nxs_err_t e = nxs_open(&r2, tiny, sizeof(tiny));
        CHECK("truncated file returns error", e != NXS_OK);
    }

    {
        uint8_t *bad = malloc(nxb_size);
        memcpy(bad, nxb_data, nxb_size);
        bad[8] ^= 0xFF;
        nxs_reader_t r2;
        nxs_err_t e = nxs_open(&r2, bad, nxb_size);
        CHECK("corrupt DictHash returns ERR_DICT_MISMATCH", e == NXS_ERR_DICT_MISMATCH);
        free(bad);
    }

    free(nxb_data);

    printf("\n%d passed, %d failed\n\n", passed, failed);
    return failed > 0 ? 1 : 0;
}
