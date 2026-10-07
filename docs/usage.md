# Using FanFic to Audio

[Back to the README](../README.md) · [Installation](installation.md) · [Troubleshooting](troubleshooting.md)

## Download a story and create an audiobook

1. Paste one story URL per line in **Download EPUB**.
2. Choose where to save your EPUBs. If the site needs login credentials or cookies, select your `personal.ini`. Adult access is an explicit session choice.
3. Click **Download & Prepare Audiobook**. The last successful EPUB opens automatically in **Create Audiobook** when the queue finishes. To narrate another downloaded story, select its queue row and click **Make Audiobook**.
4. Review the chapters and text preview. Choose macOS, OpenAI, or ElevenLabs narration, a voice, speed, audio output mode, and bitrate. **Preview** reads a short sample.
5. Click **Create Audiobook…** and choose a new destination. Export one MP3, a folder of numbered chapter MP3s, or an M4B with chapter markers and embedded EPUB cover art when available.

You can also open an existing EPUB directly into the audiobook view. Dropped EPUBs are added to the audiobook queue. **Open EPUB…** in the toolbar and Command-O work from either step.

## Create audiobooks in bulk

1. Open **Create Audiobook** and click **Add EPUBs…**. Select several EPUB files at once. You can also drop a group of EPUBs into this view or use Command-Shift-O.
2. Choose the speech provider, voice, speed, MP3 quality, and **One audiobook MP3**, **MP3 per chapter**, or **M4B with chapters**. New jobs capture these settings when the batch starts. A saved per-book preset takes precedence.
3. Click **Create Queued Audiobooks…** and select an output folder. With a folder already selected, click **Start Queue**.
4. Each EPUB converts in queue order. Its row shows progress, success, or the reason for failure. Select a completed row and click **Show Audiobook in Finder**.

Select a queue row to load its EPUB and chapter preview. The open book follows the active job during conversion. Use **Move Up**, **Move Down**, or drag rows to change the order while the queue is idle. Selection is disabled during individual exports and downloads, so the highlighted row stays aligned with the open book.

Each book creates a separate MP3, M4B, or chapter folder named from its title. Duplicate titles receive numbered suffixes; existing outputs are preserved. A failed EPUB does not stop later books.

**Cancel & Pause Queue** cancels the current book and leaves the remaining EPUBs queued. **Start Queue** resumes them. Use **Retry Selected** to requeue a failed or cancelled book, then start again. **Remove Selected** removes a row and its resume checkpoints, without deleting source or output files. **Clear Completed** clears successful rows only.

EPUBs added from disk use their default reading-order sections. To customize a queued book, select its row, check the sections you want, choose narration/output settings, then click **Save Current Settings & Sections for Selected Book**. This also replaces a previous preset. **Add Open Book** keeps your current section selection for a new entry. The single-book export remains available below the queue.

The audiobook queue, order, selected row, per-book presets, and output folder survive app restarts. An interrupted running entry becomes queued; failed/cancelled entries retain their state until you click **Retry Selected**. Keys remain in Keychain and are resolved again before each batch. A missing or moved EPUB is reported as a failed job.

Completed passages are saved under `~/Library/Application Support/FanFicToAudio/Checkpoints`. Both individual and queued exports can reuse them. Reuse requires matching text, section choices, voice, provider/model/style/speed, bitrate, and output format; cached bytes are checksum-verified. The currently unfinished passage may be sent and charged again. Completed exports remove their matching checkpoint. Older checkpoints with different settings remain until the job is removed or **Discard Saved Passages** is selected; single-book leftovers can be removed from that folder while the app is idle. **Clear Folder** resets only the output folder choice.

## Combine books into a series

Check the boxes beside the waiting EPUBs, or click **Select Waiting EPUBs**. Use **Move Up** and **Move Down** to set their reading order, enter a **Series title**, then click **Combine Selected EPUBs…**. Save the combined book with a new filename.

The merger preserves original chapter files, images, styles, and relative resource links in separate namespaces. It adds a table of contents and a title page before each book, and keeps optional/non-linear sections optional. All source sections are preserved, including sections excluded from an individual audio job. The saved EPUB replaces the selected waiting entries at their first queue position; source EPUBs remain intact. Start the queue to turn the merged series into one audiobook or a numbered chapter folder. Protected/obfuscated resources and archives exceeding the configured limits cannot be combined.

## AI narration

Choose **OpenAI** or **ElevenLabs** under **Speech provider**. Enter your own provider API key in the secure field and click **Save Key**. Keys are stored in macOS Keychain; they are never saved in app preferences. **Remove Key** deletes that provider's saved key.

OpenAI offers built-in voices and an editable model ID, plus optional style instructions for models that support them. ElevenLabs accepts a voice ID from your library, or **Load Voices** retrieves your account's available voices. Both providers have a separate API speed multiplier. These choices apply to previews, individual exports, and the queue.

Preview and conversion send the selected book text to the chosen provider and may incur its API charges. The interface and exported audio metadata identify AI-generated narration. Passages are bounded and sent sequentially. OpenAI passages also have a conservative UTF-8 byte limit to keep multilingual input below the documented token ceiling. Cancellation stops the active request; errors are shown without echoing provider response bodies. The app does not automatically retry paid speech requests. Retry an unsuccessful job explicitly when ready. Retry reuses compatible completed passages and sends only unfinished passages.

Implemented against the [official OpenAI speech API](https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create) and [ElevenLabs speech API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert). Live provider calls require your own key and quota; validation uses mocked responses with synthetic audio.

## AI usage estimates and stopping budgets

Expand **AI usage and budget**. Enter a character limit, an estimated USD cost limit, or both; blank limits are disabled. Usage is saved across app launches and counts previews, retry attempts, and requests that failed or were cancelled after dispatch. **Reset Usage** starts a new accounting period. No book text or credentials are stored in the usage record.

Enter an estimated **all-in USD rate** for the selected provider/model and choose characters, estimated input tokens, or estimated audio minutes as its basis. Rates are saved separately for each model. Use your plan's current rates and include input/output charges in the equivalent estimate. Token estimates use UTF-8 bytes divided by three; audio estimates use word count at 175 words per minute adjusted by speech speed. These rough estimates are not provider invoices, especially for multilingual text, different delivery styles, subscriptions, credits, or output-token billing.

The open-book estimate appears automatically for AI narration. **Estimate Queued AI Usage** reads each waiting EPUB and totals the selected sections, using saved presets when present. It estimates the full requested text, including already cached passages, so resume may use less. Retries and previews add to recorded usage separately.

The app reserves each attempt before dispatch and stops before the next passage would exceed a limit. A budget stop pauses the queue with later jobs waiting. Increase the limit or reset usage, then retry the stopped job and start the queue. Character limits bound the number of text scalars submitted by this app. Cost limits bound its estimates, not actual provider charges. A cost limit requires a rate for each queued AI model and no earlier unpriced attempts in the accounting period. A corrupted usage record blocks further speech requests until reset; a corrupt queue is preserved for manual recovery.

## Performance

Preview and conversion share a bounded EPUB cache (up to three books / 64 MB of text); file size and modification time invalidate edited books. Selecting another row cancels obsolete preview loads so they cannot replace the current selection later. Speech chunking walks bounded portions of the text without repeatedly counting the remaining chapter. A single MP3 export joins passages once, eliminating one extra FFmpeg remux and intermediate chapter MP3 per chapter. Chapter word/scalar/byte counts are cached at load time, and speech API connections are reused without shared cookies or credentials. Books still convert one at a time, limiting speech-service load and temporary PCM disk use.

The companion CLI includes `benchmark-read BOOK.epub` for comparing 20 fresh reads with 20 cached reads. This measures parsing reuse, not end-to-end narration speed, which remains dominated by the voice/provider.

## Download tools

- **Add to Queue** collects several jobs before you run them. Jobs run sequentially, preserving each site's own request delays. A failed story does not prevent later queued stories from downloading.
- **Preview story** reads metadata without saving an EPUB.
- **Find links on a page** returns links to the input box for review. Switch the action back to **Download EPUB** before downloading them.
- **Update Existing EPUBs…** updates FanFicFare books and backs up originals to **FanFicFare Backups** beside each book. Books with no new chapters stay unchanged.
- **Cancel & Pause Queue** stops the active download and cleans partial work. **Start Queue** resumes remaining jobs. **Retry Selected** retries a failed or cancelled job using the current INI and adult-access choices.
- Successful downloads never overwrite existing filenames. The app acknowledges a complete, validated EPUB before the helper publishes it. Cancellation is disabled briefly while the book is saved.
- The download queue lasts for the current app session. The audiobook queue is saved automatically. Destination, INI path, voice, speed, and bitrate are remembered in this app's own settings. INI contents and adult-access confirmation are not saved by the interface.

[FanFicFare](https://github.com/JimmXinu/FanFicFare), by Jim Miller (JimmXinu) and its contributors, powers story downloads, EPUB writing and updates, metadata previews, link extraction, site adapters, and authentication behavior. Its [documentation](https://github.com/JimmXinu/FanFicFare/wiki) covers site support and INI configuration. Site restrictions and browser challenges can require a configured INI; interactive password or two-factor prompts are not supported. The app reads only packaged defaults and your explicitly selected INI, and does not run FanFicFare CLI shell hooks.

## Narration requirements

For local narration, the app uses speech voices exposed by macOS `/usr/bin/say`. More voices can be downloaded in System Settings under Accessibility. Refresh them from this app's Settings afterward. Voice availability depends on what `say` exposes.

MP3 encoding uses **FFmpeg with libmp3lame**; M4B uses its **AAC** encoder. FFmpeg is detected in standard Homebrew and MacPorts locations or can be selected in Settings. FFmpeg is not bundled.

Only unprotected, text-based EPUBs can be narrated. Image-only books need OCR, which is not included. A section follows a document in the EPUB spine; title pages can be unchecked before export. MP3 output has title/author metadata. Combined MP3s have no embedded chapter markers; use **M4B with chapters** or separate chapter files for navigation. M4B preserves JPEG/PNG cover art designated in EPUB 2/3 metadata; unsupported or absent covers are omitted. macOS narration and MP3 encoding run locally; AI speech generation uses the selected provider.

Exports preserve existing files, prevent idle system sleep, and clean temporary staging on cancellation while retaining completed resume passages. Quitting waits for safe downloader publication or cancellation and audiobook cleanup. Downloading and audiobook conversion run as separate workflow steps.
