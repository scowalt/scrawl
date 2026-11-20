# Releasing Scrawl Remote (this fork)

Scrawl Remote ships from `main` of `scowalt/scrawl`, with no manual steps:

```text
push to main ─► Check (macOS + Windows) ─► Release (Scrawl Remote) ─► GitHub release remote-v<version>-remote.<n>
                                                                        ├─ Scrawl-Remote-<version>.zip
                                                                        └─ appcast.xml
installed app ─► Sparkle reads releases/latest/download/appcast.xml hourly ─► downloads, installs, relaunches
```

- **Release workflow:** `.github/workflows/release-fork.yml` runs after `Check` passes on a push to `main`
  (or by hand: `gh workflow run release-fork.yml`). It builds `--release`, assembles and signs the app
  with `scripts/assemble-app.sh` (the same script `install-app.sh` uses), zips it, writes an appcast
  with Sparkle's `generate_appcast`, and publishes a release marked latest.
- **Versions:** `CFBundleVersion` is the workflow's run number, which Sparkle compares.
  `CFBundleShortVersionString` is upstream's `Cargo.toml` version plus `-remote.<n>`. Local builds
  from `install-app.sh` are build 0 and carry no updater, so they never update themselves.
- **Installing on a Mac:** `scripts/install-release.sh` downloads the latest release, checks its
  signature against the release certificate, and replaces `~/Applications/Scrawl Remote.app`.
  Updates then install by themselves: when Sparkle has one downloaded, `sparkle::install_pending_update`
  installs it at once, or as soon as no capture is recording or being built.

## Keys

Both live in `~/.config/scrawl-remote/signing/` (mode `0600`) on Scott's MacBook and in the repo's
Actions secrets. Losing either one means making a new one and re-granting or reinstalling.

| Secret | Local file | What it does |
|---|---|---|
| `SCRAWL_SIGNING_P12` (base64) and `SCRAWL_SIGNING_P12_PASSWORD` | `identity.p12`, `identity-password` | The self-signed "Scrawl Remote Signing" certificate. macOS ties Screen Recording, Microphone and Accessibility to `identifier "com.scowalt.scrawl-remote" and certificate leaf = H"86a7…fe29"`, so every build signed with it keeps the grants. Sparkle also requires an update to be signed like the installed app. |
| `SPARKLE_ED_PRIVATE_KEY` | `sparkle-ed25519.key` | Signs each appcast entry; the app checks it against `SUPublicEDKey` in `scripts/assemble-app.sh`. |

`scripts/signing-identity.sh` makes the certificate once locally, or imports it from the secrets in
CI, into a keychain of its own that never prompts.

## Keeping up with upstream

The bb automation "Sync scrawl fork with upstream" (project scrawl, on beegent, daily) rebases the
fork's commits onto `kitlangton/scrawl` `main`, proves the result on CI through a `sync/upstream`
branch, and only then moves `main`, which releases it. A run that needed a decision stays unarchived
in bb.
