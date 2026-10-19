#!/bin/bash
# Checks of scripts/bootstrap.sh, scripts/local-signing.sh and the Makefile's new defaults against faked Macs:
# fake xcode-select, xcrun, swift and cargo on PATH, fake SDK folders, a fake HOME. No keychain, no network, no build,
# nothing installed. Run: scripts/test-bootstrap.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
# shellcheck source=bootstrap.sh
source "$here/bootstrap.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/ribbon-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
count=0 fails=0

expect() {   # expect WHAT EXPECTED ACTUAL
  count=$((count + 1))
  if [[ $2 == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    fails=$((fails + 1))
    printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
  fi
}
expect_has() {   # expect_has WHAT NEEDLE HAYSTACK
  count=$((count + 1))
  if [[ $3 == *"$2"* ]]; then
    printf '  ok   %s\n' "$1"
  else
    fails=$((fails + 1))
    printf '  FAIL %s\n         missing: %s\n         in: %s\n' "$1" "$2" "$3"
  fi
}

echo "versions and kinds"
expect "26.5 >= 26" yes "$(ver_ge 26.5 26 && echo yes || echo no)"
expect "26.10 >= 26.9 (numeric, not text)" yes "$(ver_ge 26.10 26.9 && echo yes || echo no)"
expect "1.77.2 < 1.78" no "$(ver_ge 1.77.2 1.78 && echo yes || echo no)"
expect "1.88 >= 1.88.0" yes "$(ver_ge 1.88 1.88.0 && echo yes || echo no)"
expect "08 is not octal" yes "$(ver_ge 26.08 26.8 && echo yes || echo no)"
expect "Xcode path is xcode" xcode "$(dev_kind /Applications/Xcode-27.0.0.app/Contents/Developer)"
expect "CLT path is clt" clt "$(dev_kind /Library/Developer/CommandLineTools)"

echo "sdk_pick with fake SDK folders"
sdks=$work/sdks
mkdir -p "$sdks"
for s in MacOSX.sdk MacOSX26.sdk MacOSX26.5.sdk MacOSX26.10.sdk MacOSX26.9.sdk MacOSX27.sdk MacOSX27.0.sdk MacOSXfoo.sdk; do mkdir "$sdks/$s"; done
: >"$sdks/MacOSX26.99.sdk"   # a file, not an SDK folder
expect "CLT on 27.0 takes the newest 26.x (26.10, not 26.9)" "$sdks/MacOSX26.10.sdk" "$(sdk_pick clt 27.0 "$sdks")"
expect "CLT on 26.2 needs no SDKROOT" "" "$(sdk_pick clt 26.2 "$sdks")"
expect "Xcode on 27.0 needs no SDKROOT" "" "$(sdk_pick xcode 27.0 "$sdks")"
expect "CLT on 28 still takes 26.x" "$sdks/MacOSX26.10.sdk" "$(sdk_pick clt 28.0 "$sdks")"
only27=$work/only27
mkdir -p "$only27/MacOSX27.sdk" "$only27/MacOSX27.0.sdk"
expect "CLT on 27.0 with only 27.x fails" fail "$(sdk_pick clt 27.0 "$only27" >/dev/null && echo ok || echo fail)"
expect "CLT with no SDK folder fails" fail "$(sdk_pick clt 27.0 "$work/missing" >/dev/null && echo ok || echo fail)"
expect "Xcode with no SDK folder is fine" ok "$(sdk_pick xcode 27.0 "$work/missing" >/dev/null && echo ok || echo fail)"

echo "signing_pick"
a=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA b=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
expect "adhoc ignores identities" adhoc "$(signing_pick adhoc "$a" "$b")"
expect "local with the identity present reuses it" "cert $b" "$(signing_pick local "$a" "$b")"
expect "local without the identity creates it" create "$(signing_pick local "$a" "")"
expect "auto keeps the installed identity" "cert $a" "$(signing_pick auto "$a" "$b")"
expect "auto falls back to the local identity" "cert $b" "$(signing_pick auto "" "$b")"
expect "auto never creates: ad-hoc" adhoc "$(signing_pick auto "" "")"
expect "unknown mode fails" fail "$(signing_pick bogus "" "" >/dev/null 2>&1 && echo ok || echo fail)"

# Helpers: a fake Mac is a PATH shim directory and a developer directory under a private folder, with its own HOME.
# fake_mac DIR KIND DEFAULT_SDK_VERSION SDK_FOLDER...: a PATH shim directory and a developer directory.
fake_mac() {
  local d=$1 kind=$2 ver=$3 dev s
  shift 3
  if [[ $kind == xcode ]]; then dev=$d/Xcode.app/Contents/Developer; else dev=$d/CommandLineTools; fi
  mkdir -p "$dev/usr/bin" "$dev/SDKs" "$d/bin" "$d/home"
  : >"$dev/usr/bin/make"
  chmod +x "$dev/usr/bin/make"
  for s in "$@"; do mkdir -p "$dev/SDKs/$s"; done
  printf '#!/bin/sh\ncase "$1" in -p) echo "%s" ;; --install) echo "$@" >>"%s/xcode-select.log" ;; esac\n' "$dev" "$d" >"$d/bin/xcode-select"
  printf '#!/bin/sh\ncase "$*" in *--show-sdk-version*) echo %s ;; esac\n' "$ver" >"$d/bin/xcrun"
  printf '#!/bin/sh\necho "Apple Swift version 6.2.1 (swiftlang-6.2.1.4.8)"\n' >"$d/bin/swift"
  chmod +x "$d/bin/xcode-select" "$d/bin/xcrun" "$d/bin/swift"
}
fake_rust() {   # fake_rust DIR VERSION
  printf '#!/bin/sh\necho "rustc %s (abcdef123 2026-01-01)"\n' "$2" >"$1/bin/rustc"
  printf '#!/bin/sh\necho "cargo %s (abcdef123 2026-01-01)"\n' "$2" >"$1/bin/cargo"
  chmod +x "$1/bin/rustc" "$1/bin/cargo"
}
# on DIR script args...: run the script on a fake Mac (own HOME, only the shims and system tools on PATH).
on() {
  local d=$1
  shift
  env -i HOME="$d/home" PATH="$d/bin:/usr/bin:/bin:/usr/sbin:/sbin" RIBBON_ALLOW_SANDBOX=1 "$@"
}

# fake_security DIR: a security shim that prints the listings in DIR/valid.txt (find-identity -v) and DIR/all.txt
# (find-identity), the same formats macOS prints, and logs anything else instead of doing it.
fake_security() {
  printf '#!/bin/sh\ncase "$1" in\n  find-identity) v=; for a in "$@"; do [ "$a" = -v ] && v=1; done\n    if [ -n "$v" ]; then cat "%s/valid.txt"; else cat "%s/all.txt"; fi ;;\n  login-keychain) echo "    \\"/fake/login.keychain-db\\"" ;;\n  *) echo "$@" >>"%s/security.log" ;;\nesac\n' "$1" "$1" "$1" >"$1/bin/security"
  chmod +x "$1/bin/security"
  : >"$1/valid.txt"
  : >"$1/all.txt"
}
echo "local-signing.sh on a Mac whose keychain lists nothing (a fake security command: the real keychain is never read)"
m=$work/kc0
fake_mac "$m" clt 26.2 MacOSX.sdk MacOSX26.sdk
fake_security "$m"
probe=$work/probe
cp /usr/bin/true "$probe"
codesign --force --sign - "$probe" 2>/dev/null
expect "an ad-hoc signed file is described as adhoc" adhoc "$(on "$m" "$here/local-signing.sh" describe "$probe")"
expect "verify rejects an ad-hoc app" fail "$(on "$m" "$here/local-signing.sh" verify "$probe" >/dev/null 2>&1 && echo ok || echo fail)"
expect "valid rejects a malformed hash" fail "$(on "$m" "$here/local-signing.sh" valid nonsense && echo ok || echo fail)"
expect "valid rejects an unknown hash" fail "$(on "$m" "$here/local-signing.sh" valid AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA && echo ok || echo fail)"
expect "usage error exits 2" 2 "$(on "$m" "$here/local-signing.sh" bogus >/dev/null 2>&1; echo $?)"
dry=$(on "$m" "$here/local-signing.sh" create --dry-run 2>&1 || true)
expect_has "create --dry-run trusts the certificate for code signing only" "add-trusted-cert -r trustRoot -p codeSign" "$dry"
expect_has "create --dry-run lets codesign use the key" "-T /usr/bin/codesign" "$dry"
expect_has "create --dry-run makes a non-CA code-signing certificate" "openssl.cnf" "$dry"
expect "create --dry-run changed no file" "" "$(ls "${TMPDIR:-/tmp}"/ribbon-signing.* 2>/dev/null || true)"
expect "create --dry-run ran no keychain command" no "$([[ -s $m/security.log ]] && echo yes || echo no)"

echo "bootstrap.sh against fake Macs"
m=$work/clt27
fake_mac "$m" clt 27.0 MacOSX.sdk MacOSX26.sdk MacOSX26.5.sdk MacOSX27.sdk MacOSX27.0.sdk
fake_rust "$m" 1.99.0
expect "sdk on CLT 27 prints the macOS 26.5 SDK" "$m/CommandLineTools/SDKs/MacOSX26.5.sdk" "$(on "$m" "$here/bootstrap.sh" sdk)"
expect "sdk honours an SDKROOT the user set" "" "$(on "$m" SDKROOT=/somewhere "$here/bootstrap.sh" sdk)"
out=$(on "$m" "$here/bootstrap.sh" check || true)
expect_has "check says which SDK the build uses" "the build uses MacOSX26.5.sdk" "$out"
expect_has "check reports the CLT as the build tools" "(clt), Swift 6.2.1" "$out"
expect_has "check names the Rust it found" "rustc 1.99.0" "$out"
expect_has "check with auto signing and no identity says ad-hoc" "ad-hoc" "$out"
expect "check exits 0 when nothing is missing" 0 "$(on "$m" "$here/bootstrap.sh" check >/dev/null 2>&1; echo $?)"
dry=$(on "$m" "$here/bootstrap.sh" install --dry-run --no-launch --no-open --signing adhoc 2>&1)
expect_has "install --dry-run builds with ad-hoc signing" "bundle SIGN=-" "$dry"
expect_has "install --dry-run installs into the fake home" "$m/home/Applications/Ribbon.app" "$dry"
expect "install --dry-run launched nothing" no "$([[ $dry == *"+ open "* ]] && echo yes || echo no)"
expect "install --dry-run created nothing" no "$([[ -e $m/home/Applications || -e $m/home/.cargo ]] && echo yes || echo no)"

m=$work/clt27-only27
fake_mac "$m" clt 27.0 MacOSX.sdk MacOSX27.sdk MacOSX27.0.sdk
fake_rust "$m" 1.99.0
code=$(on "$m" "$here/bootstrap.sh" sdk >/dev/null 2>"$work/err"; echo $?)
expect "sdk on CLT 27 without any 26.x SDK fails" 1 "$code"
expect_has "...and explains how to fix it" "install Xcode" "$(cat "$work/err")"
expect "check exits 3 when the SDK is missing" 3 "$(on "$m" "$here/bootstrap.sh" check >/dev/null 2>&1; echo $?)"

m=$work/xcode27
fake_mac "$m" xcode 27.0 MacOSX.sdk MacOSX27.sdk MacOSX27.0.sdk
fake_rust "$m" 1.99.0
expect "sdk with Xcode prints nothing" "" "$(on "$m" "$here/bootstrap.sh" sdk)"

m=$work/clt26
fake_mac "$m" clt 26.2 MacOSX.sdk MacOSX26.sdk MacOSX26.2.sdk
fake_rust "$m" 1.88.0
expect "sdk on macOS 26 CLT prints nothing" "" "$(on "$m" "$here/bootstrap.sh" sdk)"

m=$work/noclt
mkdir -p "$m/bin" "$m/home"
printf '#!/bin/sh\ncase "$1" in -p) exit 2 ;; --install) echo "$@" >>"%s/xcode-select.log" ;; esac\n' "$m" >"$m/bin/xcode-select"
chmod +x "$m/bin/xcode-select"
expect "sdk without the CLT prints nothing and succeeds" "" "$(on "$m" "$here/bootstrap.sh" sdk)"
expect "check exits 3 without the CLT" 3 "$(on "$m" "$here/bootstrap.sh" check >/dev/null 2>&1; echo $?)"
expect_has "check puts the CLT dialog in the plan" "xcode-select --install opens Apple's dialog" "$(on "$m" "$here/bootstrap.sh" check 2>&1 || true)"
code=$(on "$m" "$here/bootstrap.sh" install >/dev/null 2>"$work/err"; echo $?)
expect "install without the CLT exits 3 (user action)" 3 "$code"
expect_has "...after asking Apple's installer to open" "--install" "$(cat "$m/xcode-select.log" 2>/dev/null || true)"
expect_has "...and tells the user what to do" "click" "$(tr 'A-Z' 'a-z' <"$work/err")"

m=$work/norust
fake_mac "$m" clt 26.2 MacOSX.sdk MacOSX26.sdk
code=$(on "$m" "$here/bootstrap.sh" install --dry-run >/dev/null 2>"$work/err"; echo $?)
expect "install without Rust and without --install-rust exits 3" 3 "$code"
expect_has "...and names the flag" "--install-rust" "$(cat "$work/err")"
out=$(on "$m" "$here/bootstrap.sh" install --dry-run --install-rust --no-launch --no-open --signing adhoc 2>&1)
expect_has "--install-rust --dry-run uses the official installer over https" "--proto =https --tlsv1.2 -sSf" "$out"
expect_has "...with a minimal stable toolchain" "-y --profile minimal --default-toolchain stable --no-modify-path" "$out"
expect "--install-rust --dry-run installed nothing" no "$([[ -e $m/home/.cargo ]] && echo yes || echo no)"

m=$work/oldrust
fake_mac "$m" clt 26.2 MacOSX.sdk MacOSX26.sdk
fake_rust "$m" 1.70.0
code=$(on "$m" "$here/bootstrap.sh" install --dry-run >/dev/null 2>"$work/err"; echo $?)
expect "install with Rust 1.70 exits 3" 3 "$code"
expect_has "...and says it is too old" "older than $MIN_RUST" "$(cat "$work/err")"

echo "keychain listings, with a fake security command"
HA=1111111111111111111111111111111111111111 HB=2222222222222222222222222222222222222222 HC=3333333333333333333333333333333333333333
m=$work/kc
fake_mac "$m" clt 26.2 MacOSX.sdk MacOSX26.sdk
fake_rust "$m" 1.99.0
fake_security "$m"
signer() { on "$m" "$here/local-signing.sh" "$@"; }
expect "no identity: identity prints nothing" "" "$(signer identity)"
expect "no identity: status exits 1" 1 "$(signer status >/dev/null; echo $?)"
printf '  1) %s "Developer ID Application: Someone (ABC)"\n  2) %s "Ribbon Local Signing Extra"\n  3) %s "Ribbon Local Signing"\n     3 valid identities found\n' "$HA" "$HB" "$HC" >"$m/valid.txt"
cp "$m/valid.txt" "$m/all.txt"
expect "identity matches the name exactly, not a prefix" "$HC" "$(signer identity)"
expect "status says present and valid" 0 "$(signer status >/dev/null; echo $?)"
expect "valid accepts a listed hash" 0 "$(signer valid "$HA" >/dev/null; echo $?)"
expect "valid ignores the case of the hash" 0 "$(signer valid "$(printf '%s' "$HA" | tr 'A-F' 'a-f')" >/dev/null; echo $?)"
expect "valid rejects a hash that is not listed" 1 "$(signer valid 4444444444444444444444444444444444444444 >/dev/null; echo $?)"
out=$(signer create --dry-run 2>&1 || true)
expect_has "create --dry-run reuses an existing valid identity" "Reusing the existing identity" "$out"
out=$(on "$m" "$here/bootstrap.sh" check 2>&1 || true)
expect_has "check shows the local identity as the signature" "certificate $HC" "$out"
out=$(on "$m" "$here/bootstrap.sh" install --dry-run --signing local --no-launch --no-open 2>&1)
expect_has "install --dry-run --signing local signs with that identity" "bundle SIGN=$HC" "$out"
expect "...without creating anything" no "$([[ $out == *openssl* ]] && echo yes || echo no)"
out=$(env -i HOME="$m/home" PATH="$m/bin:/usr/bin:/bin:/usr/sbin:/sbin" make -C "$root" -n bundle 2>&1)
expect_has "make bundle signs with the local identity by default" "scripts/sign-app.sh build/Ribbon.app \"$HC\"" "$out"
out=$(env -i HOME="$m/home" PATH="$m/bin:/usr/bin:/bin:/usr/sbin:/sbin" make -C "$root" -n bundle SIGN="Other" 2>&1)
expect_has "...unless SIGN says otherwise" 'scripts/sign-app.sh build/Ribbon.app "Other"' "$out"

# A certificate that is in the keychain but not trusted (the real listing format, with its status in parentheses).
printf 'Policy: Code Signing\n  Matching identities\n  1) %s "Ribbon Local Signing" (CSSMERR_TP_NOT_TRUSTED)\n  2) %s "Ribbon Local Signing" (CSSMERR_TP_NOT_TRUSTED)\n     2 identities found\n\n  Valid identities only\n     0 valid identities found\n' "$HB" "$HC" >"$m/all.txt"
: >"$m/valid.txt"
expect "untrusted only: identity prints nothing" "" "$(signer identity)"
expect_has "untrusted only: status says it is not valid" "not valid" "$(signer status 2>&1 || true)"
out=$(signer create --dry-run 2>&1 || true)
expect_has "untrusted only: create trusts the existing certificate again" "Trusting it again" "$out"
expect "...and makes no second certificate" no "$([[ $out == *openssl* ]] && echo yes || echo no)"
out=$(signer remove --dry-run 2>&1 || true)
expect_has "remove deletes each leftover identity once (1)" "security delete-identity -Z $HB -t /fake/login.keychain-db" "$out"
expect_has "remove deletes each leftover identity once (2)" "security delete-identity -Z $HC -t /fake/login.keychain-db" "$out"
printf '  1) %s "Ribbon Local Signing" (CSSMERR_TP_CERT_EXPIRED)\n     1 identities found\n' "$HB" >"$m/all.txt"
out=$(signer create --dry-run 2>&1 || true)
expect_has "expired only: create makes a new certificate" "openssl req" "$out"
expect "keychain commands only ever ran as a dry run" no "$([[ -s $m/security.log ]] && echo yes || echo no)"

echo "update: the checkout moves to what the remote has (real git, a local remote)"
gitq() { git -c user.name=test -c user.email=test@example.com "$@"; }
origin=$work/origin.git
gitq init -q --bare -b main "$origin"
gitq clone -q "$origin" "$work/author" 2>/dev/null
echo one >"$work/author/file.txt"
gitq -C "$work/author" add file.txt
gitq -C "$work/author" commit -q -m one
gitq -C "$work/author" tag v1.0.0
gitq -C "$work/author" push -q origin main --tags 2>/dev/null
mkcheckout() { rm -rf "$work/$1"; gitq clone -q "$origin" "$work/$1" 2>/dev/null; }
exec() { echo "$*" >"$work/exec.log"; }   # update_checkout ends in exec of the new script: record it instead
ROOT=$work/user
SCRIPTS=$ROOT/scripts

mkcheckout user
echo two >"$work/author/file.txt"
gitq -C "$work/author" commit -q -am two
gitq -C "$work/author" push -q origin main 2>/dev/null
rm -f "$work/exec.log"
out=$(update_checkout 2>&1 || true)
expect "a branch checkout is fast-forwarded" "$(gitq -C "$work/author" rev-parse HEAD)" "$(gitq -C "$ROOT" rev-parse HEAD)"
expect_has "...and the update says what changed" "two" "$out"
expect_has "...and carries on with the new scripts, without pulling again" "update --no-pull --signing auto" "$(cat "$work/exec.log" 2>/dev/null || true)"
rm -f "$work/exec.log"
out=$(update_checkout 2>&1 || true)
expect_has "an up-to-date checkout says so" "Already up to date" "$out"
expect "...and re-runs nothing" no "$([[ -e $work/exec.log ]] && echo yes || echo no)"

echo local >"$ROOT/file.txt"
expect "uncommitted changes to tracked files stop the update" 1 "$( (update_checkout) >/dev/null 2>&1; echo $?)"
gitq -C "$ROOT" checkout -q -- file.txt

gitq -C "$ROOT" checkout -q -b lonely
expect "a branch without an upstream stops the update" 1 "$( (update_checkout) >/dev/null 2>&1; echo $?)"
gitq -C "$ROOT" checkout -q main

echo mine >"$ROOT/mine.txt"
gitq -C "$ROOT" add mine.txt
gitq -C "$ROOT" commit -q -m mine
echo three >"$work/author/file.txt"
gitq -C "$work/author" commit -q -am three
gitq -C "$work/author" push -q origin main 2>/dev/null
expect "a branch with commits of its own is not merged" 1 "$( (update_checkout) >/dev/null 2>&1; echo $?)"
expect "...and keeps its own commit" mine "$(gitq -C "$ROOT" log -1 --format=%s)"

mkcheckout user
gitq -C "$ROOT" checkout -q --detach v1.0.0
gitq -C "$work/author" tag v1.1.0
gitq -C "$work/author" push -q origin --tags 2>/dev/null
rm -f "$work/exec.log"
update_checkout >/dev/null 2>&1 || true
expect "a checkout on a tag moves to the newest tag" v1.1.0 "$(gitq -C "$ROOT" describe --tags --exact-match)"
gitq -C "$ROOT" checkout -q --detach HEAD~1
expect "a detached commit that is no tag stops the update" 1 "$( (update_checkout) >/dev/null 2>&1; echo $?)"
unset -f exec
ROOT=$(cd "$here/.." && pwd)
SCRIPTS=$ROOT/scripts

echo "permissions and uninstall --dry-run only print"
out=$(on "$work/clt26" "$here/bootstrap.sh" permissions screen-recording --dry-run 2>&1)
expect_has "permissions screen-recording opens the Screen Recording pane" "Privacy_ScreenCapture" "$out"
out=$(on "$work/clt26" "$here/bootstrap.sh" permissions --dry-run 2>&1)
expect_has "permissions opens the Accessibility pane by default" "Privacy_Accessibility" "$out"
expect "permissions --no-open opens nothing" no "$([[ $(on "$work/clt26" "$here/bootstrap.sh" permissions --no-open --dry-run 2>&1) == *"+ open"* ]] && echo yes || echo no)"
expect "permissions rejects an unknown pane with exit 2" 2 "$(on "$work/clt26" "$here/bootstrap.sh" permissions bogus >/dev/null 2>&1; echo $?)"
m=$work/clt26
mkdir -p "$m/home/Applications/Ribbon.app"
out=$(on "$m" "$here/bootstrap.sh" uninstall --dry-run --remove-signing 2>&1)
expect_has "uninstall --dry-run prints the removal" "+ rm -rf $m/home/Applications/Ribbon.app" "$out"
expect_has "uninstall --dry-run prints the identity removal" "local-signing.sh remove" "$out"
expect "uninstall --dry-run removed nothing" yes "$([[ -d $m/home/Applications/Ribbon.app ]] && echo yes || echo no)"

echo "permissions: an open that fails is a warning, not a failure"
m=$work/clt26
printf '#!/bin/sh\nexit 1\n' >"$m/bin/open"
chmod +x "$m/bin/open"
out=$(on "$m" "$here/bootstrap.sh" permissions 2>&1; echo "exit=$?")
expect_has "permissions exits 0 although open fails" "exit=0" "$out"
expect_has "...and says where the user opens the pane by hand" "opens System Settings > Privacy & Security > Accessibility by hand" "$out"
rm -f "$m/bin/open"

echo "rustup install goes through a private temporary folder"
out=$(on "$work/norust" "$here/bootstrap.sh" install --dry-run --install-rust --no-launch --no-open --signing adhoc 2>&1)
expect_has "the installer script is saved under a mktemp-style name" "ribbon-rustup.XXXXXX/rustup-init.sh" "$out"

echo "install, update and uninstall end to end (a fake make builds a signed fake app; nothing real is built, launched or touched)"
# mkfakeroot DIR: a checkout look-alike. The scripts are copies, so their ROOT is DIR.
mkfakeroot() {
  mkdir -p "$1/scripts" "$1/core" "$1/app"
  cp "$here/bootstrap.sh" "$here/local-signing.sh" "$1/scripts/"
  : >"$1/Makefile"
  : >"$1/core/Cargo.toml"
  : >"$1/app/Package.swift"
}
r=$work/fakeroot
mkfakeroot "$r"
m=$work/flow
fake_mac "$m" clt 26.2 MacOSX.sdk MacOSX26.sdk
fake_rust "$m" 1.99.0
fake_security "$m"
cat >"$m/bin/make" <<'FAKE'
#!/bin/sh
# Fake make for "-C ROOT bundle SIGN=X": ROOT/build/Ribbon.app, ad-hoc signed, holding $FAKE_BUILD. FAKE_FAIL=1 fails.
if [ "$FAKE_FAIL" = 1 ]; then echo "fake make: boom" >&2; exit 2; fi
app=$2/build/Ribbon.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp /usr/bin/true "$app/Contents/MacOS/Ribbon"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Ribbon</string><key>CFBundleIdentifier</key><string>com.makeautomation.ribbon</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n' >"$app/Contents/Info.plist"
echo "$FAKE_BUILD" >"$app/Contents/Resources/build.txt"
codesign --force --sign - --identifier com.makeautomation.ribbon "$app" 2>/dev/null
FAKE
chmod +x "$m/bin/make"
apps=$m/home/Applications
installed_build() { cat "$apps/Ribbon.app/Contents/Resources/build.txt" 2>/dev/null || echo none; }

out=$(on "$m" FAKE_BUILD=1 "$r/scripts/bootstrap.sh" install --no-launch --no-open --signing adhoc 2>&1; echo "exit=$?")
expect_has "the first install succeeds" "exit=0" "$out"
expect_has "...and says where Ribbon is" "Ribbon is installed at $apps/Ribbon.app" "$out"
expect_has "...warns that an ad-hoc build loses the Accessibility switch on each update" "signed ad-hoc" "$out"
expect_has "...and tells the user what to switch on" "switch Ribbon on" "$out"
expect "...installed the build" 1 "$(installed_build)"
expect "...and left no staging folder behind" "" "$(ls -A "$apps" | grep -v '^Ribbon.app$' || true)"
out=$(on "$m" FAKE_BUILD=1 "$r/scripts/bootstrap.sh" install --no-launch --no-open --signing adhoc 2>&1; echo "exit=$?")
expect_has "installing the same build again succeeds" "exit=0" "$out"
expect_has "...and sees the same signature" "Same signature" "$out"
out=$(on "$m" FAKE_BUILD=2 "$r/scripts/bootstrap.sh" install --no-launch --no-open --signing adhoc 2>&1; echo "exit=$?")
expect_has "a different build installs" "exit=0" "$out"
expect "...and replaces the old one" 2 "$(installed_build)"
expect_has "...and warns that the designated requirement changed" "designated requirement changed" "$out"
out=$(on "$m" FAKE_BUILD=3 FAKE_FAIL=1 "$r/scripts/bootstrap.sh" install --no-launch --no-open --signing adhoc 2>&1; echo "exit=$?")
expect_has "a failing build exits 1" "exit=1" "$out"
expect_has "...says so and shows the log" "the build failed" "$out"
expect_has "...with the end of the build's own output" "fake make: boom" "$out"
expect "...and leaves the installed app alone" 2 "$(installed_build)"
out=$(on "$m" FAKE_BUILD=4 "$r/scripts/bootstrap.sh" update --no-pull --no-launch --no-open --signing adhoc 2>&1; echo "exit=$?")
expect_has "update --no-pull rebuilds and reinstalls" "exit=0" "$out"
expect "...the new build" 4 "$(installed_build)"
out=$(on "$m" FAKE_BUILD=5 "$r/scripts/bootstrap.sh" build --signing adhoc 2>&1; echo "exit=$?")
expect_has "build stops at the built app" "exit=0" "$out"
expect "...and installs nothing" 4 "$(installed_build)"
expect "...but built it" 5 "$(cat "$r/build/Ribbon.app/Contents/Resources/build.txt")"

printf '#!/bin/sh\nexit 0\n' >"$m/bin/open"   # opens nothing, so no Ribbon ever shows up
chmod +x "$m/bin/open"
out=$(on "$m" FAKE_BUILD=6 RIBBON_LAUNCH_TRIES=1 "$r/scripts/bootstrap.sh" install --no-open --signing adhoc 2>&1; echo "exit=$?")
expect_has "a Ribbon that does not start is an error" "exit=1" "$out"
expect_has "...whose advice is the log, not running the binary in a terminal" "log show --last 2m --process Ribbon" "$out"
expect_has "...and says not to run the binary from a terminal" "Do not run the binary from a terminal" "$out"
rm -f "$m/bin/open"

out=$(on "$m" "$r/scripts/bootstrap.sh" uninstall 2>&1; echo "exit=$?")
expect_has "uninstall removes the app" "Removed $apps/Ribbon.app" "$out"
expect "...really" none "$(installed_build)"
expect_has "...and lists the login item among what stays" "Login Items" "$out"
expect_has "uninstalling twice is fine" "Nothing at" "$(on "$m" "$r/scripts/bootstrap.sh" uninstall 2>&1)"

# update with real git: the clone is fast-forwarded and the NEW scripts carry on
r2=$work/upd-origin
mkfakeroot "$r2"
gitq init -q -b main "$r2"
gitq -C "$r2" add -A
gitq -C "$r2" commit -q -m first
gitq clone -q "$r2" "$work/upd-user" 2>/dev/null
echo news >"$r2/NEWS"
gitq -C "$r2" add NEWS
gitq -C "$r2" commit -q -m "second: something new"
out=$(on "$m" FAKE_BUILD=7 "$work/upd-user/scripts/bootstrap.sh" update --no-launch --no-open --signing adhoc 2>&1; echo "exit=$?")
expect_has "update pulls, shows what is new and carries on" "second: something new" "$out"
expect_has "...then installs" "Ribbon is installed at $apps/Ribbon.app" "$out"
expect "...the build of the updated checkout" 7 "$(installed_build)"
expect "...whose checkout has the new commit" "second: something new" "$(gitq -C "$work/upd-user" log -1 --format=%s)"

echo "stopping the build when the script is interrupted"
rl=$work/rl
mkdir -p "$rl"
bash -c 'source "$1"; run_logged "$2" sh -c "echo \$\$ >\"$3\"; exec sleep 120"' _ "$here/bootstrap.sh" "$rl/log" "$rl/pid" >/dev/null 2>&1 &
runner=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $rl/pid ]] && break; sleep 0.3; done
child=$(cat "$rl/pid" 2>/dev/null || echo 0)
expect "the build is running" alive "$(kill -0 "$child" 2>/dev/null && echo alive || echo gone)"
kill -TERM "$runner" 2>/dev/null || true
wait "$runner" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$child" 2>/dev/null || break; sleep 0.5; done
expect "...and stops with the script that started it" gone "$(kill -0 "$child" 2>/dev/null && echo alive || echo gone)"
kill "$child" 2>/dev/null || true

echo "quitting the installed Ribbon (real processes: copies of sleep that are named Ribbon)"
probe_rc=0
pgrep -x NoSuchProcessNamedLikeThis >/dev/null 2>&1 || probe_rc=$?   # 1: listed, none matched. 3: cannot list (a sandbox)
if (( probe_rc <= 1 )); then
  pr=$work/proc
  mkdir -p "$pr/in/Ribbon.app/Contents/MacOS" "$pr/other/Ribbon.app/Contents/MacOS"
  for f in "$pr/in/Ribbon.app/Contents/MacOS/Ribbon" "$pr/other/Ribbon.app/Contents/MacOS/Ribbon"; do
    cp /bin/sleep "$f"
    codesign --force --sign - "$f" 2>/dev/null   # a copy of a system binary is killed on launch until it is re-signed
  done
  "$pr/in/Ribbon.app/Contents/MacOS/Ribbon" 120 &
  inside=$!
  "$pr/other/Ribbon.app/Contents/MacOS/Ribbon" 120 &
  outside=$!
  disown "$inside" "$outside"   # no "Terminated" job messages
  saved_dest=$APP_DEST
  APP_DEST=$pr/in/Ribbon.app
  sleep 1
  expect "installed_pids finds the Ribbon that runs from the install folder, and only that" "$inside" "$(installed_pids)"
  quit_installed >/dev/null
  expect "quit_installed stopped it" gone "$(kill -0 "$inside" 2>/dev/null && echo alive || echo gone)"
  expect "...and left a Ribbon from another folder running" alive "$(kill -0 "$outside" 2>/dev/null && echo alive || echo gone)"
  kill "$outside" 2>/dev/null || true
  APP_DEST=$saved_dest
else
  echo "  skip  this shell cannot list processes (a sandbox): installed_pids and quit_installed were not run"
fi

echo "Makefile"
mk=$work/make
mkdir -p "$mk/bin" "$mk/home" "$mk/withenv/.cargo/bin"
printf '#!/bin/sh\necho "fake cargo: $*"\n' >"$mk/bin/cargo"
chmod +x "$mk/bin/cargo"
out=$(env -i HOME="$mk/home" PATH="$mk/bin:/usr/bin:/bin:/usr/sbin:/sbin" make -C "$root" core 2>&1)
expect_has "make core works without ~/.cargo/env (Homebrew-style Rust)" "fake cargo: build --release --manifest-path core/Cargo.toml" "$out"
printf '#!/bin/sh\necho "fake rustup cargo: $*"\n' >"$mk/withenv/.cargo/bin/cargo"
chmod +x "$mk/withenv/.cargo/bin/cargo"
printf 'export PATH="%s/.cargo/bin:$PATH"\n' "$mk/withenv" >"$mk/withenv/.cargo/env"
out=$(env -i HOME="$mk/withenv" PATH="$mk/bin:/usr/bin:/bin:/usr/sbin:/sbin" make -C "$root" core 2>&1)
expect_has "make core still loads ~/.cargo/env when it exists" "fake rustup cargo: build --release" "$out"
out=$(make -C "$root" -n bundle SIGN=- 2>&1)
expect_has "make bundle SIGN=- signs ad-hoc through sign-app.sh" 'scripts/sign-app.sh build/Ribbon.app "-"' "$out"
out=$(env -i HOME="$work/kc0/home" PATH="$work/kc0/bin:/usr/bin:/bin:/usr/sbin:/sbin" make -C "$root" -n bundle 2>&1)
expect_has "make bundle without a local identity signs ad-hoc" 'scripts/sign-app.sh build/Ribbon.app "-"' "$out"
expect_has "...and says how to avoid the redo" "INSTALL.md, Signing" "$out"
out=$(make -C "$root" -n release VERSION=0.0.0 DRY=1 2>&1)
expect "make release VERSION=0.0.0 DRY=1 still calls release.sh --dry" "scripts/release.sh 0.0.0 --dry" "$out"
out=$(make -C "$root" -n assemble VERSION=1.2.3 BUILD=4 2>&1)
expect_has "make assemble (the release build) still sets the version" 'CFBundleShortVersionString 1.2.3' "$out"
expect_has "...and the app step asks bootstrap.sh for the SDK" 'scripts/bootstrap.sh sdk' "$out"

echo
echo "$count checks, $fails failed"
(( fails == 0 ))
