# Verification — October 5, 2026

## Automated checks

`./Scripts/swift.sh test` passed all 17 Swift Testing tests on this Apple silicon Mac with Apple's Swift 6.4 Command Line Tools.

Coverage includes EPUB 3 package location and spine order, EPUB 2 NCX labels, percent-encoded references, readable paragraph/inline text, hidden/script/style exclusion, speech-control markup, damaged ZIP data and CRCs, unsafe/duplicate ZIP names, missing spine resources, encrypted text versus obfuscated fonts, external entities, long passages, voice names, safe filenames, cancellation, existing output preservation, and rejection of empty/silent synthesized audio.

## Real conversion

An original two-section demo EPUB was generated with `Scripts/create-demo.py`. Its manifest lists section two before section one, while its spine specifies section one before section two. Inspection and export retained spine order.

The actual command-line companion, using the same conversion core as the GUI, exported:

| Output | Voice | Audio duration |
| --- | --- | --- |
| `dist/Demo.mp3` | Samantha, 175 wpm | 25.499 seconds |
| `dist/Demo Chapters/001 - The Open Book.mp3` | Ava (Premium), 175 wpm | 13.755 seconds |
| `dist/Demo Chapters/002 - The Journey Home.mp3` | Ava (Premium), 175 wpm | 13.536 seconds |

FFprobe confirmed MP3, 22,050 Hz, mono, and expected title/artist/album/genre metadata. Separate files had track metadata `1/2` and `2/2`. FFmpeg fully decoded all three files without errors. The combined audiobook had measured peak volume of -3.1 dB and mean volume of -17.5 dB, confirming non-silent audio.

Restricted command execution caused macOS `say` to return success with zero speech frames. Normal local execution produced real speech. This discovery led to an explicit decoded-sample check in the exporter and a regression test rejecting empty and silent input before MP3 padding can mask the failure.

## App packaging and interface

The release build produced an Apple silicon `.app` bundle with a custom icon and EPUB document registration. `codesign --verify --deep --strict` accepted its local ad hoc signature, and `plutil -lint` accepted its plist.

The packaged application launched. Its window, installed voice selector, EPUB import dialog, chapter selection, book metadata, text preview, speaking speed, and enabled export controls were inspected through the native UI. An imported book was visible in the live app. End-to-end output verification was performed through the shared command-line core; a full export driven exclusively by GUI clicks was not completed because the user was interacting with the app. Their open session was preserved.

Long-book completion, every installed voice, Intel execution, older macOS versions, and distribution/notarization were not tested. See `README.md` for requirements and current limitations.

## Faster speaking speeds

The speaking-speed range was increased from 80–350 to 80–1,000 WPM for previews and exports, using a shared range for the slider and conversion validation. All 17 tests passed after the change, and the app was rebuilt and its signature verified. The demo exported successfully with Samantha at the requested 1,000 WPM setting, producing a 7.670-second MP3 that decoded without errors, compared with 25.499 seconds at 175 WPM. Exact delivered speech rates depend on the macOS voice.
