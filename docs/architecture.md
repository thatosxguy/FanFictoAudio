# Architecture

[Back to the README](../README.md) · [Development](development.md)

## Modules

| Path | Responsibility |
| --- | --- |
| `Sources/FanFicToAudio` | SwiftUI interface, workflow state, settings, Keychain controls |
| `Sources/DownloadCore` | Requests, streamed helper events, cancellation, publication acknowledgement |
| `Vendor/fanficfare_gui` | FanFicFare Desktop download, session, and network modules |
| `Scripts/download-worker.py` | JSON helper entry point and bridge to the download engine |
| `Sources/AudiobookCore` | EPUB reading/merging, queue, speech providers, MP3 export |
| `Sources/CZlib` | System zlib bridge for ZIP decompression |
| `Sources/EPUBAudioCLI` | Inspection, local export, merging, parsing benchmarks |
| `Scripts` | Packaging, notices, synthetic fixtures, smoke validation |
| `Tests` | Swift Testing and pytest regression checks |

## Download publication

The native queue starts one helper job at a time. The Python helper writes a complete EPUB in staging and validates it, then sends a finalizing event. The native bridge acknowledges publication through stdin before the helper moves the output into place. Cancellation before acknowledgement cleans staging; publication is allowed to finish once acknowledged. Existing output names receive numeric suffixes; update operations preserve a backup next to the original book.

FanFicFare handles site adapters and authentication. Only packaged defaults and an explicitly selected INI are loaded. Session reuse is scoped by site, format, INI fingerprint, adult confirmation, and applicable story-specific settings; bounded caches and connections close with the worker. Site request pacing remains in effect. Downloading and audiobook conversion are separate queue operations.

## EPUBs and series

The ZIP reader enforces archive/resource limits, validates paths and entries, and the XML reader does not resolve external entities. The native EPUB reader follows the package spine and EPUB navigation, extracts text, and distinguishes optional/nonlinear sections. Narration does not render the book in a browser.

The merger copies each book's resources into its own directory namespace, rewrites package references, and adds per-book title pages and navigation. Original chapter/resource bytes and relative links are preserved. The source files are not edited. Protected or obfuscated resources are rejected; this is not a decryption tool. Queue entries become one combined job only after the new EPUB has been saved and read successfully.

The reader's actor cache holds up to three books / 64 MB of extracted text and invalidates on source size or modification time changes. Obsolete selection loads are cancelled so they cannot replace a later selection.

## Narration and export

A batch takes a shared settings snapshot and processes books sequentially. A failed book records its error and allows the next one to run. Cancelling pauses the queue and leaves later jobs waiting; retry is explicit and begins a new export.

Local narration invokes `/usr/bin/say`. OpenAI and ElevenLabs use separate request formats through the same speech-service interface. API passages are bounded and sequential; OpenAI also has a conservative UTF-8 byte limit. Provider errors are mapped to messages without displaying raw response bodies. Paid speech requests have no automatic retry or persisted resume cache.

Each passage becomes decoded PCM audio, which is checked for usable speech data before FFmpeg encoding. A single MP3 joins all passages once; chapter mode writes numbered outputs. Files are staged and then published without overwriting existing destinations. Temporary work is cleaned after success, cancellation, or failure. Queue jobs and book previews live in memory for the current session.

## Boundaries

Provider keys belong to macOS Keychain; ordinary choices and paths belong to UserDefaults. AI generation sends text to the selected external service, while local speech and encoding stay on the Mac. Download site configuration can enable additional upstream network behavior. This app is not distributed with the macOS App Sandbox enabled. See [Privacy](../PRIVACY.md) and [Security](../SECURITY.md).
