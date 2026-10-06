# Using FanFic to Audio

[Back to the README](../README.md) · [Installation](installation.md) · [Troubleshooting](troubleshooting.md)

## Download a story and create an audiobook

1. Paste one story URL per line in **Download EPUB**.
2. Choose where to save your EPUBs. If the site needs login credentials or cookies, select your `personal.ini`. Adult access is an explicit session choice.
3. Click **Download & Prepare Audiobook**. The last successful EPUB opens automatically in **Create Audiobook** when the queue finishes. To narrate another downloaded story, select its queue row and click **Make Audiobook**.
4. Review the chapters and text preview. Choose macOS, OpenAI, or ElevenLabs narration, a voice, speed, MP3 output mode, and bitrate. **Preview** reads a short sample.
5. Click **Create Audiobook…** and choose a new destination. Export one MP3 or a folder of numbered chapter MP3s.

You can also open an existing EPUB directly into the audiobook view. Dropped EPUBs are added to the audiobook queue. **Open EPUB…** in the toolbar and Command-O work from either step.

## Create audiobooks in bulk

1. Open **Create Audiobook** and click **Add EPUBs…**. Select several EPUB files at once. You can also drop a group of EPUBs into this view or use Command-Shift-O.
2. Choose the speech provider, voice, speed, MP3 quality, and **One audiobook MP3** or **MP3 per chapter**. These shared settings are fixed for the running batch.
3. Click **Create Queued Audiobooks…** and select an output folder. With a folder already selected, click **Start Queue**.
4. Each EPUB converts in queue order. Its row shows progress, success, or the reason for failure. Select a completed row and click **Show Audiobook in Finder**.

Select a queue row to load its EPUB and chapter preview. The open book follows the active job during conversion. Use **Move Up** and **Move Down** to change the order while the queue is idle.

Each book creates a separate MP3 or chapter folder named from its title. Duplicate titles receive numbered suffixes; existing outputs are preserved. A failed EPUB does not stop later books.

**Cancel & Pause Queue** cancels the current book and leaves the remaining EPUBs queued. **Start Queue** resumes them. Use **Retry Selected** to requeue a failed or cancelled book, then start again. **Remove Selected** removes a row without deleting any source or output files. **Clear Completed** clears successful rows only.

EPUBs added from disk use their default reading-order sections. To customize sections for one queued book, open it first, check the sections you want, and click **Add Open Book**. The original single-book export remains available below the queue. The audiobook queue lasts for the current app session; its chosen output folder is remembered. **Clear Folder** resets the folder choice.

## Combine books into a series

Check the boxes beside the waiting EPUBs, or click **Select Waiting EPUBs**. Use **Move Up** and **Move Down** to set their reading order, enter a **Series title**, then click **Combine Selected EPUBs…**. Save the combined book with a new filename.

The merger preserves original chapter files, images, styles, and relative resource links in separate namespaces. It adds a table of contents and a title page before each book, and keeps optional/non-linear sections optional. All source sections are preserved, including sections excluded from an individual audio job. The saved EPUB replaces the selected waiting entries at their first queue position; source EPUBs remain intact. Start the queue to turn the merged series into one audiobook or a numbered chapter folder. Protected/obfuscated resources and archives exceeding the configured limits cannot be combined.

## AI narration

Choose **OpenAI** or **ElevenLabs** under **Speech provider**. Enter your own provider API key in the secure field and click **Save Key**. Keys are stored in macOS Keychain; they are never saved in app preferences. **Remove Key** deletes that provider's saved key.

OpenAI offers built-in voices and an editable model ID, plus optional style instructions for models that support them. ElevenLabs accepts a voice ID from your library, or **Load Voices** retrieves your account's available voices. Both providers have a separate API speed multiplier. These choices apply to previews, individual exports, and the queue.

Preview and conversion send the selected book text to the chosen provider and may incur its API charges. The interface and exported MP3 metadata identify AI-generated narration. Passages are bounded and sent sequentially. OpenAI passages also have a conservative UTF-8 byte limit to keep multilingual input below the documented token ceiling. Cancellation stops the active request; errors are shown without echoing provider response bodies. The app does not automatically retry paid speech requests. Retry an unsuccessful job explicitly when ready. There is no paid resume cache: retrying starts that audiobook again.

Implemented against the [official OpenAI speech API](https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create) and [ElevenLabs speech API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert). Live provider calls require your own key and quota; validation uses mocked responses with synthetic audio.

## Performance

Preview and conversion share a bounded EPUB cache (up to three books / 64 MB of text); file size and modification time invalidate edited books. Selecting another row cancels obsolete preview loads so they cannot replace the current selection later. Speech chunking walks bounded portions of the text without repeatedly counting the remaining chapter. A single MP3 export joins passages once, eliminating one extra FFmpeg remux and intermediate chapter MP3 per chapter. Books still convert one at a time, limiting speech-service load and temporary PCM disk use.

The companion CLI includes `benchmark-read BOOK.epub` for comparing 20 fresh reads with 20 cached reads. This measures parsing reuse, not end-to-end narration speed, which remains dominated by the voice/provider.

## Download tools

- **Add to Queue** collects several jobs before you run them. Jobs run sequentially, preserving each site's own request delays. A failed story does not prevent later queued stories from downloading.
- **Preview story** reads metadata without saving an EPUB.
- **Find links on a page** returns links to the input box for review. Switch the action back to **Download EPUB** before downloading them.
- **Update Existing EPUBs…** updates FanFicFare books and backs up originals to **FanFicFare Backups** beside each book. Books with no new chapters stay unchanged.
- **Cancel & Pause Queue** stops the active download and cleans partial work. **Start Queue** resumes remaining jobs. **Retry Selected** retries a failed or cancelled job using the current INI and adult-access choices.
- Successful downloads never overwrite existing filenames. The app acknowledges a complete, validated EPUB before the helper publishes it. Cancellation is disabled briefly while the book is saved.
- The queue lasts for the current app session. Destination, INI path, voice, speed, and bitrate are remembered in this app's own settings. INI contents and adult-access confirmation are not saved by the interface.

[FanFicFare](https://github.com/JimmXinu/FanFicFare), by Jim Miller (JimmXinu) and its contributors, powers story downloads, EPUB writing and updates, metadata previews, link extraction, site adapters, and authentication behavior. Its [documentation](https://github.com/JimmXinu/FanFicFare/wiki) covers site support and INI configuration. Site restrictions and browser challenges can require a configured INI; interactive password or two-factor prompts are not supported. The app reads only packaged defaults and your explicitly selected INI, and does not run FanFicFare CLI shell hooks.

## Narration requirements

For local narration, the app uses speech voices exposed by macOS `/usr/bin/say`. More voices can be downloaded in System Settings under Accessibility. Refresh them from this app's Settings afterward. Voice availability depends on what `say` exposes.

MP3 encoding uses **FFmpeg with libmp3lame**. FFmpeg is detected in standard Homebrew and MacPorts locations or can be selected in Settings. FFmpeg is not bundled.

Only unprotected, text-based EPUBs can be narrated. Image-only books need OCR, which is not included. A section follows a document in the EPUB spine; title pages can be unchecked before export. MP3 output has title/author metadata. Combined MP3s have no embedded chapter markers; use separate chapter files for easier navigation. macOS narration and MP3 encoding run locally; AI speech generation uses the selected provider.

Exports preserve existing files, prevent idle system sleep, and clean temporary work on cancellation. Quitting waits for safe downloader publication or cancellation and audiobook cleanup. Downloading and audiobook conversion run as separate workflow steps.
