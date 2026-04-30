# NXS — lint, fix, test, conformance, and fuzz for all ten language implementations.
#
# Usage:
#   make lint        # check all linters (exit 1 on hard failures)
#   make fix         # auto-fix all fixable issues
#   make test        # run all language test suites
#   make conformance # run the conformance suite against all runners
#   make fuzz        # run cargo-fuzz for 60s (requires nightly)
#   make all         # fix + test + conformance

.PHONY: all lint fix test conformance fuzz \
        lint-rust  fix-rust  test-rust \
        lint-js    fix-js    test-js \
        lint-py    fix-py    test-py \
        lint-go    fix-go    test-go \
        lint-ruby  fix-ruby  test-ruby \
        lint-php   fix-php   test-php \
        lint-c     fix-c     test-c \
        lint-swift fix-swift test-swift \
        lint-kotlin           test-kotlin \
        lint-csharp fix-csharp test-csharp

FIXTURE_DIR := js/fixtures
JAVA_HOME   ?= /opt/homebrew/opt/openjdk@21

# ── Top-level ─────────────────────────────────────────────────────────────────

all: fix test conformance

lint: lint-rust lint-js lint-py lint-go lint-ruby lint-php lint-c lint-swift lint-kotlin lint-csharp

fix: fix-rust fix-js fix-py fix-go fix-ruby fix-php fix-c fix-swift fix-csharp
	@echo "\n✅  All auto-fixes applied."

test: test-rust test-js test-py test-go test-ruby test-php test-c test-swift test-kotlin test-csharp
	@echo "\n✅  All tests passed."

# ── Rust ──────────────────────────────────────────────────────────────────────

lint-rust:
	cd rust && cargo fmt --check && cargo clippy --lib --bin nxs --bin bench --bin gen_fixtures -- -D warnings -A dead_code -A unused_imports -A clippy::empty_line_after_doc_comments -A clippy::collapsible_if -A clippy::single_match -A clippy::manual_is_multiple_of -A clippy::manual_div_ceil -A clippy::same_item_push -A clippy::new_without_default -A clippy::len_without_is_empty

fix-rust:
	cd rust && cargo fmt
	cargo fmt -- conformance/generate.rs conformance/run_rust.rs 2>/dev/null || true

test-rust:
	cd rust && cargo test --release

# ── JavaScript ───────────────────────────────────────────────────────────────

lint-js:
	@command -v eslint >/dev/null 2>&1 || npm install -g eslint
	cd js && eslint --rule '{"no-undef":"warn","no-unused-vars":"warn"}' \
	  nxs.js nxs_writer.js wasm.js bench.js test.js || true

fix-js: lint-js

test-js:
	node js/test.js $(FIXTURE_DIR)

# ── Python ───────────────────────────────────────────────────────────────────

lint-py:
	@command -v ruff >/dev/null 2>&1 || brew install ruff
	cd py && ruff check --select E,W,F --ignore E501,E701,E702 .

fix-py:
	@command -v ruff >/dev/null 2>&1 || brew install ruff
	cd py && ruff check --select E,W,F --ignore E501,E701,E702 --fix .

test-py:
	cd py && python test_nxs.py ../$(FIXTURE_DIR)

# ── Go ────────────────────────────────────────────────────────────────────────

lint-go:
	cd go && gofmt -l . | grep . && exit 1 || true
	cd go && go vet ./...

fix-go:
	cd go && gofmt -w .

test-go:
	cd go && go test ./...

# ── Ruby ─────────────────────────────────────────────────────────────────────

lint-ruby:
	@command -v rubocop >/dev/null 2>&1 || gem install rubocop --no-document
	rubocop ruby/nxs.rb ruby/test.rb ruby/bench.rb --no-color || true

fix-ruby:
	@command -v rubocop >/dev/null 2>&1 || gem install rubocop --no-document
	rubocop ruby/nxs.rb ruby/test.rb ruby/bench.rb --no-color -A || true

test-ruby:
	ruby ruby/test.rb $(FIXTURE_DIR)

# ── PHP ───────────────────────────────────────────────────────────────────────

lint-php:
	@command -v phpstan >/dev/null 2>&1 || (echo "Install phpstan: composer global require phpstan/phpstan" && true)
	phpstan analyse php/Nxs.php --level=5 --no-progress || true

fix-php: lint-php

test-php:
	php php/test.php $(FIXTURE_DIR)

# ── C ─────────────────────────────────────────────────────────────────────────

lint-c:
	@command -v cppcheck >/dev/null 2>&1 || brew install cppcheck
	cppcheck --error-exitcode=1 --suppress=missingIncludeSystem c/nxs.c c/nxs.h

fix-c: lint-c

test-c:
	cd c && make test -s && ./test ../$(FIXTURE_DIR)

# ── Swift ─────────────────────────────────────────────────────────────────────

lint-swift:
	@command -v swiftlint >/dev/null 2>&1 || brew install swiftlint
	swiftlint lint swift/Sources/NXS/ || true

fix-swift:
	@command -v swiftlint >/dev/null 2>&1 || brew install swiftlint
	swiftlint --fix swift/Sources/NXS/ || true

test-swift:
	cd swift && swift run nxs-test ../$(FIXTURE_DIR)

# ── Kotlin ───────────────────────────────────────────────────────────────────

lint-kotlin:
	@command -v ktlint >/dev/null 2>&1 || brew install ktlint
	ktlint kotlin/src/**/*.kt || true

test-kotlin:
	cd kotlin && JAVA_HOME=$(JAVA_HOME) PATH=$(JAVA_HOME)/bin:$$PATH ./gradlew run --args="../$(FIXTURE_DIR)" -q

# ── C# ────────────────────────────────────────────────────────────────────────

lint-csharp:
	cd csharp && dotnet format -p:NxsTargetFramework=net9.0 --verify-no-changes --severity warn || true

fix-csharp:
	cd csharp && dotnet format -p:NxsTargetFramework=net9.0 || true

test-csharp:
	cd csharp && dotnet run -- ../$(FIXTURE_DIR)

# ── Conformance suite ─────────────────────────────────────────────────────────
# Generates canonical .nxb/.expected.json vectors, then runs all 10 language
# runners against them. Requires fixtures to be generated first.

conformance: conformance-generate conformance-run

conformance-generate:
	@echo "Generating conformance vectors..."
	cd rust && cargo run --release --bin gen_conformance 2>/dev/null || \
	  cargo run --release --bin gen_conformance
	@echo "Vectors written to conformance/"

conformance-run:
	@echo "Running conformance suite..."
	@PASS=0; FAIL=0; \
	run_conf() { \
	  printf "  %-10s " "$$1"; \
	  if eval "$$2" > /tmp/nxs_conf_$$1.out 2>&1; then \
	    echo "✓  $$(tail -1 /tmp/nxs_conf_$$1.out)"; PASS=$$((PASS+1)); \
	  else \
	    echo "✗  FAILED"; tail -5 /tmp/nxs_conf_$$1.out; FAIL=$$((FAIL+1)); \
	  fi; \
	}; \
	run_conf js     "node conformance/run_js.js conformance/"; \
	run_conf py     "python conformance/run_py.py conformance/"; \
	run_conf go     "(cd go && go run ../conformance/run_go.go ../conformance/)"; \
	run_conf ruby   "ruby conformance/run_ruby.rb conformance/"; \
	run_conf php    "php conformance/run_php.php conformance/"; \
	run_conf c      "cc -std=c99 -O2 -Ic/ c/nxs.c conformance/run_c.c -o /tmp/run_c_conf -lm -Wno-format-truncation -Wno-unused-result && /tmp/run_c_conf conformance/"; \
	run_conf swift  "(cd swift && swift run nxs-conformance ../conformance/)"; \
	run_conf kotlin "(cd kotlin && JAVA_HOME=$(JAVA_HOME) PATH=$(JAVA_HOME)/bin:$$PATH ./gradlew run --args='--conformance ../conformance/' -q)"; \
	run_conf csharp "(cd csharp && dotnet run -- --conformance ../conformance/)"; \
	run_conf rust   "(cd rust && cargo run --release --bin conformance_runner -- ../conformance/)"; \
	echo ""; \
	if [ $$FAIL -eq 0 ]; then echo "✅  Conformance: $$PASS/10 passed."; else echo "❌  Conformance: $$FAIL failed, $$PASS passed."; exit 1; fi

# ── Fuzz ─────────────────────────────────────────────────────────────────────
# Requires Rust nightly: rustup install nightly
# Run for FUZZ_TIME seconds (default 60).

FUZZ_TIME ?= 60

fuzz:
	@echo "Fuzzing for $(FUZZ_TIME)s (requires nightly)..."
	cd rust && cargo +nightly fuzz run fuzz_decode -- -max_total_time=$(FUZZ_TIME) -rss_limit_mb=0 -max_len=8192
	cd rust && cargo +nightly fuzz run fuzz_writer_roundtrip -- -max_total_time=$(FUZZ_TIME) -rss_limit_mb=0 -max_len=4096
	@echo "✅  Fuzz complete — no crashes found."
