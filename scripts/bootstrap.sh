#!/bin/bash
# Ribbon bootstrap: check this Mac, then build, sign and install Ribbon from this checkout.
# Written for a coding agent that follows INSTALL.md. Every command is safe to repeat. Nothing here uses sudo.
#
# Usage: scripts/bootstrap.sh [COMMAND] [OPTIONS]
#
# Commands
#   check        (default) Read-only report of what is present and missing, and the plan for `install`.
#   install      Install what is missing (only what the options allow), build, put Ribbon in ~/Applications,
#                launch it and open the Accessibility pane.
#   build        Like install, but stop at build/Ribbon.app: nothing is installed or launched.
#   update       Fast-forward this checkout, rebuild with the same signing identity, reinstall and relaunch.
#   uninstall    Quit Ribbon and remove ~/Applications/Ribbon.app.
#   permissions  [accessibility|screen-recording]  Say what the user has to switch on and open that pane.
#   sdk          Print the SDK the Swift build must use (nothing when the default one works). The Makefile calls it.
#
# Options
#   --dry-run          Print every command that changes something instead of running it. Read-only probes still run.
#   --signing MODE     local: sign with the stable 'Ribbon Local Signing' identity and create it if it is missing
#                      (scripts/local-signing.sh; one macOS dialog that only the user can answer).
#                      adhoc: ad-hoc; the Accessibility switch must be redone after every update.
#                      auto (default): the identity the installed copy already uses, else the local identity if it
#                      exists, else ad-hoc. auto never creates anything.
#   --install-rust     Allow installing or updating Rust with rustup (official installer; no shell profile changes).
#   --no-launch        install, update: do not launch Ribbon afterwards.
#   --no-open          install, update: do not open System Settings.
#   --no-pull          update: do not touch the checkout; rebuild and reinstall what is here.
#   --remove-signing   uninstall: also delete the 'Ribbon Local Signing' identity from the login keychain.
#
# Environment: RIBBON_INSTALL_DIR (default ~/Applications) is where Ribbon.app goes.
#              RIBBON_ALLOW_SANDBOX=1 skips the check that this shell is not inside a sandbox.
# Exit status: 0 done, 1 failed (the message says why), 2 usage, 3 the user has to do something, then re-run.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$ROOT/scripts
SIGNER=$SCRIPTS/local-signing.sh
INSTALL_DIR=${RIBBON_INSTALL_DIR:-$HOME/Applications}
APP_DEST=$INSTALL_DIR/Ribbon.app
APP_BUILT=$ROOT/build/Ribbon.app
BUILD_LOG=$ROOT/build/bootstrap-build.log
AX_PANE='x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
SCREEN_PANE='x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'

MIN_MACOS=26
MIN_RUST=1.78        # Cargo.lock is lockfile version 4
MIN_RUST_TEST=1.88   # `make test`: proptest 1.12
MIN_SWIFT=6.0        # app/Package.swift: swift-tools-version 6.0
CLT_SDK_MAX=26       # the newest SDK major that builds with the Command Line Tools alone

DRY=0 SIGNING=auto INSTALL_RUST=0 LAUNCH=1 OPEN_PANES=1 PULL=1 REMOVE_SIGNING=0

say() { printf '%s\n' "$*"; }
warn() { printf 'bootstrap: warning: %s\n' "$*" >&2; }
die() { printf 'bootstrap: error: %s\n' "$*" >&2; exit 1; }
need_user() { printf 'bootstrap: waiting for the user: %s\n' "$*" >&2; exit 3; }
step() { printf '\n==> %s\n' "$*"; }

# Print a command that changes something, and run it unless this is a dry run.
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( DRY )); then return 0; fi
  "$@"
}

# Run a long command with its output in a log; show a sign of life every 30 s and the log's tail on failure.
run_logged() {
  local log=$1 pid t=0 rc=0
  shift
  printf '+'; printf ' %q' "$@"; printf '\n    (output: %s)\n' "$log"
  if (( DRY )); then return 0; fi
  mkdir -p "$(dirname "$log")"
  "$@" >"$log" 2>&1 &
  pid=$!
  # An interrupted run (an agent's command timeout, Ctrl-C) must stop its build too: the next run would otherwise meet
  # a build that is still writing into build/ and app/.build.
  trap 'kill "$pid" 2>/dev/null || true; exit 143' INT TERM HUP
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    t=$((t + 2))
    if (( t % 30 == 0 )); then printf '    ... still working (%ds)\n' "$t"; fi
  done
  wait "$pid" || rc=$?
  trap - INT TERM HUP
  if (( rc != 0 )); then tail -n 40 "$log" >&2; fi
  return "$rc"
}

# Open a System Settings pane. No desktop session or a sandbox makes `open` fail; that must not fail the install.
open_pane() {
  run open "$1" || warn "could not open System Settings from here: the user opens ${2:-the pane} by hand."
}

# ---------------------------------------------------------------- pure decisions (tested by scripts/test-bootstrap.sh)

# A version as a comparable integer: 26.5 -> 26005000.
ver_key() { local IFS=.; set -- $1; echo $(( 10#${1:-0} * 1000000 + 10#${2:-0} * 1000 + 10#${3:-0} )); }
ver_ge() { (( $(ver_key "$1") >= $(ver_key "$2") )); }

# What xcode-select points at: a full Xcode, or the Command Line Tools (or anything else without Xcode's SDK plugins).
dev_kind() { case $1 in *.app/Contents/Developer) echo xcode ;; *) echo clt ;; esac; }

# The newest MacOSX<major>[.<minor>].sdk in DIR with MIN <= major <= MAX; prints its path, or nothing (status 1).
sdk_newest_in() {
  local dir=$1 min=$2 max=$3 best= best_key=-1 p v key
  for p in "$dir"/MacOSX[0-9]*.sdk; do
    [[ -d $p ]] || continue
    v=${p##*/MacOSX}
    v=${v%.sdk}
    [[ $v =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || continue
    key=$(ver_key "$v")
    (( key >= min * 1000000 && key < (max + 1) * 1000000 )) || continue
    if (( key > best_key )); then best_key=$key; best=$p; fi
  done
  if [[ -z $best ]]; then return 1; fi
  printf '%s\n' "$best"
}

# Which SDK the Swift build uses. KIND is dev_kind's answer, DEFAULT_VERSION the toolchain's default SDK
# (xcrun --show-sdk-version), SDK_DIR the toolchain's SDKs folder.
# Prints nothing when the default SDK is fine and the path of the SDK to use as SDKROOT when it is not.
# Status 1: nothing here can build Ribbon. On macOS 27 the Command Line Tools' default SDK cannot (SwiftUI's @State is a
# macro there whose plugin ships only inside Xcode), but they also ship a macOS 26.x SDK, which can.
sdk_pick() {
  local kind=$1 default_version=$2 dir=$3 major pick
  major=${default_version%%.*}
  if [[ $kind == xcode ]] || (( 10#${major:-0} <= CLT_SDK_MAX )); then return 0; fi
  pick=$(sdk_newest_in "$dir" "$MIN_MACOS" "$CLT_SDK_MAX") || return 1
  printf '%s\n' "$pick"
}

# How to sign. REQUESTED: auto | local | adhoc. INSTALLED_SHA: the certificate the installed Ribbon is signed with, if
# that is still a valid identity here, else empty. LOCAL_SHA: the valid 'Ribbon Local Signing' identity, else empty.
# Prints "adhoc", "cert SHA1" (sign with that identity) or "create" (the local identity has to be made first).
signing_pick() {
  local requested=$1 installed=${2:-} local_sha=${3:-}
  case $requested in
    adhoc) echo adhoc ;;
    local) if [[ -n $local_sha ]]; then echo "cert $local_sha"; else echo create; fi ;;
    auto)
      if [[ -n $installed ]]; then echo "cert $installed"
      elif [[ -n $local_sha ]]; then echo "cert $local_sha"
      else echo adhoc; fi ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- probes (read-only)

# Under Rosetta on Apple silicon a shell reports x86_64 and rustup would install an Intel Rust. Run natively instead.
reexec_native() {
  if [[ $(uname -m) == x86_64 && $(sysctl -n hw.optional.arm64 2>/dev/null || true) == 1 && -z ${RIBBON_BOOTSTRAP_NATIVE:-} ]]; then
    export RIBBON_BOOTSTRAP_NATIVE=1
    exec arch -arm64 /bin/bash "${BASH_SOURCE[0]}" "$@"
  fi
}

probe_platform() {
  [[ $(uname -s) == Darwin ]] || die "Ribbon is a macOS app; this is $(uname -s)."
  MACOS_VER=$(sw_vers -productVersion)
  ARCH=$(uname -m)
  MACOS_OK=1
  if (( 10#${MACOS_VER%%.*} < MIN_MACOS )); then MACOS_OK=0; fi
  return 0
}

# The shell may be inside a sandbox (agents often are). SwiftPM cannot nest its own sandbox there, so the build fails.
probe_sandbox() {
  local out
  SANDBOXED=0
  if [[ -x /usr/bin/sandbox-exec && -z ${RIBBON_ALLOW_SANDBOX:-} ]]; then
    out=$(/usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>&1 || true)
    case $out in *sandbox_apply*) SANDBOXED=1 ;; esac
  fi
  return 0
}

# DEV_DIR, DEV_KIND, TC_STATE (ok | none). Looks at files only: git, make, swift and cc from /usr/bin would open Apple's
# installer dialog when the Command Line Tools are missing.
probe_devdir() {
  DEV_DIR= DEV_KIND= TC_STATE=ok
  if DEV_DIR=$(xcode-select -p 2>/dev/null) && [[ -x $DEV_DIR/usr/bin/make ]]; then
    DEV_KIND=$(dev_kind "$DEV_DIR")
  else
    TC_STATE=none
  fi
  return 0
}

# SWIFT_VER; TC_STATE becomes broken (toolchain does not run) or old.
probe_swift() {
  local out
  SWIFT_VER= TC_DETAIL=
  if ! out=$(swift --version 2>&1); then
    TC_STATE=broken
    TC_DETAIL=$(printf '%s\n' "$out" | head -3)
    return 0
  fi
  SWIFT_VER=$(printf '%s\n' "$out" | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1 || true)
  if [[ -z $SWIFT_VER ]] || ! ver_ge "$SWIFT_VER" "$MIN_SWIFT"; then TC_STATE=old; fi
  return 0
}

# SDK_STATE: default (the toolchain's own SDK works) | pick (use SDK_PICK as SDKROOT) | env (SDKROOT is already set)
# | none (no SDK here can build Ribbon) | unknown (could not ask).
sdk_decide() {
  SDK_STATE=unknown SDK_PICK= SDK_DEFAULT_VER=
  probe_devdir
  if [[ -n ${SDKROOT:-} ]]; then SDK_STATE=env; return 0; fi
  if [[ $TC_STATE != ok ]]; then return 0; fi
  SDK_DEFAULT_VER=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
  if [[ -z $SDK_DEFAULT_VER ]]; then return 0; fi
  if SDK_PICK=$(sdk_pick "$DEV_KIND" "$SDK_DEFAULT_VER" "$DEV_DIR/SDKs"); then
    if [[ -n $SDK_PICK ]]; then SDK_STATE=pick; else SDK_STATE=default; fi
  else
    SDK_PICK= SDK_STATE=none
  fi
  return 0
}

sdk_explain() {
  cat <<EOF
bootstrap: error: no SDK on this Mac can build Ribbon.
  This Mac has only the Command Line Tools ($DEV_DIR). Their default SDK is macOS $SDK_DEFAULT_VER, and since
  macOS 27 SwiftUI's @State needs a compiler plugin that ships only inside Xcode. The Command Line Tools here have
  no macOS 26.x SDK to fall back on either (look: ls $DEV_DIR/SDKs).
  The user needs to do ONE of these (this script never uses sudo):
    - install Xcode (App Store or developer.apple.com), open it once to accept its license, then select it:
      sudo xcode-select -s /Applications/Xcode.app
    - or install a Command Line Tools release that includes a MacOSX26.x SDK (System Settings > General > Software Update).
  Then run the same command again.
EOF
}

# RUST_STATE: ok | missing | old | broken; RUSTC_VER, RUSTUP (yes|no). Looks where the Makefile looks.
probe_rust() {
  local out
  RUST_STATE=ok RUSTC_VER= RUSTUP=no RUST_DETAIL= CARGO_PATH=
  if [[ -f $HOME/.cargo/env ]]; then . "$HOME/.cargo/env"; fi
  if command -v rustup >/dev/null 2>&1; then RUSTUP=yes; fi
  if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then RUST_STATE=missing; return 0; fi
  CARGO_PATH=$(command -v cargo)
  if ! out=$(rustc --version 2>&1) || ! cargo --version >/dev/null 2>&1; then
    RUST_STATE=broken
    RUST_DETAIL=$(printf '%s\n' "${out:-}" | head -2)
    return 0
  fi
  RUSTC_VER=$(printf '%s\n' "$out" | sed -n 's/^rustc \([0-9][0-9.]*\).*/\1/p' | head -1 || true)
  if [[ -z $RUSTC_VER ]] || ! ver_ge "$RUSTC_VER" "$MIN_RUST"; then RUST_STATE=old; fi
  return 0
}

# The designated requirement of an app: what macOS ties the Accessibility grant to.
dr_of() { codesign -d -r- "$1" 2>&1 | sed -n 's/^[# ]*designated => //p' | head -1 || true; }   # some macOS versions prefix "# "

# LOCAL_SHA, INSTALLED_KIND (none | unsigned | adhoc | certificate | other), INSTALLED_SHA, SIGN_CHOICE.
probe_signing() {
  local d valid=
  LOCAL_SHA=$("$SIGNER" identity 2>/dev/null || true)
  INSTALLED_KIND=none INSTALLED_SHA=
  if [[ -d $APP_DEST ]]; then
    d=$("$SIGNER" describe "$APP_DEST" 2>/dev/null || echo other)
    case $d in
      "certificate "*)
        INSTALLED_KIND=certificate INSTALLED_SHA=${d#certificate }
        if "$SIGNER" valid "$INSTALLED_SHA"; then valid=$INSTALLED_SHA; fi ;;
      *) INSTALLED_KIND=$d ;;
    esac
  fi
  SIGN_CHOICE=$(signing_pick "$SIGNING" "$valid" "$LOCAL_SHA")
}

# The pids of the Ribbon that runs from the install folder (not a dev build somewhere else).
installed_pids() {
  local pid cmd
  for pid in $(pgrep -x Ribbon 2>/dev/null || true); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    case $cmd in "$APP_DEST/Contents/MacOS/Ribbon"*) echo "$pid" ;; esac
  done
}

# Names of other window managers that are running (Ribbon offers to quit them on its first launch).
other_wms() {
  local n found=
  for n in Rectangle Magnet Moom BetterSnapTool Amethyst yabai AeroSpace OmniWM ChainYourMac Loop Divvy Spectacle; do   # Ribbon's own list
    if pgrep -x "$n" >/dev/null 2>&1; then found="$found${found:+, }$n"; fi
  done
  if [[ $(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || true) == 1 ]]; then found="$found${found:+, }Stage Manager"; fi
  printf '%s\n' "$found"
}

probe_all() {
  probe_platform
  probe_sandbox
  sdk_decide   # also finds the developer directory
  SWIFT_VER= TC_DETAIL=
  if [[ $TC_STATE == ok ]]; then probe_swift; fi
  probe_rust
  probe_signing
}

# ---------------------------------------------------------------- check

row() { printf '  %-13s %-8s %s\n' "$1" "$2" "$3"; }

cmd_check() {
  local blocked=0 remote= describe_git= n=0
  probe_all

  say "Ribbon bootstrap check (read-only). Checkout: $ROOT"
  if [[ $TC_STATE == ok ]] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    remote=$(git -C "$ROOT" remote get-url origin 2>/dev/null || echo 'none')
    describe_git=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo '?')
    row Source ok "$describe_git, origin $remote"
  fi
  if (( MACOS_OK )); then row macOS ok "$MACOS_VER on $ARCH"; else row macOS MISSING "$MACOS_VER: Ribbon needs macOS $MIN_MACOS or later"; blocked=1; fi
  case $TC_STATE in
    ok) row 'Build tools' ok "$DEV_DIR ($DEV_KIND), Swift $SWIFT_VER" ;;
    none) row 'Build tools' MISSING "Apple's Command Line Tools are not installed"; blocked=1 ;;
    old) row 'Build tools' MISSING "Swift ${SWIFT_VER:-?} is older than $MIN_SWIFT: update the Command Line Tools or Xcode"; blocked=1 ;;
    broken) row 'Build tools' MISSING "swift does not run: $(printf '%s' "$TC_DETAIL" | tr '\n' ' ')"; blocked=1 ;;
  esac
  case $SDK_STATE in
    default) row SDK ok "default SDK $SDK_DEFAULT_VER" ;;
    pick) row SDK ok "default SDK $SDK_DEFAULT_VER cannot build Ribbon without Xcode; the build uses ${SDK_PICK##*/}" ;;
    env) row SDK ok "SDKROOT from the environment: $SDKROOT" ;;
    none) row SDK MISSING "no SDK can build Ribbon: default $SDK_DEFAULT_VER needs Xcode and there is no macOS 26.x SDK"; blocked=1 ;;
    unknown) row SDK '?' "could not ask xcrun" ;;
  esac
  case $RUST_STATE in
    ok)
      row Rust ok "rustc $RUSTC_VER ($CARGO_PATH, rustup: $RUSTUP)"
      if ! ver_ge "$RUSTC_VER" "$MIN_RUST_TEST"; then row '' note "make test needs rustc $MIN_RUST_TEST or later"; fi ;;
    missing) row Rust MISSING "no cargo/rustc (needs rustc $MIN_RUST or later)"; blocked=1 ;;
    old) row Rust MISSING "rustc ${RUSTC_VER:-?} is older than $MIN_RUST ($CARGO_PATH, rustup: $RUSTUP)"; blocked=1 ;;
    broken) row Rust MISSING "cargo/rustc do not run: $(printf '%s' "$RUST_DETAIL" | tr '\n' ' ')"; blocked=1 ;;
  esac
  case $SIGN_CHOICE in
    adhoc) row Signing warn "ad-hoc: the Accessibility switch must be redone after every update. --signing local keeps it" ;;
    create) row Signing note "will create the 'Ribbon Local Signing' identity: one macOS dialog the user answers" ;;
    cert*) row Signing ok "certificate ${SIGN_CHOICE#cert }: the Accessibility grant survives updates" ;;
  esac
  case $INSTALLED_KIND in
    none) row Installed no "$APP_DEST" ;;
    *) row Installed yes "$APP_DEST (signed: $INSTALLED_KIND), running: $([[ -n $(installed_pids) ]] && echo yes || echo no)" ;;
  esac
  if (( SANDBOXED )); then
    row Sandbox warn "this shell is sandboxed: the Swift build fails here. Run install/build outside the sandbox (with the user's permission)"
  fi
  n=$(other_wms)
  if [[ -n $n ]]; then row 'Other WMs' note "$n running: Ribbon will offer to quit it on first launch"; fi

  say
  say "Plan for 'install' (--signing $SIGNING):"
  n=0
  if [[ $TC_STATE == none ]]; then n=$((n + 1)); say "  $n. [the user] Command Line Tools: xcode-select --install opens Apple's dialog; click Install, wait, re-run."; fi
  if [[ $RUST_STATE != ok ]]; then
    n=$((n + 1))
    say "  $n. Rust with rustup (needs --install-rust; downloads https://sh.rustup.rs; adds nothing to your shell profiles)."
  fi
  if [[ $SIGN_CHOICE == create ]]; then
    n=$((n + 1)); say "  $n. [the user] Create 'Ribbon Local Signing' in the login keychain: a trust dialog (password or Touch ID) and maybe a keychain prompt."
  fi
  n=$((n + 1)); say "  $n. Build with make bundle, about 2 minutes (downloads crates.io crates, Sparkle's source and binary from GitHub)."
  n=$((n + 1)); say "  $n. Copy it to $APP_DEST and launch it with open."
  n=$((n + 1)); say "  $n. [the user] Switch Ribbon on in Privacy & Security > Accessibility (the pane is opened); optionally Screen Recording."

  if (( ! MACOS_OK )); then exit 1; fi
  if (( blocked )); then exit 3; fi
  return 0
}

# ---------------------------------------------------------------- install

gate_platform() {
  probe_platform
  (( MACOS_OK )) || die "Ribbon needs macOS $MIN_MACOS or later; this Mac runs $MACOS_VER."
  [[ -f $ROOT/Makefile && -f $ROOT/core/Cargo.toml && -f $ROOT/app/Package.swift ]] \
    || die "$ROOT does not look like a Ribbon checkout (Makefile, core/Cargo.toml or app/Package.swift is missing)."
}

gate_sandbox() {
  probe_sandbox
  if (( SANDBOXED )); then
    local msg="this shell runs inside a sandbox, and Ribbon's Swift build cannot work in one: SwiftPM cannot start its own sandbox here, downloads bypass the sandbox proxy and the module cache is not writable. Run this command outside the sandbox (ask the user for permission to do that), or set RIBBON_ALLOW_SANDBOX=1 to try anyway."
    if (( DRY )); then warn "$msg"; else die "$msg"; fi
  fi
}

gate_toolchain() {
  sdk_decide   # also finds the developer directory
  if [[ $TC_STATE == none ]]; then
    step "Command Line Tools"
    run xcode-select --install || true
    need_user "Apple's Command Line Tools are not installed. Apple's installer dialog is open (or was just requested): the user clicks Install, accepts the license and waits a few minutes. Then run this command again."
  fi
  probe_swift
  case $TC_STATE in
    broken) die "swift does not run: $TC_DETAIL
  If it mentions the Xcode license, the user must run 'sudo xcodebuild -license accept' (this script never uses sudo). Otherwise reinstall the Command Line Tools." ;;
    old) die "Swift ${SWIFT_VER:-?} is older than $MIN_SWIFT. Update the Command Line Tools in System Settings > General > Software Update (or install a current Xcode)." ;;
  esac
  if [[ $SDK_STATE == none ]]; then sdk_explain >&2; exit 1; fi
}

install_rust() {
  local dir
  step "Rust"
  if [[ $RUSTUP == yes ]]; then
    run rustup toolchain install stable --profile minimal
    run rustup default stable
  else
    if (( DRY )); then dir=${TMPDIR:-/tmp}/ribbon-rustup.XXXXXX; else dir=$(mktemp -d "${TMPDIR:-/tmp}/ribbon-rustup.XXXXXX"); fi
    run curl --proto '=https' --tlsv1.2 -sSf -o "$dir/rustup-init.sh" https://sh.rustup.rs \
      || { rm -rf "$dir"; die "could not download the rustup installer from https://sh.rustup.rs (is the Mac online?)."; }
    # --no-modify-path: the Makefile loads ~/.cargo/env itself, so no shell profile has to change.
    run sh "$dir/rustup-init.sh" -y --profile minimal --default-toolchain stable --no-modify-path \
      || { rm -rf "$dir"; die "the rustup installer failed; its message is above."; }
    run rm -rf "$dir"
  fi
  if (( DRY )); then return 0; fi
  probe_rust
  [[ $RUST_STATE == ok ]] || die "Rust is still not usable after the rustup install (state: $RUST_STATE)."
}

gate_rust() {
  probe_rust
  if [[ $RUST_STATE == ok ]]; then return 0; fi
  if (( INSTALL_RUST )); then install_rust; return 0; fi
  case $RUST_STATE in
    missing) need_user "Rust is not installed. With the user's agreement run this command again with --install-rust (official rustup installer, no shell profile changes)." ;;
    old) need_user "rustc ${RUSTC_VER:-?} at $CARGO_PATH is older than $MIN_RUST. With the user's agreement run this command again with --install-rust to install a current rustup toolchain ($([[ $RUSTUP == yes ]] && echo 'rustup update' || echo 'rustup is installed beside it and takes precedence in make')), or have the user upgrade it (for Homebrew: brew upgrade rust)." ;;
    broken) need_user "cargo/rustc do not run (${RUST_DETAIL:-no output}). With the user's agreement run this command again with --install-rust." ;;
  esac
}

# Sets SIGN_ARG, the value for make's SIGN.
resolve_signing() {
  probe_signing
  case $SIGN_CHOICE in
    adhoc) SIGN_ARG=- ;;
    create)
      step "Local signing identity"
      if (( DRY )); then
        "$SIGNER" create --dry-run
        SIGN_ARG=SHA1_OF_RIBBON_LOCAL_SIGNING
      else
        "$SIGNER" create || exit $?
        LOCAL_SHA=$("$SIGNER" identity)
        [[ -n $LOCAL_SHA ]] || die "the local signing identity was not created."
        SIGN_ARG=$LOCAL_SHA
      fi ;;
    cert\ *) SIGN_ARG=${SIGN_CHOICE#cert } ;;
    *) die "internal error: signing choice '$SIGN_CHOICE'" ;;
  esac
}

do_build() {
  local kind
  step "Building Ribbon (first build: about 2 minutes plus downloads)"
  case $SDK_STATE in
    pick) say "The default SDK ($SDK_DEFAULT_VER) cannot build Ribbon without Xcode; the Swift build uses ${SDK_PICK##*/}." ;;
    env) say "The Swift build uses SDKROOT from the environment: $SDKROOT" ;;
  esac
  case $SIGN_ARG in
    -) say "Signing: ad-hoc." ;;
    *) say "Signing: identity $SIGN_ARG." ;;
  esac
  run_logged "$BUILD_LOG" make -C "$ROOT" bundle "SIGN=$SIGN_ARG" \
    || die "the build failed. The end of the log is above; all of it is in $BUILD_LOG."
  if (( DRY )); then return 0; fi

  [[ -x $APP_BUILT/Contents/MacOS/Ribbon ]] || die "the build finished but $APP_BUILT/Contents/MacOS/Ribbon is missing."
  codesign --verify --strict --deep "$APP_BUILT" 2>&1 || die "the built app's signature does not verify."
  BUILT_DR=$(dr_of "$APP_BUILT")
  kind=$("$SIGNER" describe "$APP_BUILT")
  say "Built $APP_BUILT ($(lipo -archs "$APP_BUILT/Contents/MacOS/Ribbon" 2>/dev/null || echo '?'))."
  say "Designated requirement: ${BUILT_DR:-none}"
  case $kind in
    adhoc)
      if [[ $SIGN_ARG != - ]]; then
        warn "the identity $SIGN_ARG could not sign, so the build fell back to ad-hoc (the build log says why: $BUILD_LOG)."
      fi
      warn "this build is signed ad-hoc: macOS treats every rebuild as a new app, so the Accessibility switch must be redone after each update. --signing local avoids that." ;;
    "certificate "*) say "Signed with a certificate: the Accessibility grant stays valid across rebuilds signed the same way." ;;
    *) warn "the build is signed in an unexpected way ($kind)." ;;
  esac
}

quit_installed() {
  local pids i
  pids=$(installed_pids)
  if [[ -z $pids ]]; then return 0; fi
  say "Ribbon is running from $APP_DEST: asking it to quit (it puts every window back first)."
  # shellcheck disable=SC2086
  run kill -TERM $pids
  if (( DRY )); then return 0; fi
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 0.5
    if [[ -z $(installed_pids) ]]; then return 0; fi
  done
  die "Ribbon did not quit within 10 seconds. The user chooses Quit in Ribbon's menu bar item; then run this command again."
}

do_install_app() {
  local new=$INSTALL_DIR/.Ribbon.app.new old=$INSTALL_DIR/.Ribbon.app.old
  step "Installing to $APP_DEST"
  quit_installed
  run mkdir -p "$INSTALL_DIR"
  run rm -rf "$new" "$old"
  run ditto "$APP_BUILT" "$new"
  if [[ -e $APP_DEST ]]; then run mv "$APP_DEST" "$old"; fi
  run mv "$new" "$APP_DEST"
  run rm -rf "$old"
}

do_launch() {
  local i tries=${RIBBON_LAUNCH_TRIES:-20}   # half a second each; the tests shorten it
  step "Launching Ribbon"
  run open "$APP_DEST" || die "open could not start Ribbon."
  if (( DRY )); then return 0; fi
  for (( i = 0; i < tries; i++ )); do
    if [[ -n $(installed_pids) ]]; then say "Ribbon is running (menu bar item)."; return 0; fi
    sleep 0.5
  done
  die "Ribbon did not start. Try: open '$APP_DEST'. To see why it quits, read 'log show --last 2m --process Ribbon' and the newest file in ~/Library/Logs/DiagnosticReports. Do not run the binary from a terminal: a permission prompt or grant would then attach to the terminal instead of Ribbon."
}

# What the user has to switch on, and the pane for it.
print_permissions() {
  cat <<EOF

The user has to switch Ribbon on. Nothing can do this for them.
  1. System Settings > Privacy & Security > Accessibility > switch on "Ribbon".
     Ribbon's own window ("Let Ribbon tidy your windows") notices the grant by itself, then shows "You're all set".
  2. Optional, smoother swipes and glides: Privacy & Security > Screen Recording > switch on "Ribbon", then quit
     Ribbon from its menu bar item and open it again. (scripts/bootstrap.sh permissions screen-recording opens that pane.)
  If Ribbon still asks although it is ticked, the list holds an older copy: select Ribbon, press the minus button, and
  open Ribbon again so it asks afresh.
EOF
}

cmd_permissions() {
  local which=${1:-accessibility} pane name
  case $which in
    accessibility|ax) pane=$AX_PANE name=Accessibility ;;
    screen-recording|screen) pane=$SCREEN_PANE name="Screen Recording" ;;
    *) usage >&2; exit 2 ;;
  esac
  print_permissions
  if (( OPEN_PANES )); then open_pane "$pane" "System Settings > Privacy & Security > $name"; fi
}

# The common tail of build, install and update. MODE: build | install.
flow() {
  local mode=$1 old_dr= grant_needed=1
  gate_platform
  gate_sandbox
  gate_toolchain
  gate_rust
  resolve_signing

  if [[ -d $APP_DEST ]]; then old_dr=$(dr_of "$APP_DEST"); fi
  do_build
  [[ $mode == install ]] || return 0
  do_install_app
  if (( DRY )); then
    grant_needed=1
  elif [[ -n $old_dr && $old_dr == "$(dr_of "$APP_DEST")" ]]; then
    grant_needed=0
  elif [[ -n $old_dr ]]; then
    warn "Ribbon's signature differs from the copy that was installed (designated requirement changed), so macOS will ask for Accessibility again."
  fi
  if (( LAUNCH )); then do_launch; fi

  step "Done"
  if (( DRY )); then say "(dry run) Ribbon would now be installed at $APP_DEST."; else say "Ribbon is installed at $APP_DEST."; fi
  if (( grant_needed )); then
    print_permissions
    if (( OPEN_PANES )); then open_pane "$AX_PANE" "System Settings > Privacy & Security > Accessibility"; fi
  else
    say "Same signature as the copy that was installed, so an Accessibility grant given to it still applies."
    say "If Ribbon's window asks for Accessibility anyway, the user switches it on (scripts/bootstrap.sh permissions opens the pane)."
  fi
}

# ---------------------------------------------------------------- update, uninstall

git_() { git -C "$ROOT" "$@"; }

update_checkout() {
  local old new branch upstream tag newest
  step "Updating the checkout"
  git_ rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git checkout; clone Ribbon again to update."
  say "origin: $(git_ remote get-url origin 2>/dev/null || echo none)"
  if [[ -n $(git_ status --porcelain --untracked-files=no) ]]; then
    die "this checkout has uncommitted changes to tracked files. Commit or stash them, or use --no-pull to rebuild what is here."
  fi
  old=$(git_ rev-parse HEAD)
  run git -C "$ROOT" fetch --tags --quiet || die "git fetch failed (is the Mac online?)."
  branch=$(git_ symbolic-ref --short -q HEAD || true)
  if [[ -n $branch ]]; then
    upstream=$(git_ rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
      || die "branch '$branch' tracks no remote branch. Set one (git branch --set-upstream-to origin/$branch), or use --no-pull."
    run git -C "$ROOT" merge --ff-only --quiet "$upstream" \
      || die "cannot fast-forward '$branch' to '$upstream': this checkout has commits of its own. Resolve it with git, or use --no-pull."
  else
    tag=$(git_ describe --tags --exact-match 2>/dev/null) \
      || die "this checkout is on a commit that is not a tag. Check out a tag or a branch, or use --no-pull."
    newest=$(git_ tag --list 'v[0-9]*' --sort=-v:refname | head -1 || true)
    if [[ -n $newest && $newest != "$tag" ]] && git_ merge-base --is-ancestor "$tag" "$newest"; then
      run git -C "$ROOT" checkout --quiet "$newest"
    fi
  fi
  if (( DRY )); then say "(dry run) the checkout would be at its newest commit or tag from here on."; return 0; fi
  new=$(git_ rev-parse HEAD)
  if [[ $new == "$old" ]]; then say "Already up to date ($(git_ rev-parse --short HEAD))."; return 0; fi
  say "Updated $(git_ rev-parse --short "$old") -> $(git_ rev-parse --short "$new"):"
  git_ log --oneline "$old..$new" | head -20 || true
  # The scripts may have changed: carry on with the new ones.
  local args=(update --no-pull --signing "$SIGNING")
  if (( INSTALL_RUST )); then args+=(--install-rust); fi
  if (( ! LAUNCH )); then args+=(--no-launch); fi
  if (( ! OPEN_PANES )); then args+=(--no-open); fi
  exec "$SCRIPTS/bootstrap.sh" "${args[@]}"
}

cmd_update() {
  gate_platform
  probe_devdir
  if [[ $TC_STATE == none ]]; then gate_toolchain; fi   # git is part of the Command Line Tools
  if (( PULL )); then update_checkout; fi
  flow install
}

cmd_uninstall() {
  gate_platform
  step "Removing Ribbon"
  quit_installed
  if [[ -e $APP_DEST ]]; then run rm -rf "$APP_DEST"; say "Removed $APP_DEST."; else say "Nothing at $APP_DEST."; fi
  if (( REMOVE_SIGNING )); then run "$SIGNER" remove; fi
  say
  say "Left behind on purpose (the user can delete them):"
  say "  - settings: defaults delete com.makeautomation.ribbon, and ~/Library/Application Support/Ribbon (layout memory)"
  say "  - the Accessibility (and Screen Recording) entry: System Settings > Privacy & Security, select Ribbon, press minus"
  say "  - Ribbon's login item, if it was on: System Settings > General > Login Items & Extensions (switch it off in Ribbon before uninstalling next time)"
  say "  - the build in $ROOT/build, and the checkout itself"
  if (( ! REMOVE_SIGNING )); then say "  - the 'Ribbon Local Signing' identity, if you made it (uninstall --remove-signing deletes it)"; fi
}

# ---------------------------------------------------------------- sdk (used by the Makefile)

cmd_sdk() {
  sdk_decide
  case $SDK_STATE in
    pick) printf '%s\n' "$SDK_PICK" ;;
    none) sdk_explain >&2; return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------- main

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

main() {
  local cmd= arg=
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) DRY=1 ;;
      --signing)
        if [[ $# -lt 2 ]]; then printf 'bootstrap: --signing takes local, adhoc or auto\n' >&2; exit 2; fi
        SIGNING=$2; shift ;;
      --signing=*) SIGNING=${1#*=} ;;
      --install-rust) INSTALL_RUST=1 ;;
      --no-launch) LAUNCH=0 ;;
      --no-open) OPEN_PANES=0 ;;
      --no-pull) PULL=0 ;;
      --remove-signing) REMOVE_SIGNING=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) printf 'bootstrap: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
      *) if [[ -z $cmd ]]; then cmd=$1; else arg=$1; fi ;;
    esac
    shift
  done
  case $SIGNING in local|adhoc|auto) ;; *) printf 'bootstrap: --signing takes local, adhoc or auto\n' >&2; exit 2 ;; esac
  cmd=${cmd:-check}
  if (( DRY )); then say "Dry run: commands that change something are printed, not run."; fi

  case $cmd in
    sdk) cmd_sdk ;;
    check) cmd_check ;;
    install) flow install ;;
    build) flow build ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall ;;
    permissions) cmd_permissions "$arg" ;;
    help) usage ;;
    *) printf 'bootstrap: unknown command %s\n' "$cmd" >&2; usage >&2; exit 2 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  # `sdk` runs under make, which is already in the right architecture.
  if [[ ${1:-} != sdk ]]; then reexec_native "$@"; fi
  main "$@"
fi
