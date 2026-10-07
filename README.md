# EPUB to MP3 for macOS

A native SwiftUI app that turns DRM-free EPUB books into audiobooks using the speech voices installed on your Mac. All book text and audio stay local. The original EPUB is opened read-only.

## Use the app

Open `dist/EPUB to MP3.app`, choose or drop an EPUB, then:

1. Check the sections you want to include. Their order comes from the EPUB spine, not filenames or ZIP order.
2. Choose a macOS voice and speaking speed from **80 to 1,000 WPM**. **Preview** reads a short sample of the selected section.
3. Choose **One audiobook MP3** or **MP3 per chapter**, and an audio bitrate.
4. Click **Create Audiobook…** and choose the export location.

The app prevents idle system sleep during export. Progress advances by completed passages; a long passage can hold the progress bar still while speech is generated. **Cancel** stops the active process and removes temporary output. Existing files are never overwritten. Quitting the app cancels an active export and waits for cleanup.

## Requirements

- macOS 14 or later. The included local build targets Apple silicon; source also supports Intel Macs.
- Installed voices exposed by macOS's `/usr/bin/say`. Download additional voices in **System Settings → Accessibility → Read & Speak**, called **Spoken Content** in earlier releases. Refresh the voice list in the app's Settings afterward. Voice availability, including Siri voices, depends on what `say` exposes; the app cannot use every voice shown elsewhere in macOS.
- **FFmpeg with the `libmp3lame` encoder**. The app detects Homebrew installations under `/opt/homebrew/bin` and `/usr/local/bin`, MacPorts under `/opt/local/bin`, or a previously chosen executable. Use **Settings → Choose FFmpeg…** for another location. This Mac already has a compatible FFmpeg installation. FFmpeg is not bundled in this local build.

If you already use Homebrew, install the encoder with `brew install ffmpeg`. See [FFmpeg's official download page](https://ffmpeg.org/download.html#build-mac) for other installation options.

## Build and test

Install Apple's Command Line Tools (`xcode-select --install`) and use a Swift 6 or newer toolchain. No external Swift packages are needed: the ZIP reader uses the system zlib library. Full Xcode is optional; open `Package.swift` in Xcode if desired.

```sh
./Scripts/swift.sh test
./Scripts/build-app.sh
```

The build script creates an ad hoc signed app in `dist/EPUB to MP3.app`. It is suitable for local use; distribution would require a release signing identity, notarization, and a decision about bundling or installing FFmpeg. Builds use project-local compiler and package caches, which also permits building in restricted workspaces.

Create the included original demonstration book:

```sh
python3 Scripts/create-demo.py
```

## Command-line companion

```sh
./Scripts/swift.sh build --product epub-audio
```

Locate the executable with `./Scripts/swift.sh build --show-bin-path`, then run:

```sh
epub-audio voices
epub-audio inspect "My Book.epub"
epub-audio export "My Book.epub" "My Book.mp3" --voice "Samantha" --rate 175
epub-audio export "My Book.epub" "My Book Chapters" --chapters --voice "Ava (Premium)"
```

`--bitrate` accepts 64, 96, 128, or 192 kbps. `--ffmpeg` accepts an explicit encoder path. The command-line exporter includes the default reading-order sections. The GUI allows individual section selection.

## How conversion works

The reader locates the package through `META-INF/container.xml`, reads metadata and the OPF manifest/spine, and uses EPUB 3 navigation or EPUB 2 NCX labels when available. It extracts text from XHTML/HTML bodies, retains paragraph boundaries, excludes scripts, styles, SVGs and explicit hidden elements, and neutralizes embedded speech-control sequences. Navigation documents and non-linear extras start unchecked. Document sections are the export units; one spine document containing multiple chapters currently becomes one section.

Each selected section is split into bounded passages, preferably at paragraph or sentence boundaries. `say` renders each passage to 22.05 kHz, 16-bit PCM audio. FFmpeg encodes mono MP3 and joins passages and sections without another lossy encoding pass. A short pause separates sections. Outputs include title, author, album, genre and, for individual chapter files, track metadata.

Read the local `say` manual with `man say`, and [FFmpeg's official documentation](https://ffmpeg.org/ffmpeg.html) for encoder and metadata behavior.

## Current limits

- DRM-protected text cannot be converted. Font obfuscation alone does not block unprotected text.
- Image-only books need OCR, which is not included. Image descriptions, complex mathematical notation, CSS layout rules and footnote placement are not interpreted as a human reader would. Review the text preview for unusual books.
- Standard stored/deflated EPUB ZIP archives are supported; ZIP64 and multipart archives are rejected. Limits: 256 MB archive, 32 MB per accessed resource, and 64 MB total chapter source text.
- A combined MP3 does not include embedded chapter markers. Separate chapter files preserve navigable sections across players.
- MP3 concatenation can introduce small encoder-boundary gaps. M4B export, cover artwork, pronunciation dictionaries, queued books and resumable exports are not included in this first version.

## Project layout

- `Sources/EPUBToMP3`: SwiftUI interface, settings and workflow.
- `Sources/AudiobookCore`: bounded ZIP reader, EPUB parsing, speech/encoder processes and transactional export.
- `Sources/EPUBAudioCLI`: command-line inspection and conversion using the same core.
- `Tests/AudiobookCoreTests`: reading-order, legacy navigation, text preservation, damaged files, encrypted resources, external entities, cancellation and overwrite checks.
- `Scripts`: project-local build wrapper, app packaging and demo EPUB generation.
