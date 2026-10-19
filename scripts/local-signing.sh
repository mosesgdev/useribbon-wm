#!/bin/bash
# A stable code-signing identity for building Ribbon yourself. See INSTALL.md, "Signing".
#
# Why: an ad-hoc signature is only a hash of the app, so macOS sees every rebuild as a different app and the
# Accessibility switch has to be redone after each update. A self-signed certificate keeps the app's designated
# requirement (bundle id + this certificate) the same across rebuilds, so the grant survives updates.
# The certificate lives only in your login keychain and is trusted for code signing only. It never leaves this Mac.
#
# Usage: scripts/local-signing.sh COMMAND [--dry-run]
#   identity      print the SHA-1 of the valid identity, or nothing. Read-only and silent; the Makefile calls it.
#   valid SHA1    exit 0 if SHA1 is a valid code-signing identity in your keychains. Read-only.
#   status        say whether the identity exists and is usable. Read-only.
#   describe APP  print how APP is signed: unsigned | adhoc | certificate SHA1 | other. Read-only.
#   create        create the identity if it does not exist (otherwise reuse it), trust it for code signing and prove
#                 that it can sign. macOS shows ONE trust dialog (password or Touch ID) that only you can answer, and
#                 may show a keychain-access prompt the first time codesign uses the key. Never type those for anyone.
#   verify APP    check that APP's designated requirement names this certificate and is not ad-hoc.
#   remove        delete the identity and its trust setting from your login keychain.
#   --dry-run     print every command that changes something instead of running it.
#
# Exit status: 0 done, 1 failed, 2 usage, 3 the user has to do something and then re-run.
set -euo pipefail

NAME="Ribbon Local Signing"
DRY=0

say() { printf '%s\n' "$*"; }
warn() { printf 'local-signing: warning: %s\n' "$*" >&2; }
die() { printf 'local-signing: error: %s\n' "$*" >&2; exit 1; }
need_user() { printf 'local-signing: waiting for you: %s\n' "$*" >&2; exit 3; }

# Print a command that changes something, and run it unless this is a dry run.
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( DRY )); then return 0; fi
  "$@"
}

# "SHA1 NAME" for every valid code-signing identity (valid = trusted chain, not expired).
identities_valid() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9][0-9]*) \([0-9A-Fa-f]\{40\}\) "\(.*\)".*$/\1 \2/p'
}

# SHA-1 of the first valid identity named exactly $NAME, or nothing.
local_sha1() {
  identities_valid | awk -v n="$NAME" '{ h = $1; sub(/^[^ ]+ /, ""); if ($0 == n) { print h; exit } }'
}

# SHA-1 of every identity named $NAME, valid or not, once each (an untrusted or expired one is listed without -v).
# With "unexpired" the expired ones are left out: trusting those again would not make them usable.
all_local_sha1() {
  security find-identity -p codesigning 2>/dev/null \
    | { if [[ ${1:-} == unexpired ]]; then grep -v 'EXPIRED' || true; else cat; fi; } \
    | sed -n 's/^ *[0-9][0-9]*) \([0-9A-Fa-f]\{40\}\) "\(.*\)".*$/\1 \2/p' \
    | awk -v n="$NAME" '{ h = $1; sub(/^[^ ]+ /, ""); if ($0 == n) print h }' | sort -u
}

login_keychain() {
  security login-keychain 2>/dev/null | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//'
}

# How an app is signed, from its designated requirement: an ad-hoc signature has a cdhash-only one, which changes
# with every build; a certificate signature names the certificate leaf, which stays the same.
describe_app() {
  local app=$1 dr
  # The line reads "designated => ..."; some macOS versions print it as a comment, "# designated => ...".
  dr=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^[# ]*designated => //p' | head -1 || true)
  case $dr in
    '') say unsigned ;;
    'cdhash H"'*) say adhoc ;;
    *'certificate leaf = H"'*)
      say "certificate $(printf '%s\n' "$dr" | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p' | tr 'a-f' 'A-F')" ;;
    *) say other ;;
  esac
}

# Sign a scratch copy of a system binary with the identity: proves codesign may use the key and that the
# result has a certificate-based designated requirement. The first use of the key is where macOS may ask for access.
probe_signing() {
  local sha=$1 work kind
  work=$(mktemp -d "${TMPDIR:-/tmp}/ribbon-probe.XXXXXX")
  cp /usr/bin/true "$work/probe"
  if ! codesign --force --sign "$sha" --identifier com.makeautomation.ribbon.probe "$work/probe" 2>"$work/err"; then
    cat "$work/err" >&2; rm -rf "$work"
    warn "errSecInternalComponent means macOS wants the user to allow codesign to use the key (a keychain prompt, answered with Always Allow) and cannot show it here: run this in the user's own desktop session, not over ssh, and unlock the login keychain."
    return 1
  fi
  kind=$(describe_app "$work/probe")
  rm -rf "$work"
  [[ $kind == "certificate "* ]] || { warn "a test signature came out as '$kind', not a certificate signature"; return 1; }
}

cmd_identity() { local_sha1 || true; }

cmd_valid() {
  local want=${1:-}
  [[ $want =~ ^[0-9A-Fa-f]{40}$ ]] || return 1
  identities_valid | tr 'a-f' 'A-F' | awk -v h="$(printf '%s' "$want" | tr 'a-f' 'A-F')" '$1 == h { f = 1 } END { exit !f }'
}

cmd_status() {
  local sha any
  sha=$(local_sha1 || true)
  if [[ -n $sha ]]; then
    say "'$NAME' is present and valid: $sha"
    return 0
  fi
  any=$(all_local_sha1 | head -1 || true)
  if [[ -n $any ]]; then
    say "'$NAME' exists ($any) but is not valid: not trusted for code signing, or expired. 'create' repairs it."
  else
    say "'$NAME' does not exist. 'create' makes it."
  fi
  return 1
}

cmd_describe() {
  [[ -e ${1:-} ]] || die "usage: local-signing.sh describe APP"
  describe_app "$1"
}

cmd_verify() {
  local app=${1:-} sha kind
  [[ -e $app ]] || die "usage: local-signing.sh verify APP"
  sha=$(local_sha1 || true)
  kind=$(describe_app "$app")
  case $kind in
    adhoc) die "$app is signed ad-hoc: its designated requirement is a cdhash that changes with every build." ;;
    unsigned|other) die "$app has no certificate-based designated requirement ($kind)." ;;
  esac
  if [[ -n $sha && ${kind#certificate } != "$sha" ]]; then
    die "$app is signed with certificate ${kind#certificate }, not with '$NAME' ($sha)."
  fi
  say "$app: designated requirement names the certificate ${kind#certificate }"
}

cmd_create() {
  local sha kc work pass openssl legacy any
  sha=$(local_sha1 || true)
  if [[ -n $sha ]]; then
    say "Reusing the existing identity '$NAME' ($sha)."
    (( DRY )) || probe_signing "$sha" || die "'$NAME' exists but codesign cannot use it. If macOS asked for keychain access, choose Always Allow; otherwise run 'local-signing.sh remove' and 'create' again."
    return 0
  fi

  kc=$(login_keychain)
  [[ -n $kc ]] || die "cannot find your login keychain ('security login-keychain' printed nothing)."

  # A leftover certificate that is only untrusted needs the trust step again, not a second certificate.
  any=$(all_local_sha1 unexpired | head -1 || true)
  if (( ! DRY )); then
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/ribbon-signing.XXXXXX")
    trap "rm -rf '$work'" EXIT   # expanded now: the key material must go even when the function has returned
  else
    work=/tmp/ribbon-signing.XXXXXX
  fi

  if [[ -n $any ]]; then
    say "'$NAME' is already in your keychain ($any) but is not trusted for code signing. Trusting it again."
    if (( ! DRY )); then security find-certificate -c "$NAME" -p "$kc" >"$work/cert.pem"; fi
  else
    openssl=/usr/bin/openssl
    [[ -x $openssl ]] || openssl=$(command -v openssl || true)
    [[ -n $openssl ]] || die "openssl not found (it ships with macOS as /usr/bin/openssl)."
    # macOS's LibreSSL writes a PKCS#12 file that 'security import' reads; OpenSSL 3 needs -legacy for that.
    legacy=()
    if "$openssl" version 2>/dev/null | grep -q '^OpenSSL 3'; then legacy=(-legacy); fi
    say "Creating the code-signing certificate '$NAME' (self-signed, 10 years, usable for code signing only)."
    if (( ! DRY )); then
      cat >"$work/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
default_md = sha256
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
      pass=$("$openssl" rand -hex 16)
    fi
    run "$openssl" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -config "$work/openssl.cnf" \
      -keyout "$work/key.pem" -out "$work/cert.pem" || die "openssl could not create the certificate."
    # A throwaway password protects the file for a moment. It reaches openssl through the environment and is never printed.
    ( export RIBBON_P12_PASS=${pass:-}
      run "$openssl" pkcs12 -export ${legacy[@]+"${legacy[@]}"} -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
        -out "$work/identity.p12" -passout env:RIBBON_P12_PASS ) || die "openssl could not package the certificate."
    printf '+ security import %s -k %s -P <throwaway password> -T /usr/bin/codesign\n' "$work/identity.p12" "$kc"
    if (( ! DRY )); then
      security import "$work/identity.p12" -k "$kc" -P "$pass" -T /usr/bin/codesign \
        || die "'security import' failed. The login keychain may be locked, or this shell cannot reach the user's desktop session (as over ssh): run it from the user's own session."
      rm -f "$work/key.pem" "$work/identity.p12"
    fi
  fi

  say
  say "macOS will now ask you to confirm the trust setting for '$NAME' (a password or Touch ID dialog)."
  say "Only the user can answer it. Nobody else should type the password."
  run security add-trusted-cert -r trustRoot -p codeSign -k "$kc" "$work/cert.pem" \
    || need_user "the trust setting was not applied (dialog cancelled, or this shell cannot show one, as over ssh). Run 'scripts/local-signing.sh create' again in the user's own session and have the user answer the dialog."

  if (( DRY )); then say "(dry run) next: prove that codesign can use the identity."; return 0; fi
  sha=$(local_sha1 || true)
  [[ -n $sha ]] || need_user "'$NAME' is not a valid code-signing identity yet. Run 'scripts/local-signing.sh create' again and answer the trust dialog."
  say "Testing a signature with it. If macOS asks whether codesign may use the key, the user chooses Always Allow."
  probe_signing "$sha" || die "codesign cannot sign with '$NAME' ($sha)."
  say "Ready: '$NAME' ($sha) signs with a stable certificate-based designated requirement."
}

cmd_remove() {
  local kc sha shas
  kc=$(login_keychain)
  shas=$(all_local_sha1 || true)
  if [[ -z $shas ]]; then say "No '$NAME' identity to remove."; return 0; fi
  for sha in $shas; do
    run security delete-identity -Z "$sha" -t ${kc:+"$kc"} || die "could not delete $sha."
  done
  say "Removed '$NAME'. Apps already signed with it keep working; the next build is signed differently."
}

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

main() {
  local cmd= arg=
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) DRY=1 ;;
      -h|--help) cmd=help ;;
      -*) usage >&2; exit 2 ;;
      *) if [[ -z $cmd ]]; then cmd=$1; else arg=$1; fi ;;
    esac
    shift
  done
  case $cmd in
    identity) cmd_identity ;;
    valid) cmd_valid "$arg" ;;
    status) cmd_status ;;
    describe) cmd_describe "$arg" ;;
    create) cmd_create ;;
    verify) cmd_verify "$arg" ;;
    remove) cmd_remove ;;
    help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
