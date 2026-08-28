# macOS App Maintenance Scripts for Microsoft Intune

A set of self-contained **detect-and-patch** shell scripts that keep common third-party
macOS apps up to date on managed Macs. Each script resolves the latest vendor version,
compares it to what's installed, and silently downloads + installs the update — verifying
the publisher's code signature before anything runs as root.

They are designed to be deployed as **Intune → Devices → macOS → Shell scripts**, but work
equally well from any MDM, Jamf policy, or a `launchd` job.

---

## Contents

| Script | App | Version source | Installer type | Signed-by check |
|---|---|---|---|---|
| `macOS-Maintain-MicrosoftEdge.sh` | Microsoft Edge | `edgeupdates.microsoft.com` API | `.pkg` | Team ID `UBF8T346G9` |
| `macOS-chrome-detect_patch.sh` | Google Chrome | `chromiumdash.appspot.com` API | `.app` in `.dmg` | Team ID `EQHXZ8M8AV` |
| `macOS-Maintain-VLC.sh` | VLC | VideoLAN Sparkle appcast | `.app` in `.dmg` | Team ID `75GAHG3SZQ` |
| `macOS-flameshot-detect_patch.sh` | Flameshot | GitHub Releases API | `.app` in `.dmg` | GitHub SHA-256 + `codesign` |
| `macOS-Maintain-PolyLens.sh` | Poly Lens / HP Poly Studio | Poly GraphQL API | `.pkg` in `.dmg` | Team ID `WJCM3F7AQ4` |
| `macOS-deepLdesktop-detect_patch.sh` | DeepL | DeepL versioned index | `.app` in `.dmg` | Team ID `4N8BGCG336` |
| `macOS-Maintain-LogiOptionsPlus.sh` | Logi Options+ | ETag / Content-Length* | `.app` installer in `.zip` | Team ID `QED4VVPZWA` |
| `macOS-parallelsdesktop-detect_patch.sh` | Parallels Desktop | `update.parallels.com` feed | `inittool` from `.dmg` | Team ID `4C6364ACXT` |
| `macOS-Maintain-AdobeReader.sh` | Adobe Acrobat Reader | Adobe RDC products API | `.pkg` in `.dmg` | Team ID `JQ525L2MZD` |
| `macOS-Maintain-AngryIPScanner.sh` | Angry IP Scanner | GitHub Releases API | `.app` in `.zip` | Unsigned (De-quarantine only) |
| `macOS-Maintain-Figma.sh` | Figma | Figma Release API | `.app` in `.zip` | Team ID `T8RA8NE3B7` |
| `macOS-Maintain-OBSStudio.sh` | OBS Studio | GitHub Releases API | `.app` in `.dmg` | Team ID `2MMRE5MTB8` |
| `macOS-Maintain-AdobeCreativeCloud.sh` | Adobe Creative Cloud | Adobe ccdConfig XML | `Install.app` in `.dmg` | Team ID `JQ525L2MZD` |

\* Logi Options+ has no reliable public version endpoint, so it uses HTTP ETag/Content-Length
change detection instead of a version comparison. See [Per-app notes](#per-app-notes).

---

## How a script works

Every script follows the same lifecycle:

1. **Resolve the latest version** from the vendor's official API/feed (never by scraping a
   redirect — see [Design notes](#design-notes)).
2. **Compare** against the installed version (read from the app's `Info.plist`, or from a
   local tracker plist where the app's own version isn't directly comparable).
3. **Defer** if the app (or a dependent background agent / VM) is actively running, to avoid
   closing user windows or corrupting data. Deferral exits `0` so the device stays compliant
   and re-evaluates on the next run.
4. **Download** the installer with retries and timeouts.
5. **Verify the code signature / Team ID** (or a published SHA-256 for Flameshot). A mismatch
   aborts the install — the script *fails closed*.
6. **Install** via the appropriate native mechanism (`installer -pkg`, mount-and-copy, or the
   vendor's own installer binary).
7. **Record** the installed version (where a tracker plist is used) and **clean up** scratch
   files.

### Exit codes

| Code | Meaning | Intune result |
|---|---|---|
| `0` | Up to date, deferred (app running), unreachable vendor, or successful install | **Success** |
| `1` | Fatal error: download failed, signature mismatch, mount failed, installer error | **Failed** (retried) |

Deferrals and "vendor unreachable" return `0` on purpose so a transient condition doesn't
flag the device red; the next scheduled run re-evaluates.

---

## Deploying in Intune

1. **Intune admin center** → **Devices** → **macOS** → **Shell scripts** → **Add**.
2. Upload one script per app.
3. Configure:
   - **Run script as signed-in user:** **No** — these need root to write to `/Applications`
     and run `installer`/`codesign`.
   - **Hide script notifications:** as you prefer.
   - **Script frequency:** pick a real cadence (e.g. **Every 1 day** or **Every 1 week**).
     > ⚠️ If frequency is left at **Not configured**, the script runs **once per device, ever** —
     > there is no ongoing patching. Set a recurring frequency for maintenance use.
   - **Max number of times to retry if script fails:** **3**.
4. Assign to the target device group.

The Intune agent runs scripts from
`/Library/Application Support/Microsoft/Intune/IntuneMdmAgent.app/...` and logs to
`/Library/Logs/Microsoft/Intune/`.

### Requirements

- macOS 11+ with the Intune MDM agent (or any runner executing the script as root).
- Standard system tools only: `curl`, `hdiutil`, `installer`, `pkgutil`, `codesign`,
  `shasum`, `defaults`, `unzip`, `pgrep`. No `jq`, `python`, or Homebrew dependency.
- Outbound HTTPS to the vendor domains listed under [Network endpoints](#network-endpoints).

---

## Security

Because these scripts download executables and run them as **root**, each one verifies the
publisher before installing:

- **PKG installers** are checked with `pkgutil --check-signature`, requiring the expected
  Apple Developer **Team ID** in the certificate chain.
- **App bundles / installer apps** are checked with `codesign --verify --deep --strict`
  *and* a `TeamIdentifier=` match.
- **Flameshot** (a community build with no pinned Team ID) is verified against the
  **SHA-256 checksum that GitHub publishes** alongside each release asset, plus a
  `codesign` validity check.
- **Angry IP Scanner** is unsigned. Its script therefore requires an explicit
  `ANGRYIP_EXPECTED_SHA256` value in the Intune script environment before it will
  install or replace the app. Update this pin only after reviewing a new release.

All downloads restrict both initial and redirected transport to HTTPS. Installer
URLs are not written to Intune logs because vendor URLs can contain short-lived
authorization parameters. Each root-run script uses a private, unpredictable
`mktemp` directory and removes it on exit.

A failed verification **aborts the install with exit 1** — the scripts never install a
tampered or unexpectedly-signed payload, and an unsigned payload requires an explicit
operator-managed hash pin. Team IDs are sourced from the
[Installomator](https://github.com/Installomator/Installomator) project; Parallels' Team ID
is additionally documented in Parallels' own kernel-extension KB.

---

## Per-app notes

- **Microsoft Edge** — Uses the enterprise update API
  (`edgeupdates.microsoft.com/api/products?view=enterprise`) and selects the highest macOS
  **Stable** version. The legacy `go.microsoft.com/fwlink/?linkid=2093438` redirect now points
  at an **Android APK** and must not be used.
- **Google Chrome** — The unauthenticated `googlechrome.pkg` path requires a per-session
  acceptance token and now 404s, so the script installs the always-current universal
  **DMG** (`dl.google.com/chrome/mac/stable/GoogleChrome.dmg`) by copying the app bundle.
- **VLC** — Reads the Sparkle appcast and picks the **newest** entry via `sort -V` (the feed
  lists oldest-first). Downloads the architecture-matched DMG (`arm64` / `intel64`).
- **Flameshot** — Maps `uname -m` to the release asset name (`x86_64` → `intel`,
  `arm64` → `arm64`) so Intel Macs no longer receive an arm64 build.
- **Poly Lens** — Resolves the installer through Poly's software-update **GraphQL API**. The
  DMG contains a **`.pkg`** (not a drag-install app), so it's installed with `installer`.
  Handles the "Poly Lens.app" → "HP Poly Studio.app" rebrand.
- **DeepL** — Reads the versioned download index (`appdownload.deepl.com/macos/`) and installs
  the exact version-matched DMG.
- **Logi Options+** — Keeps **ETag/Content-Length** change detection (no reliable public
  version endpoint). Tracker plist stores `LastContentLength` / `LastETag`.
- **Parallels Desktop** — Resolves the latest version by scanning the
  `update.parallels.com` feeds. **When Parallels ships a new major version, add it to the
  `PD_MAJORS` variable** at the top of the script (e.g. `PD_MAJORS="20 21 22 23"`).
- **Adobe Acrobat Reader** — Queries the Adobe RDC products API (`rdc.adobe.io`) to resolve the latest version and builds the direct download URL. Mounts the DMG and runs the `.pkg` installer via `installer -pkg`.
- **Angry IP Scanner** — Queries GitHub Releases API to resolve the latest version and download URL. Because the vendor app is unsigned, installation fails closed unless the ZIP matches the operator-pinned `ANGRYIP_EXPECTED_SHA256` value. The quarantine attribute is removed only after this verification.
- **Figma** — Queries the Figma Release API (`desktop.figma.com`) to resolve the latest version and download URL, extracts the app bundle from the ZIP container, verifies its codesign Team ID `T8RA8NE3B7`, and installs it.
- **OBS Studio** — Queries GitHub Releases API to resolve the latest version and download URL, downloads the architecture-specific DMG, verifies its codesign Team ID `2MMRE5MTB8`, and installs it.
- **Adobe Creative Cloud** — Queries the Adobe ccdConfig API (`ffc-static-cdn.oobesaas.adobe.com`) to resolve the latest version, builds the dynamic download URL for the architecture-specific DMG, mounts it, verifies its codesign Team ID `JQ525L2MZD`, and runs the native installer silently using `Install.app/Contents/MacOS/Install --mode=silent`.

### Tracker plists

Apps whose installed version isn't directly comparable store the last-installed version in a
plist under `/Library/Preferences/`:

| App | Plist | Keys |
|---|---|---|
| Poly Lens | `com.company.patching.polylens.plist` | `LastVersion` |
| DeepL | `com.company.patching.deepl.plist` | `LastVersion` |
| Parallels | `com.company.patching.parallels.plist` | `LastVersion` |
| Logi Options+ | `com.company.patching.logioptionsplus.plist` | `LastContentLength`, `LastETag` |

> Rename the `com.company.*` domain to your organization's reverse-DNS identifier before
> production use.

---

## Network endpoints

Allow outbound HTTPS to these hosts:

```
edgeupdates.microsoft.com          msedge.sf.dl.delivery.mp.microsoft.com
chromiumdash.appspot.com           dl.google.com
update.videolan.org                get.videolan.org
api.github.com                     github.com / objects.githubusercontent.com
api.silica-prod01.io.lens.poly.com swupdate.lens.poly.com
appdownload.deepl.com
download01.logi.com
update.parallels.com               www.parallels.com
rdc.adobe.io                       ardownload2.adobe.com
desktop.figma.com
ffc-static-cdn.oobesaas.adobe.com  ccmdls.adobe.com
```

---

## Design notes

- **APIs over redirect-scraping.** Version discovery uses each vendor's documented update
  API/feed rather than parsing a download redirect's final URL, which is brittle and can
  silently point at the wrong platform.
- **No external dependencies.** Everything parses with `grep`/`sed`/`awk`/`sort -V` and ships
  with macOS — important because stock macOS has no `jq` or `python3`.
- **Idempotent & safe.** Scripts check before acting, defer around running apps, verify
  signatures, and clean up `/private/tmp/*_update` scratch directories on every path.
- **Fail closed.** Any signature/Team-ID/checksum failure aborts with exit 1 rather than
  installing an unverified binary.

---

## Troubleshooting

- **"Could not parse version…" / "Skipping run"** — the vendor API was unreachable or changed
  shape. Check connectivity to the relevant [endpoint](#network-endpoints) and run the script
  manually with `sudo bash <script>.sh` to see full output.
- **Output looks truncated in the Intune console** — Intune captures a limited amount of
  stdout. Run the script locally for the complete log, or add a `tee` to a file under
  `/Library/Logs/Microsoft/Intune/` for persistent logging.
- **"Signature/Team ID verification failed"** — the download didn't match the expected
  publisher. This is the safety net working; verify the vendor URL and that the device isn't
  behind an HTTPS-inspecting proxy that re-signs traffic.
- **Test a single script:**
  ```bash
  sudo bash macOS-Maintain-MicrosoftEdge.sh
  ```

---

## Possible future enhancements

Not yet implemented; candidates if you want to extend the suite:

- Persistent per-script logging via `tee` to `/Library/Logs/Microsoft/Intune/`.
- A `flock`/PID lock to prevent overlapping runs on slow downloads.
- A pre-flight free-disk-space check before downloading large images.
- Consolidating onto [Installomator](https://github.com/Installomator/Installomator), which
  already handles URL resolution, version comparison, Team-ID verification, and
  blocking-process handling for 800+ apps including all of these.
