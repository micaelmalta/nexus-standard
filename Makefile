# NXS — lint, fix, and test all ten language implementations.
#
# Usage:
#   make lint      # check all linters (exit 1 on any hard failure)
#   make fix       # auto-fix all fixable issues
#   make test      # run all language test suites
#   make all       # fix + test

.PHONY: all lint fix test \
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
JAVA_HOME   ?= /opt/homebrew/opt/openjdk

# ── Top-level ─────────────────────────────────────────────────────────────────

all: fix test

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
	export JAVA_HOME=$(JAVA_HOME) && export PATH=$(JAVA_HOME)/bin:$$PATH && \
	cd kotlin && ./gradlew run --args="../$(FIXTURE_DIR)" -q

# ── C# ────────────────────────────────────────────────────────────────────────

lint-csharp:
	cd csharp && dotnet format -p:NxsTargetFramework=net9.0 --verify-no-changes --severity warn || true

fix-csharp:
	cd csharp && dotnet format -p:NxsTargetFramework=net9.0 || true

test-csharp:
	cd csharp && dotnet run -- ../$(FIXTURE_DIR)
