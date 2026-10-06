# Validation

Last reviewed: October 6, 2026. Release: **1.2.0**, build **3**.

## Automated checks

The release passed **35 native Swift tests** (30 audiobook/EPUB/queue checks and 5 download bridge checks) and **36 Python downloader/session/bridge checks**. Test data is synthetic. OpenAI and ElevenLabs responses are mocked; API export tests process synthetic audio through the real MP3 encoder.

Coverage includes reading order and legacy navigation, text extraction, damaged/encrypted archives, external entities, bounded Unicode passages, provider authentication/request formats, error-body redaction, paginated voice retrieval, cancellation, non-overwriting publication, download backups, queue reorder/execution, pause/retry behavior, cache invalidation, series order, and preservation of original chapter/style/image bytes and optional sections.

The connection-reuse check starts only a loopback HTTP server. The source tests and build helper are independent of either original project directory. See [development instructions](docs/development.md) to repeat the checks.

## Packaged and interface checks

The packaged helper generated an EPUB using FanFicFare's offline fixture adapter. The native engine read its spine, generated local macOS speech, and encoded both a single MP3 and numbered chapter MP3s. Checks confirmed non-silent decoded audio, positive duration, and metadata. The bundle passed deep/strict signature verification.

The native interface was also exercised locally for download-to-audiobook handoff, voice selection, single export, multi-file EPUB picking, per-row failure with later successful jobs, retry, queue reordering, selection-driven preview changes, series combining, and the provider settings forms.

A two-book series with reversed queue order preserved its chapter and stylesheet bytes and produced a **12.874-second** local MP3 with the expected series/author metadata and non-silent levels. A batch containing two valid books and one damaged book produced both successful outputs without overwriting either. These synthetic checks demonstrate those workflows on the tested Mac, not universal site or voice compatibility.

Local evidence, generated books/audio, and screenshots remain excluded from the public source tree because they can contain user-specific paths or settings.

## Performance evidence

For a synthetic 100-chapter EPUB containing about 2.2 MB of prose, 20 fresh reads averaged **261.455 ms** and 20 warmed cache reads averaged **0.047 ms** on the development Mac. This measures parsing reuse only. It does not represent first-load or end-to-end audiobook speed, which depends mainly on the voice/provider and book length.

## Environment and limits

- Tested locally on Apple silicon with Swift 6.4 and Python 3.12; FanFicFare 4.62.0 and PyInstaller 6.22.3 package the downloader.
- The supplied bundle includes Python and FanFicFare; FFmpeg remains an external requirement.
- The build is ad hoc signed, **not Developer ID signed or notarized**. A signature check verifies bundle integrity, not Apple's distribution approval.
- Live story-site downloads, authenticated site challenges, live OpenAI/ElevenLabs key/quota/model delivery, another Mac's installation, Intel packaging, and notarization have not been verified.
- Programmatic checks confirm usable decoded audio and metadata. Narration quality was not independently judged by listening.
- GitHub CI repeats offline suites and packaging; headless tests do not replace native UI or listening checks.

See the [1.2.0 release](https://github.com/thatosxguy/FanFictoAudio/releases/tag/v1.2.0) for the exact archive and its SHA-256 companion.
