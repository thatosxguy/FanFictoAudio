# Development and releases

[Back to the README](../README.md) · [Architecture](architecture.md) · [Validation](../VALIDATION.md)

## Start from a clean clone

```sh
git clone https://github.com/thatosxguy/FanFictoAudio.git
cd FanFictoAudio
xcode-select --install  # Only if Apple's development tools are missing.
swift --version
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements-build.txt
```

Use Swift 6 or later and Python 3.12. The package targets macOS 14 or later. The build wrapper supports Command Line Tools and full Xcode installations and keeps compiler caches in `.build`. Homebrew users can install the build/runtime prerequisites with `brew install python@3.12 ffmpeg`.

`requirements-build.txt` pins the direct dependencies used for version 1.3.0 and constrains transitive versions with `requirements-build.lock`: [FanFicFare](https://github.com/JimmXinu/FanFicFare) 4.62.0, PyInstaller 6.22.3, and pytest 9.1.1. FanFicFare is the upstream download engine by Jim Miller (JimmXinu) and its contributors; preserve its [license and attribution](https://github.com/JimmXinu/FanFicFare/blob/main/LICENSE) when packaging. The transitive constraints pin the tested dependency closure by version; they do not pin package hashes or the complete toolchain. No remote Swift packages are required. Build architecture follows the Swift toolchain and Python interpreter; the release asset is arm64, not universal.

## Run tests

```sh
./Scripts/swift.sh test
PYTHONPATH="$PWD/Vendor" .venv/bin/python -m pytest -q Tests/DownloadEngineTests
```

Swift Testing covers the EPUB reader, audiobook queue, merger, narration requests, audio export, and native downloader bridge. Python checks use the vendored downloader modules. FanFicFare's `test1.com` adapter creates synthetic stories offline; that fixture URL does not visit a real story site. One connection-reuse test binds only `127.0.0.1`, so restrictive command sandboxes must permit loopback sockets.

Install FFmpeg before testing: synthetic API audio export checks need a compatible encoder. Provider responses are mocked; no API key or paid speech request is needed. The GitHub Actions workflow runs the native and Python suites and verifies app packaging on an Apple silicon macOS runner. Headless checks do not prove UI behavior or audible voice quality.

## Build the app

```sh
./Scripts/build-app.sh
open 'dist/FanFic to Audio.app'
```

The script freezes the downloader with PyInstaller, compiles the release Swift executable, copies resources and license notices, and signs the bundle ad hoc. Existing builds move into `dist/Previous Builds` before replacement. It does not install into Applications or provide notarization.

To use another Python 3.12 build environment:

```sh
FANFIC_BUILD_PYTHON=/absolute/path/to/venv/bin/python ./Scripts/build-app.sh
```

Use a dedicated build environment so unrelated installed packages do not add unnecessary dependency notices. The helper is independent of editable installs or the two original project folders.

## Validate the packaged pipeline

```sh
./Scripts/swift.sh build --product epub-audio
bin_dir="$(./Scripts/swift.sh build --show-bin-path)"
.venv/bin/python Scripts/smoke-app.py --cli "$bin_dir/epub-audio"
```

This exercises the helper **inside the app bundle**, creates an offline fixture EPUB, converts it using local macOS narration to one MP3, chapter files, and M4B, checks 192 kbps MP3 streams and M4B chapters plus duration/metadata using FFprobe, and verifies the bundle signature. Each run uses a new directory under `dist/Validation`. Override it with `--output /path/to/empty-directory`; optionally pass `--voice NAME` and `--ffprobe /path/to/ffprobe`.

Speech needs normal access to macOS services. Restricted command sandboxes can produce silent `say` output; run the smoke check in a normal local terminal if that happens. Inspect and listen to sample audio separately when evaluating narration quality.

## Companion CLI

Build with `./Scripts/swift.sh build --product epub-audio`, then use the executable from `--show-bin-path`:

```text
epub-audio voices
epub-audio inspect BOOK.epub
epub-audio export BOOK.epub OUTPUT.mp3 --voice NAME --rate 175 --bitrate 128
epub-audio export BOOK.epub OUTPUT.m4b --m4b
epub-audio export BOOK.epub OUTPUT_FOLDER --chapters --ffmpeg /path/to/ffmpeg
epub-audio combine "Series title" SERIES.epub BOOK1.epub BOOK2.epub
epub-audio benchmark-read BOOK.epub
```

The CLI export uses macOS voices. AI key management and provider selection are in the graphical app. `benchmark-read` compares 20 fresh parses with 20 warmed cache reads; it does not benchmark audiobook generation.

## Prepare a release

1. Update the version and build number in `Resources/Info.plist`, the changelog, validation record, and release notes. Rebuild and run the relevant tests and smoke check.
2. Review the files being committed. Do not commit personal INI files, API keys, cookies, real books, audio, local screenshots, logs, virtual environments, or build artifacts. Check Git's actual staged tree; `.gitignore` alone is not a content audit.
3. Verify the bundle, then package it from `dist`:

   ```sh
   codesign --verify --deep --strict 'dist/FanFic to Audio.app'
   ./Scripts/package-release.sh
   ```

4. Publish the tested source commit, tag that commit, and upload the ZIP and checksum to the corresponding GitHub release. Record architecture, minimum OS, FFmpeg requirement, and signing status in the notes. Do not silently replace an existing release asset.
5. Compare the remote commit/tag and uploaded asset checksum with the validated local values. Test installation on another Mac when available.

## Developer ID signing and notarization

The default build remains ad hoc for CI and local development. For distribution, use a Developer ID Application identity available to macOS (a hardware-token identity is supported):

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./Scripts/build-app.sh
```

`sign-app.py` signs nested Mach-O code and Python frameworks inside-out, then the app, with hardened runtime and timestamps. Private keys remain in Keychain or the token; no export is required. Enter PINs only in local system prompts and touch the token when required. Verify the exact identity before signing. The packaged downloader must be smoke-tested after signing; an ad hoc signature check alone cannot establish Developer ID compatibility.

Create a notarization Keychain profile interactively; keep passwords out of shell arguments, logs, and Git:

```sh
xcrun notarytool store-credentials FanFictoAudio-Notary --team-id YOUR_TEAM_ID
```

Notarization authentication uses an Apple ID app-specific password or an App Store Connect API key; the hardware signing key alone is insufficient. Then package the verified app:

```sh
NOTARY_PROFILE=FanFictoAudio-Notary \
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
./Scripts/package-release.sh
```

The script requires Apple's `Accepted` status before stapling and Gatekeeper assessment, builds ZIP/DMG assets without overwriting previous releases, notarizes/staples the DMG, and writes SHA-256 checksums. Leave `NOTARY_PROFILE` unset only for explicitly unnotarized packaging; release notes must state that status. A YubiKey is required at signing time, not by users installing the app. See [Apple's distribution guidance](https://developer.apple.com/developer-id/) and [PyInstaller signing notes](https://pyinstaller.org/en/stable/feature-notes.html#macos-binary-code-signing).

To refresh transitive constraints after an intentional dependency update, install the direct requirements in a clean macOS Python 3.12 venv, run `Scripts/lock-build-dependencies.py` with that venv, and repeat tests/build/smoke checks. The lock is version-based, not a cryptographic package-integrity guarantee.
