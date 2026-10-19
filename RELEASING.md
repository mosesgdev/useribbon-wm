# Releasing Ribbon

Ribbon ships outside the App Store as a Developer ID-signed, notarized DMG. Installed copies update
themselves through [Sparkle 2](https://sparkle-project.org). macOS 26 and later only.

`make release VERSION=0.2.0` does the whole build: it signs, notarizes, staples, makes the DMG and
refreshes the appcast. You do the one-time setup below first.

## One-time setup

1. **Apple Developer Program.** Join at developer.apple.com/programs (paid, yearly).
2. **Developer ID Application certificate.** Xcode → Settings → Accounts → your team → Manage
   Certificates → **+** → *Developer ID Application*. Check it with
   `security find-identity -v -p codesigning`: a line like
   `"Developer ID Application: Your Name (TEAMID1234)"` must be there. That whole quoted name is `DEVELOPER_ID`.
3. **Notary credentials.** Create an app-specific password at account.apple.com (Sign-In and Security),
   then store it once in the keychain (it prompts for the password):
   `xcrun notarytool store-credentials ribbon-notary --apple-id you@example.com --team-id TEAMID1234`.
   `ribbon-notary` is the `NOTARY_PROFILE`.
4. **Sparkle signing key.** After any build (or `make release VERSION=0.0.0 DRY=1`), run
   `$(make -s print-SWIFT_SCRATCH)/artifacts/sparkle/Sparkle/bin/generate_keys` (`app/.build/plus/artifacts/...` for the Plus edition). It keeps the private key in your login
   keychain and prints the public key: that is `SU_PUBLIC_ED_KEY`. Back the private key up
   (`generate_keys -x ~/ribbon-sparkle.key`, then keep the file somewhere safe, outside the repo).
   Without it you can never ship an update that installed copies accept.
5. **Where the feed lives.** Pick a static HTTPS folder you control and keep it for good, since it is built into
   every release: `https://example.com/ribbon/appcast.xml` is `SU_FEED_URL`, and the DMGs go in the same folder.
6. **The config file.** `cp release.env.example release.env` and fill in the four values. It is untracked.

`make release` stops early, naming the step above, if the identity, notary profile, feed URL or
public key is missing, or if `SU_PUBLIC_ED_KEY` is not the public key of the Sparkle key in your keychain.

## Each release

1. Commit everything. A release is built from a clean tree.
2. Optional: write release notes as `releases/Ribbon-0.2.0.html` (or `.md`); the appcast picks them up by file name.
3. Practice run, no Apple account or network needed: `make release VERSION=0.2.0 DRY=1`. It builds
   `build/dry/Ribbon-0.2.0.dmg`, signed with whatever identity this Mac has and not notarized. Never ship it.
4. `make release VERSION=0.2.0`. Takes a few minutes: it notarizes twice (app, then DMG). The first time
   `generate_keys` (the key check at the start) and `generate_appcast` run, macOS asks to let each use the
   Sparkle key in your keychain: allow. It also runs the signed app with `--selftest` before notarizing.
5. Upload every new file in `releases/` to the feed folder: `Ribbon-0.2.0.dmg`, the `.delta` files (from the
   second release on) and the notes file, which `generate_appcast` may have edited. Not `old_updates/`.
   Upload `appcast.xml` last, so no one is offered a file that is not there yet.
6. `git tag v0.2.0`.

The DMG in `releases/` is the download for new users. `releases/` is not tracked by git: keep it, because
`generate_appcast` builds the next appcast from the DMGs it finds there (and makes small delta updates from them).

## Notes

- **Versions.** `VERSION` becomes the version people see. The build number (`CFBundleVersion`, what Sparkle
  compares) is the git commit count, so it only goes up while you release from the same history.
- **Dev builds never update.** `make bundle` and `make install` carry no feed URL or key, so the updater
  does not start and the menu item is hidden. In a release build a scheduled check that finds an
  update does not pop a window behind other apps: the menu shows "Update available…" and a dot beside the desktop number. Only `make release` sets them. A copy installed from a dev
  build has no updater: install the first Developer ID DMG by hand once.
- **Accessibility survives updates.** macOS ties the Accessibility grant to the app's signing identity
  (Developer ID team plus bundle id), not its exact bytes, so updates keep it. Switching from a dev-signed
  build to the first Developer ID build asks once more.
- **Signing.** `scripts/sign-app.sh` signs inside-out: Sparkle's `Autoupdate` and `Updater.app`, then the
  framework, then Ribbon, all with the hardened runtime and a secure timestamp, never `--deep`. Ribbon is
  not sandboxed, so the bundle drops Sparkle's XPC services and headers. No entitlements are needed.
- **A rejected notarization.** The script prints the submission id; read the reason with
  `xcrun notarytool log <id> --keychain-profile ribbon-notary`.
- **Sparkle version.** Pinned exactly in `app/Package.swift`. To move it: change the version, run
  `cd app && swift package resolve`, commit `app/Package.resolved`.
