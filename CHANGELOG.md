# Changelog

## 1.3.0 — 2026-10-06

- Save audiobook queue order, selections, states, and credential-free per-book narration settings across launches.
- Resume completed passages after cancellation, failure, or interruption; invalidate incompatible content/settings and verify cached audio checksums.
- Add M4B output with AAC audio, chapter navigation, and EPUB JPEG/PNG cover art.
- Track AI attempts across previews, retries, and failed requests; add persistent character and estimated USD budgets with user-entered per-model rates.
- Add per-book settings/section editing and drag reordering, retaining the move buttons.
- Fix selection/open-book disagreement during individual exports and downloads, 192 kbps local encoding, and multilingual preview bounds.
- Bound subprocess cancellation and command deadlines; keep blocking audio/download waits off Swift task threads so smaller machines can still deliver cancellation and timers. Cache word/text counts and reuse speech API connections.
- Add inside-out Developer ID signing, hardware-token support, optional notarization/stapling, ZIP/DMG packaging, and locked build dependencies.
- Require FFmpeg explicitly in audio integration tests and add recovery, budget, metadata, preview, cancellation, and selection regressions.

## 1.2.0 — 2026-10-06

- Move waiting audiobook jobs up or down; the book preview follows the selected row and active conversion.
- Combine selected EPUBs into an ordered series with per-book title pages and navigation, preserving source files and resources.
- Add OpenAI and ElevenLabs narration, secure Keychain controls, provider settings, voice selection, and AI-output disclosure.
- Bound and sequence API passages, redact response bodies, and require explicit retries for paid speech.
- Cache parsed EPUB text with bounded storage and file-change invalidation; avoid obsolete selection loads.
- Join single-book audio once and improve speech chunk traversal.
- Add public installation, usage, development, architecture, troubleshooting, privacy, security, and contribution documentation with GitHub CI.

## 1.1.0 — 2026-10-05

- Add bulk EPUB selection and a sequential audiobook queue.
- Add per-book progress, cancel/pause/resume, retry, completed-item cleanup, and Finder shortcuts.
- Preserve existing outputs and allocate numbered names for duplicate book titles.

## 1.0.0 — 2026-10-05

- Combine the FanFicFare downloader and EPUB-to-MP3 engine into one native SwiftUI app.
- Download EPUBs, preview metadata, extract links, and update existing books with backups.
- Hand off successful downloads to audiobook creation.
- Support macOS voice previews, section selection, and single/chapter MP3 exports through FFmpeg.
- Bundle the Python downloader runtime and retain license notices.
