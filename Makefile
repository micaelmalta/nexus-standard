# NXS — lint, fix, test, conformance, and fuzz for all ten language implementations.
#
# Usage:
#   make lint           # strict: every step must pass (no swallowed failures)
#   make fix            # auto-fix all fixable issues
#   make test           # run all language test suites (needs fixtures: make fixtures)
#   make fixtures       # generate js/fixtures (FIXTURE_COUNT=1000 default)
#   make test-py-ci     # Python + C extension parity (matches CI)
#   make test-ruby-ci   # Ruby + C extension smoke (matches CI)
#   make test-php-ci    # PHP + C extension tests (matches CI)
#   make test-rust-ci   # Rust tests + compile examples/ (matches CI)
#   make conformance    # generate vectors + run all conformance runners
#   make conformance-run-js  # … single runner (see Makefile)
#   make fuzz           # run cargo-fuzz for 60s (requires nightly)
#   make all            # fix + test + conformance
#   make install-git-hooks   # pre-commit → make lint (SKIP_HOOKS=1 to bypass once)

.PHONY: all lint fix test conformance fuzz fixtures rust-examples install-git-hooks \
        lint-rust  fix-rust  test-rust \
        lint-js    fix-js    test-js \
        lint-py    fix-py    test-py \
        lint-go    fix-go    test-go \
        lint-ruby  fix-ruby  test-ruby \
        lint-php   fix-php   test-php \
        lint-c     fix-c     test-c \
        lint-swift fix-swift test-swift \
        lint-kotlin           test-kotlin \
        lint-csharp fix-csharp test-csharp \
        test-rust-ci test-py-ci test-ruby-ci test-php-ci \
        conformance-run conformance-run-js conformance-run-py conformance-run-go \
        conformance-run-ruby conformance-run-php conformance-run-c conformance-run-swift \
        conformance-run-kotlin conformance-run-csharp conformance-run-rust

FIXTURE_DIR     := js/fixtures
FIXTURE_COUNT   ?= 1000
JAVA_HOME       ?= /opt/homebrew/opt/openjdk@21
# Default to net10 so `make conformance-run` works with a single current SDK; CI sets net9 where needed.
DOTNET_FRAMEWORK ?= net10.0

# ── Top-level ─────────────────────────────────────────────────────────────────

all: fix test conformance

install-git-hooks:
	git config core.hooksPath .githooks
	@echo "Git hooks path set to .githooks (pre-commit runs: make lint). Bypass once: SKIP_HOOKS=1 git commit …"

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

rust-examples:
	cd rust && cargo build --release --bin nxs
	cd rust && for f in ../examples/*.nxs; do ./target/release/nxs "$$f" && echo "compiled $$f"; done

test-rust-ci: test-rust rust-examples

# Best-effort: repo checkouts or docker-created trees may lack u+w on js/fixtures.
fixtures:
	@chmod -R u+w $(FIXTURE_DIR) 2>/dev/null || true
	cd rust && cargo run --release --bin gen_fixtures -- ../$(FIXTURE_DIR) $(FIXTURE_COUNT)

# ── JavaScript ───────────────────────────────────────────────────────────────

lint-js:
	cd js && npm install --ignore-scripts --no-fund --no-audit
	cd js && npm run lint

fix-js:
	cd js && npm install --ignore-scripts --no-fund --no-audit
	cd js && npx eslint --fix --max-warnings 0 nxs.js nxs_writer.js wasm.js bench.js test.js

test-js:
	node js/test.js $(FIXTURE_DIR)

# ── Python ───────────────────────────────────────────────────────────────────

lint-py:
	@command -v ruff >/dev/null 2>&1 || python3 -m pip install --user ruff
	cd py && ruff check --select E,W,F --ignore E501,E701,E702 .

fix-py:
	@command -v ruff >/dev/null 2>&1 || python3 -m pip install --user ruff
	cd py && ruff check --select E,W,F --ignore E501,E701,E702 --fix .

test-py:
	cd py && python test_nxs.py ../$(FIXTURE_DIR)

test-py-ci: test-py
	cd py && bash build_ext.sh
	cd py && python test_c_ext.py ../$(FIXTURE_DIR)

# ── Go ────────────────────────────────────────────────────────────────────────

lint-go:
	@cd go && { fmt=$$(gofmt -l .); [ -z "$$fmt" ] || { printf 'run gofmt -w on:\n%s\n' "$$fmt"; exit 1; }; }
	cd go && go vet ./...
	@PATH="$$PATH:$$(go env GOPATH)/bin"; \
	  command -v staticcheck >/dev/null 2>&1 || go install honnef.co/go/tools/cmd/staticcheck@latest; \
	  cd go && staticcheck ./...

fix-go:
	cd go && gofmt -w .

test-go:
	cd go && go test ./...

# ── Ruby ─────────────────────────────────────────────────────────────────────

lint-ruby:
	@command -v rubocop >/dev/null 2>&1 || gem install rubocop --no-document
	rubocop ruby/nxs.rb ruby/test.rb ruby/bench.rb --config ruby/.rubocop.yml --no-color --cache false

fix-ruby:
	@command -v rubocop >/dev/null 2>&1 || gem install rubocop --no-document
	rubocop ruby/nxs.rb ruby/test.rb ruby/bench.rb --config ruby/.rubocop.yml --no-color --cache false -A

test-ruby:
	ruby ruby/test.rb $(FIXTURE_DIR)

test-ruby-ci: test-ruby
	bash ruby/ext/build.sh
	ruby ruby/bench_c.rb $(FIXTURE_DIR)

# ── PHP ───────────────────────────────────────────────────────────────────────

lint-php:
	@command -v composer >/dev/null 2>&1 || { echo "Install Composer: https://getcomposer.org/" >&2; exit 1; }
	cd php && composer install --no-interaction --prefer-dist --no-progress
	cd php && ./vendor/bin/phpstan analyse Nxs.php --level=5 --no-progress

fix-php: lint-php

test-php:
	php php/test.php $(FIXTURE_DIR)

test-php-ci: test-php
	bash php/nxs_ext/build.sh
	php -d extension=php/nxs_ext/modules/nxs.so php/test.php $(FIXTURE_DIR)

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
	cd swift && swiftlint lint --strict --cache-path .swiftlint-cache Sources/NXS

fix-swift:
	@command -v swiftlint >/dev/null 2>&1 || brew install swiftlint
	cd swift && swiftlint --fix --strict --cache-path .swiftlint-cache Sources/NXS

test-swift:
	cd swift && swift run nxs-test ../$(FIXTURE_DIR)

# ── Kotlin ───────────────────────────────────────────────────────────────────

lint-kotlin:
	cd kotlin && JAVA_HOME=$(JAVA_HOME) PATH="$(JAVA_HOME)/bin:$$PATH" ./gradlew ktlintCheck -q

test-kotlin:
	cd kotlin && JAVA_HOME=$(JAVA_HOME) PATH=$(JAVA_HOME)/bin:$$PATH ./gradlew run --args="../$(FIXTURE_DIR)" -q

# ── C# ────────────────────────────────────────────────────────────────────────

lint-csharp:
	cd csharp && DOTNET_FRAMEWORK=$(DOTNET_FRAMEWORK) dotnet format nxs.csproj --verify-no-changes --severity warn

fix-csharp:
	cd csharp && DOTNET_FRAMEWORK=$(DOTNET_FRAMEWORK) dotnet format nxs.csproj

test-csharp:
	cd csharp && dotnet run -p:NxsTargetFramework=$(DOTNET_FRAMEWORK) -- ../$(FIXTURE_DIR)

# ── Conformance suite ─────────────────────────────────────────────────────────
# Generates canonical .nxb/.expected.json vectors, then runs all 10 language
# runners against them. Requires fixtures to be generated first.

conformance: conformance-generate conformance-run

conformance-generate:
	@echo "Generating conformance vectors..."
	cd rust && cargo run --release --bin gen_conformance -- ../conformance
	@echo "Vectors written to conformance/"

conformance-run-js:
	node conformance/run_js.js conformance/

conformance-run-py:
	python3 conformance/run_py.py conformance/

conformance-run-go:
	cd go && go run ../conformance/run_go.go ../conformance/

conformance-run-ruby:
	ruby conformance/run_ruby.rb conformance/

conformance-run-php:
	php conformance/run_php.php conformance/

conformance-run-c:
	cc -std=c99 -O2 -Ic/ c/nxs.c conformance/run_c.c -o /tmp/run_c_conf -lm -Wno-format-truncation -Wno-unused-result && /tmp/run_c_conf conformance/

conformance-run-swift:
	cd swift && swift run nxs-conformance ../conformance/

conformance-run-kotlin:
	cd kotlin && JAVA_HOME=$(JAVA_HOME) PATH="$(JAVA_HOME)/bin:$$PATH" ./gradlew conformance -q

conformance-run-csharp:
	cd csharp && dotnet run -p:NxsTargetFramework=$(DOTNET_FRAMEWORK) -- --conformance ../conformance/

conformance-run-rust:
	cd rust && cargo run --release --bin conformance_runner -- ../conformance/

conformance-run: conformance-run-js conformance-run-py conformance-run-go conformance-run-ruby conformance-run-php conformance-run-c conformance-run-swift conformance-run-kotlin conformance-run-csharp conformance-run-rust
	@echo "✅  Conformance: all runners finished."

# ── Fuzz ─────────────────────────────────────────────────────────────────────
# Requires Rust nightly: rustup install nightly
# Run for FUZZ_TIME seconds (default 60).

FUZZ_TIME ?= 60

fuzz:
	@echo "Fuzzing for $(FUZZ_TIME)s (requires nightly)..."
	cd rust && cargo +nightly fuzz run fuzz_decode -- -max_total_time=$(FUZZ_TIME) -rss_limit_mb=0 -max_len=8192
	cd rust && cargo +nightly fuzz run fuzz_writer_roundtrip -- -max_total_time=$(FUZZ_TIME) -rss_limit_mb=0 -max_len=4096
	@echo "✅  Fuzz complete — no crashes found."
