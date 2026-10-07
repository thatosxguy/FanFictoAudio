# Architecture

[Back to the README](../README.md) · [Development](development.md)

## Modules

| Path | Responsibility |
| --- | --- |
| `Sources/FanFicToAudio` | SwiftUI interface, workflow state, settings, Keychain controls |
| `Sources/DownloadCore` | Requests, streamed helper events, cancellation, publication acknowledgement |
| `Vendor/fanficfare_gui` | FanFicFare Desktop download, session, and network modules |
| `Scripts/download-worker.py` | JSON helper entry point and bridge to the download engine |
| `Sources/AudiobookCore` | EPUB reading/merging, queue, speech providers, MP3/M4B export, checkpoints, usage budgets |
| `Sources/CZlib` | System zlib bridge for ZIP decompression |
| `Sources/EPUBAudioCLI` | Inspection, local export, merging, parsing benchmarks |
| `Scripts` | Packaging, notices, synthetic fixtures, smoke validation |
| `Tests` | Swift Testing and pytest regression checks |

## Download publication

The native queue starts one helper job at a time. The Python helper writes a complete EPUB in staging and validates it, then sends a finalizing event. The native bridge acknowledges publication through stdin before the helper moves the output into place. Cancellation before acknowledgement cleans staging; publication is allowed to finish once acknowledged. Existing output names receive numeric suffixes; update operations preserve a backup next to the original book.

The upstream [FanFicFare](https://github.com/JimmXinu/FanFicFare) engine, by Jim Miller (JimmXinu) and its contributors, implements story downloads, site adapters, metadata extraction, EPUB writing and updates, link extraction, and authentication. The native interface and helper coordinate that engine. Only packaged defaults and an explicitly selected INI are loaded. Session reuse is scoped by site, format, INI fingerprint, adult confirmation, and applicable story-specific settings; bounded caches and connections close with the worker. Site request pacing remains in effect. Downloading and audiobook conversion are separate queue operations.

## EPUBs and series

The ZIP reader enforces archive/resource limits, validates paths and entries, and the XML reader does not resolve external entities. The native EPUB reader follows the package spine and EPUB navigation, extracts text, and distinguishes optional/nonlinear sections. Narration does not render the book in a browser.

The merger copies each book's resources into its own directory namespace, rewrites package references, and adds per-book title pages and navigation. Original chapter/resource bytes and relative links are preserved. The source files are not edited. Protected or obfuscated resources are rejected; this is not a decryption tool. Queue entries become one combined job only after the new EPUB has been saved and read successfully.

The reader's actor cache holds up to three books / 64 MB of extracted text and invalidates on source size or modification time changes. Obsolete selection loads are cancelled so they cannot replace a later selection.

## Narration and export

A batch takes a shared settings snapshot and processes books sequentially. A failed book records its error and allows the next one to run. Cancelling pauses the queue and leaves later jobs waiting; retry is explicit and begins a new export.

Local narration invokes `/usr/bin/say`. OpenAI and ElevenLabs use separate request formats through the same speech-service interface. API passages are bounded and sequential; OpenAI also has a conservative UTF-8 byte limit. Provider errors are mapped to messages without displaying raw response bodies. Paid speech requests have no automatic retry or persisted resume cache.

Each passage becomes decoded PCM audio, which is checked for usable speech data before FFmpeg encoding. A single MP3 joins all passages once; chapter mode writes numbered outputs. Files are staged and then published without overwriting existing destinations. Temporary work is cleaned after success, cancellation, or failure. Audiobook jobs and completed passages are saved for recovery; book previews and download jobs remain in memory for the current session.

## Boundaries

Provider keys belong to macOS Keychain; ordinary choices and paths belong to UserDefaults. AI generation sends text to the selected external service, while local speech and encoding stay on the Mac. Download site configuration can enable additional upstream network behavior. This app is not distributed with the macOS App Sandbox enabled. See [Privacy](../PRIVACY.md) and [Security](../SECURITY.md).

## Queue and narration recovery

`AudiobookQueue` atomically persists a versioned JSON snapshot. Running jobs recovered after a crash become queued unless their atomically published output already exists. Presets serialize provider/model/voice/style/speed/output choices, never API keys. Credentials are resolved before a batch starts. Budget failures pause later jobs rather than sending further requests.

`ConversionCheckpoint` hashes book metadata, all chapter text and selection, cover bytes, and a credential-free preset with an encoding schema version. Completed encoded passages have SHA-256 checksums and measured durations. Export staging is always cleaned; checkpoints survive failed/cancelled attempts and are removed after publication. MP3 and AAC passages are joined once. M4B uses measured durations to create FFmetadata chapters and embeds supported cover art.

`APIUsageLedger` serializes reservations before speech dispatch. Failed/cancelled attempts remain counted conservatively; cached passages do not reserve again. Rates and costs are manual estimates, not provider billing records. Speech requests use a pooled ephemeral URLSession with cookies/credential storage disabled and redirects rejected. The subprocess runner owns each process, sends SIGTERM on cancellation/deadline, and escalates to SIGKILL after a grace period with process-identity checks.

Blocking subprocess waits run on dedicated dispatch queues rather than Swift cooperative task threads. A separate control queue delivers audio command deadlines and termination escalation even while a child process is unresponsive.
