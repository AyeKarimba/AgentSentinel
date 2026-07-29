.PHONY: install uninstall app build test check run clean help

help:
	@echo "TerminalNavigator"
	@echo
	@echo "  make install     build, install to /Applications, register hooks, start at login"
	@echo "  make uninstall   remove the app, the login item and the hooks"
	@echo "  make app         build TerminalNavigator.app into ./build, without installing"
	@echo "  make test        unit tests"
	@echo "  make check       unit tests + the hook integration test"
	@echo "  make run         run from source, without installing (development)"
	@echo "  make clean       remove build artefacts"

# ARGS is passed straight through, e.g. `make install ARGS=--no-login`
ARGS ?=

install:
	@./scripts/install.sh $(ARGS)

uninstall:
	@./scripts/uninstall.sh $(ARGS)

app:
	@./scripts/make-app.sh

build:
	swift build -c release

# Against a scratch state directory: some library code writes to the event log, and unit tests
# have no business appending to the user's real ~/.claude/tnav.
test:
	TNAV_STATE_DIR="$$(mktemp -d)" swift test

check: test
	@./scripts/integration-test.sh

# Development: run the menu bar app straight from .build. Note that macOS ties Accessibility
# permission to a binary's signature, so a rebuild here drops the grant and cross-desktop
# jumps quietly stop working — `make install` is the one that behaves consistently.
run:
	swift build
	@pkill -f "\.build/.*/TerminalNavigatorApp" 2>/dev/null || true
	@./.build/debug/TerminalNavigatorApp &
	@echo "running from .build — see the menu bar"

clean:
	swift package clean
	rm -rf build
