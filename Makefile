# Signing identity of a dev build, first that applies: SIGN given on the command line or in the environment (any identity
# in your keychain, by name or SHA-1), the local identity that scripts/local-signing.sh made (its SHA-1, so a name clash
# cannot pick the wrong certificate), else ad-hoc. `make bundle SIGN=-` forces ad-hoc. Releases never use this: scripts/release.sh.
SIGN ?= $(or $(shell scripts/local-signing.sh identity 2>/dev/null),-)
ADHOC_NOTE = no stable signing identity, using ad-hoc: $(ADHOC_HINT)
ADHOC_HINT := the Accessibility switch must be redone after every rebuild; scripts/local-signing.sh create makes a stable identity (INSTALL.md, Signing)
APP  := build/Ribbon.app

# The edition. plus: the paid edition (core built with --features plus, app built with -DRIBBON_PLUS). free: the open-source one.
# Where this checkout carries the Plus code (core/src/plus) it is plus, else free, so the public repo, which is exported
# without that code, builds free with no arguments. `make EDITION=free ...` / `make EDITION=plus ...` choose one.
# Each edition has its own cargo target dir and its own SwiftPM scratch path, so switching never links the other edition's
# core and never rebuilds the other one; the app also refuses a core of the other edition (--selftest fails, see Edition.swift).
EDITION ?= $(if $(wildcard core/src/plus),plus,free)
ifeq ($(filter plus free,$(EDITION)),)
$(error EDITION must be plus or free, not '$(EDITION)')
endif
CORE_TARGET   := core/target/$(EDITION)
CORE_LIB      := $(CORE_TARGET)/release
CORE_A        := $(CORE_LIB)/libribbon_core.a
CORE_FEATURES := $(if $(filter plus,$(EDITION)),--features plus)
SWIFT_SCRATCH := app/.build/$(EDITION)
SWIFT_EDITION := $(if $(filter plus,$(EDITION)),-Xswiftc -DRIBBON_PLUS)
BIN   := $(SWIFT_SCRATCH)/release/Ribbon
DUMMY := $(SWIFT_SCRATCH)/release/RibbonDummy

# Only the release script sets these (":=" so a stray environment variable cannot).
# A build without FEED_URL has no updater at all.
VERSION  :=
BUILD    :=
FEED_URL :=
ED_KEY   :=
PLIST    := $(APP)/Contents/Info.plist
SPARKLE  := $(APP)/Contents/Frameworks/Sparkle.framework

# rustup's ~/.cargo/env puts cargo on PATH. A Rust from elsewhere (Homebrew) has no such file and is already there.
CARGO_ENV := if [ -f "$$HOME/.cargo/env" ]; then . "$$HOME/.cargo/env"; fi;

.PHONY: core app assemble bundle release run install icon selftest test test-edition check-editions smoke clean

core:
	$(CARGO_ENV) cargo build --release --manifest-path core/Cargo.toml --target-dir $(CORE_TARGET) $(CORE_FEATURES)

# `scripts/bootstrap.sh sdk` prints an SDK only where the default one cannot build Ribbon: macOS 27 with just the
# Command Line Tools (SwiftUI's macros need Xcode there), where it picks the newest macOS 26 SDK. Mac with Xcode: nothing.
# The linker finds this edition's core through -L (Package.swift names no path). SwiftPM does not know the static library is
# an input of the binary, so a core that is not the one the binary was linked with (a checksum kept beside the build says which)
# gets the binary removed first and the build links it again. A checksum, not a date: cargo can hand back an older library.
app: core
	sdk=$$(scripts/bootstrap.sh sdk) || exit 1; \
	if [ -n "$$sdk" ]; then echo "Swift build uses the SDK $$sdk"; export SDKROOT="$$sdk"; fi; \
	stamp="$(SWIFT_SCRATCH)/core.cksum"; now=$$(cksum < "$(CORE_A)"); \
	if [ -e "$(BIN)" ] && [ "$$(cat "$$stamp" 2>/dev/null)" != "$$now" ]; then echo "The $(EDITION) core is not the one Ribbon was linked with: linking again"; rm -f "$(BIN)"; fi; \
	(cd app && swift build -c release --scratch-path "$(CURDIR)/$(SWIFT_SCRATCH)" -Xlinker "-L$(CURDIR)/$(CORE_LIB)" $(SWIFT_EDITION)) || exit 1; \
	echo "$$now" > "$$stamp"

# The bundle without a signature. Sparkle keeps only what a non-sandboxed app runs: no XPC services, no headers.
assemble: app
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp $(BIN) $(APP)/Contents/MacOS/Ribbon
	cp app/Resources/Info.plist $(PLIST)
	cp app/Resources/Ribbon.icns $(APP)/Contents/Resources/Ribbon.icns
	ditto $(SWIFT_SCRATCH)/release/Sparkle.framework $(SPARKLE)
	rm -rf $(SPARKLE)/Versions/B/XPCServices $(SPARKLE)/Versions/B/Headers $(SPARKLE)/Versions/B/PrivateHeaders $(SPARKLE)/Versions/B/Modules
	rm -f $(SPARKLE)/XPCServices $(SPARKLE)/Headers $(SPARKLE)/PrivateHeaders $(SPARKLE)/Modules
ifneq ($(VERSION),)
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" -c "Set :CFBundleVersion $(BUILD)" $(PLIST)
endif
ifneq ($(FEED_URL),)
ifeq ($(ED_KEY),)
	$(error FEED_URL needs ED_KEY: updates are only trusted if signed with your key)
endif
	/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $(FEED_URL)" -c "Add :SUPublicEDKey string $(ED_KEY)" \
	  -c "Add :SUEnableAutomaticChecks bool true" $(PLIST)
endif

bundle: assemble
	$(if $(and $(filter -,$(SIGN)),$(filter file,$(origin SIGN))),@echo "$(ADHOC_NOTE)")
	scripts/sign-app.sh $(APP) "$(SIGN)" \
	  || (echo "signing identity '$(SIGN)' unavailable, using ad-hoc: $(ADHOC_HINT)" \
	      && scripts/sign-app.sh $(APP) -)

# make release VERSION=0.2.0 [DRY=1]: signed, notarized DMG + appcast; see RELEASING.md.
release:
	scripts/release.sh $(VERSION) $(if $(filter-out 0,$(DRY)),--dry)

# Regenerate app/Resources/Ribbon.icns from the SwiftUI icon (the .icns is committed).
icon: app
	rm -rf build/icon && $(BIN) --render-icon build/icon
	iconutil -c icns build/icon/Ribbon.iconset -o app/Resources/Ribbon.icns

run: bundle
	open $(APP)

# Stable location so the Accessibility grant survives rebuilds.
install: bundle
	pkill -x Ribbon || true
	rm -rf $(HOME)/Applications/Ribbon.app
	mkdir -p $(HOME)/Applications
	cp -R $(APP) $(HOME)/Applications/Ribbon.app
	open $(HOME)/Applications/Ribbon.app

selftest: app
	$(BIN) --selftest

# Live AX smoke test (needs an unlocked screen and Accessibility for the terminal).
smoke: bundle
	DUMMY_BIN="$(CURDIR)/$(DUMMY)" ./qa/live-smoke.sh

# Both editions the checkout can build (free; plus too where core/src/plus exists), each with its own core: cargo test, then the
# app's selftest, which also fails if the app and the core it linked are not the same edition. `make test EDITION=plus` tests one.
TEST_EDITIONS := $(if $(filter command line environment,$(origin EDITION)),$(EDITION),free $(if $(wildcard core/src/plus),plus))

# The rules the public export relies on (EDITIONS.md): how Plus/ and Free/ files are wrapped, and what unifdef makes of them.
check-editions:
	scripts/check-editions.sh

test: check-editions
	@for e in $(TEST_EDITIONS); do \
	  echo "== $$e edition"; \
	  $(MAKE) --no-print-directory EDITION=$$e test-edition || exit 1; \
	done

test-edition:
	$(CARGO_ENV) cargo test --manifest-path core/Cargo.toml --target-dir $(CORE_TARGET) $(CORE_FEATURES)
	$(MAKE) selftest

clean:
	rm -rf build app/.build
	$(CARGO_ENV) cargo clean --manifest-path core/Cargo.toml

# `make print-EDITION` / `make print-BIN`: what a script (release.sh) needs to know about the build, from this one place.
print-%:
	@echo '$($*)'
