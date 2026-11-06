# OurCard — own AirCard-like tool for iOS 27

A sideloaded iOS app that reuses the AirTraffic sandbox-escape primitive
(prebuilt `AirliftFFI` Rust core, copied from the AirCard-iOS reference fork)
to do two things on iOS 27:

1. **Flash `.tendies` wallpapers** into PosterBoard (descriptor inject +
   refresh flags), with an opt-in SQLite registration path that fixes
   AirCard's "wallpaper doesn't appear in the gallery" bug.
2. **Re-skin Apple Wallet card artwork** (background art only).
3. **Build a custom Wallet pass (.pkpass) styled like a card** from your own
   art + text, and inject it into `/var/mobile/Library/Passes/` — visual
   only, experimental (see §4).

Everything privileged runs **on-device**. There is no server component.

## Architecture

```
┌─ OurCard (SwiftUI, this repo)
│   ├─ Exploit/AirliftBridge.swift   Swift wrapper over the al_* C FFI
│   ├─ Exploit/PairingManager.swift  Bonjour + PIN Developer-Mode pairing
│   ├─ Exploit/GrappaHelper.{h,m}    AirTraffic auth token (from AirCard)
│   ├─ Wallpaper/
│   │   ├─ TendiesImporter.swift     .tendies(zip) → descriptor folders
│   │   ├─ DescriptorInjector.swift  fresh UUIDs + plist ID randomization + inject
│   │   └─ PosterBoardDB.swift       Nugget SQLite recipe behind a fail-safe seam
│   ├─ Card/CardSkinEngine.swift     multi-res skins, manual ID + syslog discovery
│   ├─ Pass/PassBuilder.swift        unsigned .pkpass bundle builder + injector
│   └─ Respring/NeoSpring.swift      WebKit respring (credited)
└─ rust-core/                         Rust FFI source — CI builds AirliftFFI.xcframework from this
   (the 127 MB prebuilt xcframework is NOT committed; GitHub blocks files over 100 MB)
```

### How the exploit works (short version)

1. The app runs an RPPairing host and advertises it over Bonjour as
   `_remotepairing-pairable-host._tcp.`. The user confirms the shown PIN in
   Settings › Privacy & Security › Developer Mode.
2. A loopback VPN (LocalDevVPN/WireGuard, **10.7.0.1** — not 127.0.0.1) lets
   the phone reach its own RSD/lockdown services.
3. The Rust core stages a StreamingZip archive containing a **symlink** plus
   payload, writes a forged `Books/Sync/Books.plist` via AFC, then speaks
   `com.apple.atc` (with an authentic Grappa token) so `atairlockd` moves the
   files to **arbitrary absolute paths**.
4. The primitive is **write-only**: it cannot read anything back. All
   read-then-modify flows (notably the PosterBoard SQLite DB) must get their
   "before" image from somewhere else — see below.

## Build

Free GitHub Actions macOS runner → unsigned IPA → install with Sideloadly:

1. Push this repo to GitHub (public repos get free macOS minutes).
2. Actions tab → "Build unsigned IPA" → Run workflow (or push to `main`).
3. Download the `OurCard-unsigned-ipa` artifact.
4. Sideload `OurCard-unsigned.ipa` with Sideloadly (needs the Apple Devices
   app from the Microsoft Store for USB drivers on Windows).

Local build (Mac with Xcode): open `OurCard.xcodeproj` and build with
`CODE_SIGNING_ALLOWED=NO` for an unsigned product.

> Change `PRODUCT_BUNDLE_IDENTIFIER` (`com.ourcard.ourcard`) before
> distributing your own builds.

## Usage

1. Start a loopback VPN on the iPhone (10.7.0.1).
2. Open OurCard → **Pair with this iPhone** → confirm the PIN in
   Settings › Privacy & Security › Developer Mode.
3. **Wallpapers**: import a `.tendies` file → Flash → Respring.
   - Without a database: descriptors are injected and PosterBoard refresh
     flags are written (same as AirCard). The wallpaper may need manual
     selection in Settings › Wallpaper.
   - With a database (advanced): import
     `PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3` pulled from a **backup
     of THIS device** (the Windows Studio companion does this), tick "Allow
     PosterBoard DB overwrite", and confirm. The app applies Nugget's exact
     insert recipe to a copy and writes the whole DB back. **A corrupt DB
     breaks the wallpaper gallery until you restore from backup.**
4. **Card skins**: paste a card ID (or Scan while bringing up Apple Pay),
   choose artwork, Flash, force-close Wallet.
   - Appearance only: name, network marks, balances, and payments are
     system-controlled. You cannot add a card to the Apple Pay pay sheet —
     that requires bank tokenization and is out of scope by design.
5. **Custom pass card**: pick art, type a title + name, Build & install pass.
   - The pass is UNSIGNED (no Pass Type ID certificate) and has no balance,
     barcode, or payment data. It shows in the Wallet pass list at best —
     never in the Apple Pay pay sheet, and it can't pay.
   - Install is experimental: the bundle is injected into
     `/var/mobile/Library/Passes/`, but pass registration with passd is
     unverified — the pass may not appear even if the files land. Reboot
     after installing and check Wallet. Your test iPhone decides.

## Build (CI builds the exploit core from source)

The repo does NOT contain the 127 MB prebuilt `AirliftFFI.xcframework`
(GitHub blocks files over 100 MB). CI builds it from `rust-core/` on the
Mac runner (`build-xcframework.sh`) before compiling the app, so a plain
push is enough. Locally, run `./build-xcframework.sh` once on a Mac if you
don't already have the prebuilt copy.

## What's real vs. what needs the Mac run

| Item | Status |
|---|---|
| Swift sources (all modules) | Written, complete, no placeholder bodies in the critical path |
| Pass module (PassBuilder + UI) | Written; bundle follows Apple's .pkpass spec (pass.json + images + SHA1 manifest), unsigned |
| Pass registration with passd | **UNVERIFIED** — the pass may not appear in Wallet even if the files inject; test iPhone decides |
| `AirliftFFI.xcframework` | Built in CI from `rust-core/` (3.1 MB source); prebuilt 127 MB copy NOT in git |
| `GrappaHelper.{h,m}` | Copied verbatim from the AirCard reference |
| `OurCard.xcodeproj` | Regenerated; Pass module included (15 files) |
| FFI names in `AirliftBridge.swift` | Match `airlift.h` exactly (verified by grep) |
| Compilation | **Needs the GitHub Actions Mac run** — no Xcode on this machine |
| On-device behavior (pairing, inject, respring) | **Unverified** — needs a real iPhone on iOS 27 |

## Risks

- The exploit writes outside the sandbox. A wrong absolute path can damage
  system data. The wallpaper/card paths used here are the same ones AirCard
  ships.
- NeoSpring respring is a WebKit crash — it restarts SpringBoard; unsaved
  app state is lost. Reboot always recovers.
- Apple can patch the underlying primitive in any iOS update; this targets
  iOS 27.x as of October 2026.
- Cosmetic-only by design: no PAN/tokenization/provisioning code exists in
  this repo and none should be added.
