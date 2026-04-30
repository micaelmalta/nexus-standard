package nxs

import (
	"encoding/json"
	"math"
	"strings"
	"os"
	"path/filepath"
	"testing"
)

const fixtureDir = "../js/fixtures"

type record struct {
	ID       int64   `json:"id"`
	Username string  `json:"username"`
	Email    string  `json:"email"`
	Age      int64   `json:"age"`
	Balance  float64 `json:"balance"`
	Active   bool    `json:"active"`
	Score    float64 `json:"score"`
}

func loadFixtures(t *testing.T, n int) ([]byte, []record) {
	t.Helper()
	nxb, err := os.ReadFile(filepath.Join(fixtureDir, fmtRecordsNxb(n)))
	if err != nil {
		t.Skipf("nxb fixture missing: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(fixtureDir, fmtRecordsJson(n)))
	if err != nil {
		t.Skipf("json fixture missing: %v", err)
	}
	var recs []record
	if err := json.Unmarshal(raw, &recs); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return nxb, recs
}

func fmtRecordsNxb(n int) string { return "records_" + itoa(n) + ".nxb" }
func fmtRecordsJson(n int) string { return "records_" + itoa(n) + ".json" }

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	pos := len(buf)
	for n > 0 {
		pos--
		buf[pos] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		pos--
		buf[pos] = '-'
	}
	return string(buf[pos:])
}

func TestReaderOpens(t *testing.T) {
	nxb, _ := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	if r.RecordCount() != 1000 {
		t.Errorf("record count = %d, want 1000", r.RecordCount())
	}
}

func TestSchemaKeys(t *testing.T) {
	nxb, _ := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"id", "username", "email", "age", "score", "active"} {
		found := false
		for _, k := range r.Keys {
			if k == want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("missing key %q (got %v)", want, r.Keys)
		}
	}
}

func TestRecordsMatchJSON(t *testing.T) {
	nxb, js := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	for _, i := range []int{0, 7, 42, 500, 999} {
		o := r.Record(i)
		if got, _ := o.GetI64("id"); got != js[i].ID {
			t.Errorf("record %d id=%d want %d", i, got, js[i].ID)
		}
		if got, _ := o.GetStr("username"); got != js[i].Username {
			t.Errorf("record %d username=%q want %q", i, got, js[i].Username)
		}
		if got, _ := o.GetF64("score"); !closeEnough(got, js[i].Score) {
			t.Errorf("record %d score=%v want %v", i, got, js[i].Score)
		}
		if got, _ := o.GetBool("active"); got != js[i].Active {
			t.Errorf("record %d active=%v want %v", i, got, js[i].Active)
		}
	}
}

func TestSumF64(t *testing.T) {
	nxb, js := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	var want float64
	for _, x := range js {
		want += x.Score
	}
	if got := r.SumF64("score"); !closeEnough(got, want) {
		t.Errorf("sum = %v, want %v", got, want)
	}
}

func TestSumI64(t *testing.T) {
	nxb, js := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	var want int64
	for _, x := range js {
		want += x.Age
	}
	if got := r.SumI64("age"); got != want {
		t.Errorf("sum = %v, want %v", got, want)
	}
}

func TestMinMaxF64(t *testing.T) {
	nxb, js := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	wantMin, wantMax := math.Inf(1), math.Inf(-1)
	for _, x := range js {
		if x.Score < wantMin {
			wantMin = x.Score
		}
		if x.Score > wantMax {
			wantMax = x.Score
		}
	}
	if m, ok := r.MinF64("score"); !ok || !closeEnough(m, wantMin) {
		t.Errorf("min = %v, want %v", m, wantMin)
	}
	if m, ok := r.MaxF64("score"); !ok || !closeEnough(m, wantMax) {
		t.Errorf("max = %v, want %v", m, wantMax)
	}
}

func closeEnough(a, b float64) bool {
	return math.Abs(a-b) < 1e-6
}

func TestBadMagic(t *testing.T) {
	nxb, _ := loadFixtures(t, 1000)
	bad := append([]byte{}, nxb...)
	bad[0] = 0x00
	_, err := NewReader(bad)
	if err == nil || !strings.Contains(err.Error(), "ERR_BAD_MAGIC") {
		t.Errorf("expected ERR_BAD_MAGIC, got %v", err)
	}
}

func TestTruncatedFile(t *testing.T) {
	_, err := NewReader([]byte{0x4E, 0x58, 0x53, 0x42, 0x00, 0x01})
	if err == nil {
		t.Error("expected error on truncated file")
	}
}

func TestDictHashMismatch(t *testing.T) {
	nxb, _ := loadFixtures(t, 1000)
	bad := append([]byte{}, nxb...)
	bad[8] ^= 0xFF
	_, err := NewReader(bad)
	if err == nil || !strings.Contains(err.Error(), "ERR_DICT_MISMATCH") {
		t.Errorf("expected ERR_DICT_MISMATCH, got %v", err)
	}
}

func TestIsUniform(t *testing.T) {
	nxb, _ := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	if !r.IsUniform() {
		t.Error("fixture should be uniform across all records")
	}
}

func TestSumF64FastMatchesSafe(t *testing.T) {
	nxb, js := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	var want float64
	for _, x := range js {
		want += x.Score
	}
	fast := r.SumF64Fast("score")
	safe := r.SumF64("score")
	if !closeEnough(fast, safe) {
		t.Errorf("fast=%v safe=%v", fast, safe)
	}
	if !closeEnough(fast, want) {
		t.Errorf("fast=%v want=%v", fast, want)
	}
}

func TestSumI64FastMatchesSafe(t *testing.T) {
	nxb, js := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	var want int64
	for _, x := range js {
		want += x.Age
	}
	if got := r.SumI64Fast("age"); got != want {
		t.Errorf("SumI64Fast = %d want %d", got, want)
	}
}

func TestSumF64FastParMatchesSerial(t *testing.T) {
	nxb, _ := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	serial := r.SumF64Fast("score")
	for _, w := range []int{1, 2, 4, 8} {
		par := r.SumF64FastPar("score", w)
		if !closeEnough(par, serial) {
			t.Errorf("workers=%d par=%v serial=%v", w, par, serial)
		}
	}
}

func TestSumI64FastParMatchesSerial(t *testing.T) {
	nxb, _ := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	serial := r.SumI64Fast("age")
	for _, w := range []int{1, 2, 4, 8} {
		par := r.SumI64FastPar("age", w)
		if par != serial {
			t.Errorf("workers=%d par=%v serial=%v", w, par, serial)
		}
	}
}

func TestMinMaxF64Fast(t *testing.T) {
	nxb, js := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil {
		t.Fatal(err)
	}
	wantMin, wantMax := math.Inf(1), math.Inf(-1)
	for _, x := range js {
		if x.Score < wantMin {
			wantMin = x.Score
		}
		if x.Score > wantMax {
			wantMax = x.Score
		}
	}
	if m, ok := r.MinF64Fast("score"); !ok || !closeEnough(m, wantMin) {
		t.Errorf("MinF64Fast = %v want %v", m, wantMin)
	}
	if m, ok := r.MaxF64Fast("score"); !ok || !closeEnough(m, wantMax) {
		t.Errorf("MaxF64Fast = %v want %v", m, wantMax)
	}
}

func TestFieldIndexMatchesFast(t *testing.T) {
	nxb, _ := loadFixtures(t, 1000)
	r, err := NewReader(nxb)
	if err != nil { t.Fatal(err) }

	fast := r.SumF64Fast("score")
	idx, ok := r.BuildFieldIndex("score")
	if !ok { t.Fatal("BuildFieldIndex failed") }
	indexed := r.SumF64Indexed(idx)
	if !closeEnough(fast, indexed) {
		t.Errorf("SumF64Indexed=%v SumF64Fast=%v", indexed, fast)
	}

	mn, _ := r.MinF64Indexed(idx)
	mx, _ := r.MaxF64Indexed(idx)
	mnFast, _ := r.MinF64Fast("score")
	mxFast, _ := r.MaxF64Fast("score")
	if !closeEnough(mn, mnFast) { t.Errorf("min mismatch") }
	if !closeEnough(mx, mxFast) { t.Errorf("max mismatch") }
}
