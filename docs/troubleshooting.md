# Troubleshooting

[Back to the README](../README.md) · [Installation](installation.md) · [User guide](usage.md)

| Symptom | What to check |
| --- | --- |
| macOS blocks first launch | Read the release's signing status and Apple's app-specific approval instructions in the installation guide. Managed policies may prevent approval. |
| FFmpeg missing or encoding unavailable | Install FFmpeg with `libmp3lame`, then select its executable in Settings if it is outside the standard locations. AI exports also need it. |
| A downloaded voice is absent | Refresh voices and check `/usr/bin/say -v '?'`. This app uses the voices that `say` exposes. |
| An EPUB has no readable sections | Image-only books need OCR. Protected books and damaged EPUB packages are unsupported. Review the warnings and section list. |
| A download needs login | Select your own `personal.ini` with the correct site section. Interactive password and two-factor prompts are unsupported. Keep credentials out of issues and screenshots. |
| A site rejects a download or shows a browser challenge | Check the site and FanFicFare's current adapter behavior. The native app does not automate interactive challenges. Avoid repeatedly retrying a site that is throttling requests. |
| Queue actions are disabled | Wait for the active operation or cancel/pause it. Reordering and series combining require an idle audiobook queue. |
| A failed book remains in the queue | Select it, use **Retry Selected**, then **Start Queue**. Later books continue after ordinary failures. |
| A series combines in the wrong order | Use **Move Up** / **Move Down** before combining. The merger follows queue order, not checkbox selection order. |
| Title pages are narrated | Open the book, uncheck unwanted sections, and use **Add Open Book** for a queue job with that selection. |
| API preview/export is disabled | Choose the provider, enter your API key, and click **Save Key**. ElevenLabs also needs a valid voice ID. |
| API authentication or permission error | Check the saved provider key, model, voice access, and account permissions. Remove and replace the key if needed. |
| API quota or rate error | Check your provider account and retry explicitly when ready. The app does not automatically retry paid speech. |
| Retrying an audiobook repeats earlier narration | Compatible completed passages are reused in version 1.3. Changed text/settings, discarded checkpoints, or the unfinished passage can require new narration and API charges. |
| One MP3 lacks chapter navigation | Embedded MP3 chapter markers are not implemented. Select **M4B with chapters** or **MP3 per chapter** instead. |
| A developer smoke test reports silent speech | Run it in a normal local terminal with access to macOS speech services. Restricted command sandboxes can produce silent `say` audio. |

Use the GitHub bug template for reproducible problems. Include app/macOS versions, architecture, provider, and sanitized steps. Do not attach personal INI files, API keys, cookies, private URLs, or copyrighted book/audio content. Site-specific credentials should remain local.
