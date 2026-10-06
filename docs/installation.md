# Installation

[Back to the README](../README.md) · [User guide](usage.md)

## Requirements

| Component | Requirement |
| --- | --- |
| Mac | Apple silicon (M-series) for the supplied ZIP |
| macOS | 14 or later |
| MP3 encoder | FFmpeg with the `libmp3lame` encoder, installed separately |
| Local narration | At least one voice exposed by macOS `say` |
| AI narration | Your own OpenAI or ElevenLabs API key and available API quota |
| Network | Needed for story downloads and AI speech; existing EPUBs with macOS voices work locally |

The app includes Python and FanFicFare. You do not need either original application or a separate Python installation to use the release.

## Install the release

1. Open [Releases](https://github.com/thatosxguy/FanFictoAudio/releases/latest).
2. Download `FanFic-to-Audio-macOS-AppleSilicon.zip` and its `.sha256` file from the same release. GitHub's **Source code** ZIP is the source tree, not the ready-to-run app.
3. Optionally verify the downloaded archive from the folder containing both files:

   ```sh
   shasum -a 256 -c FanFic-to-Audio-macOS-AppleSilicon.zip.sha256
   ```

4. Extract the ZIP, then drag **FanFic to Audio.app** into Applications. Keep the whole bundle intact.
5. Open the app. This release is **ad hoc signed, not Developer ID signed or notarized**, so macOS may block its first launch. If you trust the downloaded release, follow Apple's [instructions for opening an app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac): attempt to open it, then use **System Settings → Privacy & Security → Open Anyway**, when available, and confirm the app-specific exception. Managed Macs may prohibit exceptions.

The checksum detects an altered download relative to the published file; it does not replace Developer ID signing or notarization. If the app cannot be approved on your Mac, you can [build from source](development.md).

## Install FFmpeg

If [Homebrew](https://brew.sh) is already installed:

```sh
brew install ffmpeg
ffmpeg -hide_banner -encoders | rg libmp3lame
```

You can inspect the encoder list directly if `rg` is not installed. The app checks `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, and `/opt/local/bin/ffmpeg`. For another location, select your executable in the app's Settings. A compatible MacPorts installation also works.

FFmpeg is required for every MP3 export, including OpenAI and ElevenLabs narration. FFprobe is used by the developer smoke script, rather than by normal app exports.

## Add macOS voices

Download voices through macOS System Settings → Accessibility speech settings, then refresh voices in the app's Settings. Names vary across macOS versions. A voice must appear in `/usr/bin/say -v '?'` to be usable here.

## Upgrade or remove

Quit the app and replace its bundle in Applications with the new release. Your selected paths and narration preferences live outside the bundle; provider keys are stored separately in Keychain. Keep your EPUBs and MP3s in a folder you choose.

To remove a provider key, choose the provider and use **Remove Key** before removing the app. Deleting the app bundle does not delete your books, audio, preferences, or Keychain entries. See [Privacy](../PRIVACY.md).
