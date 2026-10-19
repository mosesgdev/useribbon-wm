#!/usr/bin/env bash
# Build, sign, notarize and publish-ready package a Ribbon release. See RELEASING.md.
# Usage: scripts/release.sh VERSION [--dry]      (or: make release VERSION=0.2.0 [DRY=1])
#   --dry  builds a DMG with whatever signing identity this Mac has, into build/dry/.
#          No Apple account, no network, no notarization, no appcast: it only proves the packaging.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

die() { echo "release: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

version=${1:-}
dry=0
[[ ${2:-} == --dry ]] && dry=1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $# -le 2 && ( $# -lt 2 || $dry == 1 ) ]] \
  || die "usage: scripts/release.sh VERSION [--dry], VERSION like 0.2.0"

config=${RELEASE_CONFIG:-$root/release.env}
if [[ -f $config ]]; then
  # shellcheck disable=SC1090
  source "$config"
elif (( ! dry )); then
  die "no $config. Copy release.env.example to release.env and fill it in (RELEASING.md, one-time setup)."
fi
: "${DEVELOPER_ID:=}" "${NOTARY_PROFILE:=}" "${SU_FEED_URL:=}" "${SU_PUBLIC_ED_KEY:=}"

# `has_identity NAME valid` accepts only usable certificates (not expired, trusted chain); without `valid`, any listed identity.
has_identity() { security find-identity ${2:+-v} -p codesigning | grep -qF "\"$1\""; }

# Monotonic: every commit raises it, so a later release always has the larger CFBundleVersion.
build=$(git rev-list --count HEAD)
app=build/Ribbon.app
# The edition this checkout builds (see the Makefile; `make release EDITION=...` passes its own down)
# and where SwiftPM keeps that edition's build, Sparkle's tools included.
edition=$(make -s print-EDITION)
scratch=$(make -s print-SWIFT_SCRATCH)
sparkle_bin=$scratch/artifacts/sparkle/Sparkle/bin
generate_appcast=$sparkle_bin/generate_appcast

if (( dry )); then
  out=build/dry
  if [[ -n $DEVELOPER_ID ]] && has_identity "$DEVELOPER_ID"; then identity=$DEVELOPER_ID
  elif local_id=$(scripts/local-signing.sh identity 2>/dev/null) && [[ -n $local_id ]]; then identity=$local_id
  else identity=-; fi
  # No Developer ID, so Sparkle's differently-signed code would fail library validation if run: skip the runtime flag.
  sign_opts=(--timestamp=none)
  echo "dry run: signing with '$identity', output in $out/ (never ship this)"
else
  out=releases
  identity=$DEVELOPER_ID
  sign_opts=(--options runtime --timestamp)
  step "Checking the setup"
  [[ -n $DEVELOPER_ID ]] || die "DEVELOPER_ID is empty in $config (RELEASING.md, step 2: Developer ID certificate)."
  [[ $DEVELOPER_ID == "Developer ID Application:"* ]] || die "DEVELOPER_ID must be a 'Developer ID Application: ...' certificate, not '$DEVELOPER_ID' (RELEASING.md, step 2)."
  has_identity "$DEVELOPER_ID" valid || die "no signing identity '$DEVELOPER_ID' in your keychain (RELEASING.md, step 2: Developer ID certificate; it must be listed by 'security find-identity -v -p codesigning')."
  [[ -n $NOTARY_PROFILE ]] || die "NOTARY_PROFILE is empty in $config (RELEASING.md, step 3: notarytool store-credentials)."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool cannot use the keychain profile '$NOTARY_PROFILE', or Apple is unreachable (RELEASING.md, step 3: notarytool store-credentials)."
  [[ $SU_FEED_URL == https://* ]] || die "SU_FEED_URL in $config must be an https:// URL (RELEASING.md, step 5)."
  [[ -n $SU_PUBLIC_ED_KEY ]] || die "SU_PUBLIC_ED_KEY is empty in $config (RELEASING.md, step 4)."
  [[ -z $(git status --porcelain) ]] || die "uncommitted or untracked files: a release is built from a clean, committed tree."
  [[ ! -e $out/Ribbon-$version.dmg ]] || die "$out/Ribbon-$version.dmg already exists: it is a finished release. Pick a new VERSION."
  (cd app && swift package --scratch-path "$root/$scratch" resolve)
  [[ -x $generate_appcast ]] || die "Sparkle's generate_appcast is missing from $scratch/artifacts: run 'cd app && swift package --scratch-path ../$scratch resolve'."
  # One check covers a missing private key, a typo, the example placeholder and a key that is not the one in the keychain:
  # generate_appcast would only warn about those and write an unsigned entry that no installed copy accepts.
  keychain_key=$("$sparkle_bin/generate_keys" -p) || die "no Sparkle signing key in your keychain (RELEASING.md, step 4)."
  [[ $keychain_key == "$SU_PUBLIC_ED_KEY" ]] || die "SU_PUBLIC_ED_KEY in $config is not the public key of the Sparkle key in your keychain (RELEASING.md, step 4)."
fi
dmg=$out/Ribbon-$version.dmg
mkdir -p "$out"
work=$(mktemp -d)   # scratch space outside $out, which generate_appcast scans
trap 'rm -rf "$work"' EXIT

step "Building $version (build $build, $edition edition)"
if (( dry )); then SU_FEED_URL= SU_PUBLIC_ED_KEY=; fi   # a dry bundle never carries an updater
make assemble VERSION="$version" BUILD="$build" FEED_URL="$SU_FEED_URL" ED_KEY="$SU_PUBLIC_ED_KEY"

step "Signing inside-out"
scripts/sign-app.sh "$app" "$identity" "${sign_opts[@]}"
codesign --verify --strict --deep --verbose=2 "$app"
if (( ! dry )); then
  # The runtime flag and the secure timestamp are what notarization rejects when missing.
  for code in "$app" "$app/Contents/Frameworks/Sparkle.framework"; do
    details=$(codesign -dvv "$code" 2>&1)
    grep -q "flags=.*runtime" <<<"$details" || die "$code is not signed with the hardened runtime."
    grep -q "^Timestamp=" <<<"$details" || die "$code has no secure timestamp (is the Mac online?)."
  done
fi

# The signed bundle must still start: dyld has to accept the embedded, re-signed Sparkle. (--selftest never starts the updater.)
"$app/Contents/MacOS/Ribbon" --selftest

# Notarize `file`, which must come back Accepted; the full log names the cause otherwise.
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m 2>&1 | tee "$work/notary.log" || true
  grep -q "status: Accepted" "$work/notary.log" \
    || die "notarization of $1 was not accepted. Read why with: xcrun notarytool log <the id above> --keychain-profile $NOTARY_PROFILE"
}

if (( ! dry )); then
  step "Notarizing the app"
  ditto -c -k --keepParent "$app" "$work/Ribbon.zip"
  notarize "$work/Ribbon.zip"
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

step "Building the DMG"
stage=$work/dmg
mkdir "$stage"
ditto "$app" "$stage/Ribbon.app"
ln -s /Applications "$stage/Applications"
# Built in $work and moved to $out only when done, so a failed run leaves nothing in the folder generate_appcast scans.
wip=$work/Ribbon-$version.dmg
hdiutil create -volname Ribbon -srcfolder "$stage" -format UDZO -ov "$wip"
codesign --force --sign "$identity" "${sign_opts[@]}" "$wip"
codesign --verify --strict --verbose=2 "$wip"

if (( dry )); then
  rm -f "$dmg"; mv "$wip" "$dmg"
  echo; echo "dry run done: $dmg (signed with '$identity', not notarized)"
  exit 0
fi

step "Notarizing the DMG"
notarize "$wip"
xcrun stapler staple "$wip"
spctl --assess --type open --context context:primary-signature --verbose=2 "$wip"
mv "$wip" "$dmg"

step "Updating the appcast"
prefix=${DOWNLOAD_URL_PREFIX:-${SU_FEED_URL%/*}/}
"$generate_appcast" --download-url-prefix "$prefix" "$out"

echo
echo "Released $version: upload every new file in $out/ (the DMG, any .delta, the notes) to $prefix, then $out/${SU_FEED_URL##*/} last. Not old_updates/ (RELEASING.md, per-release step 5)."
