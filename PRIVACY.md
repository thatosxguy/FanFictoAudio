# Privacy and data handling

This describes version 1.3.0 of FanFic to Audio. The app has no application analytics or telemetry implementation and no developer-operated backend.

For Dr. Matt Booth's handling of support correspondence, contributions, and privacy requests, see the [Publisher Privacy Policy](https://github.com/thatosxguy/policies/blob/main/PRIVACY-POLICY.md). The project's [Terms of Service](https://github.com/thatosxguy/policies/blob/main/TERMS-OF-SERVICE.md) preserve its open-source license rights. Contact [admin@strixmcs.com](mailto:admin@strixmcs.com) for privacy questions.

## Local data

- EPUB downloads, combined series, and MP3/M4B outputs are written to the destinations you choose. Updating an existing FanFicFare book creates a backup beside it.
- UserDefaults stores ordinary preferences: selected destination paths, selected INI path, FFmpeg path, macOS voice/rate/bitrate, provider, model/voice identifiers, and the audiobook queue output folder. It does not store provider API keys or a copy of your INI contents.
- API keys are saved only when you click **Save Key**, as generic-password items in macOS Keychain under service `com.matt.fanfictoaudio.tts`. New entries use the unlocked, device-only accessibility setting. **Remove Key** deletes the selected provider's item.
- The selected `personal.ini` remains your file. FanFicFare reads it and may use configured credentials, cookie files, proxies, or services. These files are not imported into this repository or shipped with the app.
- The audiobook queue, per-book narration presets (without keys), selected row, and AI usage totals are saved under `~/Library/Application Support/FanFicToAudio`. UserDefaults also stores budget limits and estimated per-model rates. Usage totals contain counts and estimated costs, not text or credentials.
- Completed narration passages and checksums are saved in that directory's `Checkpoints` folder for resume. They contain generated audio of the story and are retained after cancellation/failure. Matching checkpoints are deleted after successful publication; removing a queue row or selecting **Discard Saved Passages** deletes that job's checkpoints. Other checkpoints can be deleted manually while idle.
- The download queue and book previews last for the app session. EPUB text and downloader session data use bounded in-memory caches. Job requests and generated audio use temporary files, with normal completion/cancellation cleanup; a process crash can leave temporary files behind.
- The app is not built with the macOS App Sandbox. It can access user-selected files and run its helper, `say`, and the FFmpeg executable you select.

## Network behavior

| Action | External destination / data |
| --- | --- |
| Download, update, metadata preview, or extract links | The selected website and resources through FanFicFare; configured site authentication may be sent there |
| Narrate or preview using macOS voices | Local speech generation; the app makes no speech-provider request |
| Narrate or preview using OpenAI | Book passages and narration settings to OpenAI's speech endpoint, authenticated with your key |
| Narrate or preview using ElevenLabs | Book passages and voice/model settings to ElevenLabs' speech endpoint, authenticated with your key |
| Load ElevenLabs voices | Your account's voice-library endpoint, authenticated with your key; no book text is needed |

AI calls are billed and governed by your provider account. Provider retention and account policies are outside this app's control; consult the provider before sending sensitive text. Cancellation stops the active request but cannot retract text already sent or guarantee that a provider will not charge for it.

AI narration is identified in the interface and audio comment metadata. Raw provider error bodies are omitted from displayed API errors. Download errors and file paths may still reveal site or local information; review them before sharing a report.

## Removal and public reports

Remove keys with the app's **Remove Key** control. Removing the app bundle does not remove preferences, Keychain entries, EPUBs, audio, backups, saved queue/usage records, or resume checkpoints. You can manage the app's preferences and Keychain records with macOS tools if needed.

This public repository and its release assets contain application code/resources and synthetic fixtures, not user settings, credentials, books, generated audio, or local validation screenshots. Keep those out of contributions and bug reports.
