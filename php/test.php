<?php
/**
 * NXS PHP parity tests — validates the PHP reader against the 1000-record JSON fixture.
 *
 * Usage (from project root):
 *   php php/test.php js/fixtures
 */

declare(strict_types=1);

require __DIR__ . '/Nxs.php';

// ── Helpers ──────────────────────────────────────────────────────────────────

$pass = 0;
$fail = 0;

function check(string $label, bool $ok, string $detail = ''): void
{
    global $pass, $fail;
    if ($ok) {
        echo "  \u{2713} $label\n";
        $pass++;
    } else {
        echo "  \u{2717} $label" . ($detail ? " — $detail" : '') . "\n";
        $fail++;
    }
}

// ── Fixtures ─────────────────────────────────────────────────────────────────

$dir = $argv[1] ?? (__DIR__ . '/../js/fixtures');
$dir = rtrim($dir, '/');

$nxbPath  = "$dir/records_1000.nxb";
$jsonPath = "$dir/records_1000.json";

if (!file_exists($nxbPath)) {
    fwrite(STDERR, "ERROR: cannot find $nxbPath\n");
    exit(1);
}
if (!file_exists($jsonPath)) {
    fwrite(STDERR, "ERROR: cannot find $jsonPath\n");
    exit(1);
}

$nxbBytes = file_get_contents($nxbPath);
$json     = json_decode(file_get_contents($jsonPath), true, 512, JSON_THROW_ON_ERROR);

echo "\nNXS PHP Reader — parity tests against records_1000\n";
echo str_repeat('─', 56) . "\n";

// ── Reader construction ───────────────────────────────────────────────────────

try {
    $reader = new Nxs\Reader($nxbBytes);
    check('Reader construction succeeds', true);
} catch (\Throwable $e) {
    check('Reader construction succeeds', false, $e->getMessage());
    exit(1);
}

// ── Test 1: recordCount ────────────────────────────────────────────────────────

check('recordCount() === 1000', $reader->recordCount() === 1000,
    'got ' . $reader->recordCount());

// ── Test 2: keys() contains "username" ────────────────────────────────────────

check('keys() contains "username"', in_array('username', $reader->keys(), true));

// ── Test 3: record(42)->getStr("username") matches JSON ───────────────────────

$got42 = $reader->record(42)->getStr('username');
$exp42 = (string)$json[42]['username'];
check(
    'record(42)->getStr("username") matches JSON',
    $got42 === $exp42,
    "got=$got42, expected=$exp42"
);

// ── Test 4: record(500)->getF64("score") matches JSON (6 dp) ──────────────────

$gotScore = $reader->record(500)->getF64('score');
$expScore = (float)$json[500]['score'];
check(
    'record(500)->getF64("score") ≈ json[500].score',
    round((float)$gotScore, 6) === round($expScore, 6),
    "got=$gotScore, expected=$expScore"
);

// ── Test 5: record(999)->getBool("active") matches JSON ───────────────────────

$gotBool = $reader->record(999)->getBool('active');
$expBool = (bool)$json[999]['active'];
check(
    'record(999)->getBool("active") matches JSON',
    $gotBool === $expBool,
    'got=' . var_export($gotBool, true) . ', expected=' . var_export($expBool, true)
);

// ── Test 6: sumF64("score") matches JSON sum (4 dp) ───────────────────────────

$gotSum = $reader->sumF64('score');
$expSum = (float)array_sum(array_column($json, 'score'));
check(
    'sumF64("score") ≈ array_sum(json[*].score) [4 dp]',
    round($gotSum, 4) === round($expSum, 4),
    "got=$gotSum, expected=$expSum"
);

// ── Test 7: Out-of-bounds throws NxsException ─────────────────────────────────

try {
    $reader->record(1000);
    check('record(1000) throws NxsException', false, 'no exception thrown');
} catch (Nxs\NxsException $e) {
    check('record(1000) throws NxsException', true);
} catch (\Throwable $e) {
    check('record(1000) throws NxsException', false, get_class($e) . ': ' . $e->getMessage());
}

// ── Test 8: record(0)->getI64("id") matches JSON ─────────────────────────────

$gotId = $reader->record(0)->getI64('id');
$expId = (int)$json[0]['id'];
check(
    'record(0)->getI64("id") matches JSON',
    $gotId === $expId,
    "got=$gotId, expected=$expId"
);

// ── Test 9: record(1)->getBool("active") === true ─────────────────────────────

$gotActive1 = $reader->record(1)->getBool('active');
$expActive1 = (bool)$json[1]['active'];
check(
    'record(1)->getBool("active") matches JSON (true)',
    $gotActive1 === $expActive1,
    'got=' . var_export($gotActive1, true) . ', expected=' . var_export($expActive1, true)
);

// ── Test 10: record(1)->getF64("balance") ≈ json[1].balance ──────────────────

$gotBal1 = $reader->record(1)->getF64('balance');
$expBal1 = (float)$json[1]['balance'];
check(
    'record(1)->getF64("balance") ≈ json[1].balance [6 dp]',
    round((float)$gotBal1, 6) === round($expBal1, 6),
    "got=$gotBal1, expected=$expBal1"
);

// ── Security tests ───────────────────────────────────────────────────────────

$badMagic = $nxbBytes;
$badMagic[0] = "\x00";
try {
    new Nxs\Reader($badMagic);
    check('bad magic throws ERR_BAD_MAGIC', false, 'no exception');
} catch (Nxs\NxsException $e) {
    check('bad magic throws ERR_BAD_MAGIC', str_contains($e->getMessage(), 'ERR_BAD_MAGIC'), $e->getMessage());
}

try {
    new Nxs\Reader(substr($nxbBytes, 0, 16));
    check('truncated file throws NxsException', false, 'no exception');
} catch (Nxs\NxsException $e) {
    check('truncated file throws NxsException', true);
}

$badHash = $nxbBytes;
$badHash[8] = chr(ord($badHash[8]) ^ 0xFF);
try {
    new Nxs\Reader($badHash);
    check('corrupt DictHash throws ERR_DICT_MISMATCH', false, 'no exception');
} catch (Nxs\NxsException $e) {
    check('corrupt DictHash throws ERR_DICT_MISMATCH', str_contains($e->getMessage(), 'ERR_DICT_MISMATCH'), $e->getMessage());
}

// ── Summary ───────────────────────────────────────────────────────────────────

echo str_repeat('─', 56) . "\n";
$total = $pass + $fail;
if ($fail === 0) {
    echo "  All $pass/$total tests passed.\n\n";
    exit(0);
} else {
    echo "  $pass/$total passed, $fail FAILED.\n\n";
    exit(1);
}
