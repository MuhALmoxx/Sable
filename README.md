# Sable

**Sable** is an open-source video player for iPhone. It is built natively in Swift and SwiftUI for
iOS 18+, with a black pixel-art interface. It translates whole subtitle tracks from English to
Arabic, has precise manual subtitle timing, and offers a guided way to sync subtitles that run
early or late.

- Plays the files you already have: MP4/MOV with Apple's hardware-accelerated AVFoundation engine,
  and MKV, WebM, AVI and more with an embedded VLC engine.
- Translates **a whole subtitle track at once** into Arabic that renders correctly from right to
  left, using either free, private on-device translation or Claude with your own Anthropic key.
- Fixes subtitle timing in milliseconds, by hand or by marking one spoken line.

No account, no tracking, no Sable server. MIT-licensed.

---

## Contents

[Features](#features) ·
[Screenshots](#screenshots) ·
[Formats and codecs](#format--codec-support) ·
[Subtitles](#subtitles) ·
[Translation](#translation) ·
[Timing and guided sync](#timing--guided-sync) ·
[Picture in Picture](#picture-in-picture) ·
[Install the IPA](#installing-the-unsigned-ipa) ·
[Build from source](#building-from-source) ·
[CI](#continuous-integration) ·
[Project structure](#project-structure) ·
[Licenses](#licenses)

## Features

**Library**
- Import videos from the Files app. Sable copies them into its library, so files from iCloud Drive
  or a USB drive stay playable.
- Thumbnails, durations, watched-progress bars, search, and sorting by date added, last played,
  title, duration or size. Removing a video deletes its media, subtitles, translations and timing.

**Playback**
- Two engines, chosen per file: **AVFoundation** for files iOS plays natively, with hardware
  decoding and Picture in Picture, and **VLC** (MobileVLCKit 3.7.5) for everything else. You can
  force VLC for all files in Settings.
- Play/pause, a scrubber, skip buttons, and double-tap on the left/right half of the video to seek
  (5/10/15/30 s, configurable).
- Speed from 0.5× to 2×, aspect modes (Fit, Fill, Stretch, 16:9, 4:3, 21:9), audio track switching,
  and background audio.
- Remembers per video: position (resume), speed, audio and subtitle track, aspect, subtitle style.

**Subtitles**
- Embedded text tracks in MKV/WebM (SRT, ASS/SSA, WebVTT) and MP4 (`mov_text`), plus external
  SRT, WebVTT, ASS and SSA files.
- Drawn by Sable on both engines, with adjustable size, position, outline/shadow/box and font.
  Arabic is always set in IBM Plex Sans Arabic, right to left.
- Image-based tracks (PGS/VobSub) are labelled and rendered natively by the VLC engine.

**Translation**
- Whole-track English→Arabic translation that produces a new track with identical timing.
- Apple on-device (free, private) or Claude (your key, billed to you, confirmation before every
  job).
- Chunked with context and a glossary, validated line by line, resumable after cancel or crash,
  and cached.
- Export any track as SRT, optionally with the timing correction baked in.

**Timing and sync**
- Manual offset: ±0.1 s / ±1 s buttons, typed values ("-2.5", "1:02.5", "250ms"), reset and
  50-step undo, saved per video and track.
- Guided sync: mark the moment a line is spoken, pick the line, and Sable computes the offset.
- An English track and its Arabic translation share one timing.

**Interface**
- True-black OLED design with one amber accent, crisp integer-scaled pixel icons, and pixel fonts
  for the interface.
- 44-pt touch targets, VoiceOver labels and Dynamic Type throughout.

## Screenshots

> Screenshots are captured by the UI tests on every `main` build. They are in the
> `logs-and-screens-<sha>` workflow artifact (`screens/`).
> **TODO(integrator):** copy the latest set into `docs/screenshots/` and replace this table.

| Library | Player | Landscape | Tracks |
|---|---|---|---|
| `01-library.png` | `02-player-portrait.png` | `03-player-landscape.png` | `04-tracks.png` |

| Translation | Arabic subtitles | Timing | Guided sync | Settings |
|---|---|---|---|---|
| `05-translation-progress.png` | `06-arabic-subtitles.png` | `07-timing.png` | `08-sync-candidates.png` | `09-settings.png` |

## Format & codec support

Sable picks the engine per file. AVFoundation is used when the file is an MP4/MOV/M4V that iOS
reports as playable. Everything else, and anything AVFoundation fails to open, goes to VLC.
Settings › *Use VLC for everything* forces VLC, which disables Picture in Picture.

| | AVFoundation engine | VLC engine (MobileVLCKit 3.7.5) |
|---|---|---|
| **Containers** | MP4, M4V, MOV (QuickTime) | MKV, WebM, AVI, MP4/MOV, TS/M2TS, MPEG-PS, FLV, OGG/OGV, WMV/ASF, and most other formats VLC demuxes |
| **Video** | H.264, HEVC (incl. 10-bit HDR), with hardware decoding; AV1 on devices with hardware AV1 (iPhone 15 Pro and later) | H.264 and HEVC (hardware via VideoToolbox where possible), VP8/VP9, AV1 (software, dav1d), MPEG-2, MPEG-4 Part 2 (DivX/Xvid), VC-1/WMV, Theora |
| **Audio** | AAC, ALAC, MP3, AC-3/E-AC-3, FLAC, PCM | AAC, MP3, AC-3/E-AC-3, DTS, FLAC, Opus, Vorbis, TrueHD, PCM, WMA |
| **Text subtitles** | drawn by Sable (embedded `mov_text` + external files) | drawn by Sable (embedded SRT/ASS/SSA/WebVTT + external files) |
| **Image subtitles** | not shown | PGS, VobSub, DVB rendered natively by VLC (offset applied) |
| **Picture in Picture** | yes | no |
| **Hardware decoding** | always | where VideoToolbox supports the codec; otherwise software |

Honest notes:
- Software decoding (VP9, AV1 on older iPhones, high-bitrate MPEG-2) uses more battery and can
  drop frames on 4K material.
- HDR and Dolby Vision are shown as intended only with AVFoundation. VLC may show HDR10 with
  approximate tone-mapping, and Dolby Vision profile 5 colours look wrong in VLC.
- The codec list for VLC describes what libvlc 3.x decodes. **TODO(playback):** confirm any codec
  that the MobileVLCKit build turned out not to include, and the exact AVFoundation-vs-VLC
  routing rule.
- DRM-protected files (purchased iTunes videos, Widevine/PlayReady) cannot be played.

## Subtitles

| Format | External file | Embedded in MKV/WebM | Embedded in MP4 | Translatable / guided sync |
|---|---|---|---|---|
| SRT (SubRip) | yes | yes (`S_TEXT/UTF8`) | n/a | yes |
| WebVTT | yes | yes | n/a | yes |
| ASS / SSA | yes | yes | n/a | yes |
| MP4 timed text (`tx3g`/`mov_text`) | n/a | n/a | yes | yes |
| PGS / VobSub / DVB (image) | n/a | listed, VLC renders | n/a | **no** (needs OCR) |

- Text encodings: UTF-8 (with or without BOM), UTF-16 with BOM, Windows-1256 (Arabic),
  Windows-1252 and ISO-8859-1 are detected automatically.
- **Formatting is simplified on purpose.** Line breaks and `<i>`, `<b>`, `<u>` are kept. ASS
  positioning, colours, fonts, karaoke, animation and drawing are removed, and so are WebVTT cue
  positioning and CSS. Sable's own subtitle style applies instead, and alignment (`\an8` "top") is
  used as a hint. Typeset signs therefore show as plain text.
- **Image-based subtitles** (PGS from Blu-ray, VobSub from DVD) are pictures, not text. Sable
  cannot read them, because OCR is **not implemented**. They are labelled "image-based", rendered
  natively by the VLC engine with your offset applied, and are not offered for translation or
  guided sync. Import a text (SRT) version to translate them.

Details: [docs/SUBTITLES.md](docs/SUBTITLES.md).

## Translation

Open **Translate** in the player and choose the source track and the provider. Sable translates the
**whole track** and saves it as a new Arabic track. The new track has the same lines and
timestamps as the source, which is never modified.

| | Apple on-device | Claude (Anthropic) |
|---|---|---|
| Cost | free | **billed to your Anthropic account** (your own API key) |
| Privacy | subtitle text never leaves the iPhone | subtitle text is sent to Anthropic's API under your account; nothing goes to Sable |
| Method | line by line, no context | chunks of about 40 lines with surrounding context and a running glossary of names/terms |
| Quality | good for simple dialogue; names and tone can be inconsistent | consistent names, gender and register; idiomatic subtitles |
| Before it runs | nothing to confirm | **a confirmation before every job** shows the line count, requests, estimated tokens and approximate cost |
| Setup | may download Apple's language assets on first use | paste your API key in Settings › Translation; it is stored only in the iOS **Keychain** (this device only), never in files, settings or logs |

How it works:
- **Chunking:** lines are sent in chunks. Each chunk carries a few earlier lines (with their
  translations) and later lines as read-only context, plus the glossary built so far.
- **Validation:** every line must come back exactly once with its id. Mismatches are detected and
  repaired, so a translation never shifts lines or silently drops one.
- **Resume:** a checkpoint is saved after every chunk. Cancel at any time, or lose the app to a
  crash. **Resume** continues where it stopped, and finished chunks are never sent (or billed) again.
- **Cache:** a finished translation is cached per source content, provider and model. Translating
  the same track again is instant and free.
- The translated track shares the source's timing, so an offset fixed on English also fixes the
  Arabic.

Details, including errors and the mock provider used by the tests:
[docs/TRANSLATION.md](docs/TRANSLATION.md).

## Timing & guided sync

**Positive offset = subtitles appear later.** Original cue times are never modified. The
correction is applied when cues are drawn and, if you choose, when you export.

- **Manual:** open **Timing** while the video plays. Use −1 / −0.1 / +0.1 / +1 s, or type an
  offset (`-2.5`, `+0.25`, `1:02.5`, `-1:02:03.25`, `250ms`, `-2s`, `0,5`) and apply it.
  Reset and Undo (50 steps) are always available. Timing is saved per video and track.
- **Guided sync:** open **Sync**, tap **Mark** the moment someone starts speaking (nudge it if
  needed), then choose that line from the candidates within ±10 s. You can widen to 30 s, 60 s or
  all lines, or search. Sable sets `offset = mark − the line's original start`, which you can
  preview, apply and undo.
- **Limitation:** one offset fixes a **constant** delay. Subtitles that **drift** (for example
  made for a 25 fps release and played against 23.976 fps, about 4 % slower) need a two-point
  correction (`SyncMath.twoPointTiming`). See [docs/SYNC.md](docs/SYNC.md) for how far the UI
  supports it.

## Picture in Picture

PiP is available **only with the AVFoundation engine**, which handles MP4/MOV/M4V files iOS can
play. It uses the system PiP controller, so it keeps playing over other apps. Files played with
VLC (MKV, WebM, AVI, … or everything when *Use VLC for everything* is on) have no PiP, and the PiP
button is not offered for them.

**TODO(playback):** state whether Sable's subtitles appear inside the PiP window. Sable draws them
in its own overlay, so by default they are not.

## Installing the unsigned IPA

Each build of `main` publishes **`Sable-unsigned.ipa`** on the
[`latest` pre-release](https://github.com/MuhALmoxx/Sable/releases/tag/latest), with its SHA-256.
Every CI run also uploads `Sable-unsigned-ipa-<sha>` as a workflow artifact.

The IPA is a real **device** build (arm64, iphoneos, MobileVLCKit embedded), but it is **unsigned**.
**It must be signed before iOS will install it.** Choose one of:

1. **AltStore / SideStore** (with your Apple ID): open the IPA with the app. Free accounts must
   refresh the app every 7 days and can have at most 3 sideloaded apps.
2. **Sideloadly** (macOS/Windows, with your Apple ID): drag in the IPA, sign in and install.
3. **Your own certificate + provisioning profile:** re-sign with `codesign` (framework first, then
   the app) and install it with Xcode or `xcrun devicectl`. Step-by-step commands:
   [docs/SIGNING.md](docs/SIGNING.md). CI can also produce a signed IPA from repository secrets
   (same document).

iOS 16+ also requires **Developer Mode** (Settings › Privacy & Security) for sideloaded apps. No
simulator build is distributed as an IPA. For the simulator, build from source.

## Building from source

Requirements: a Mac with **Xcode 26** (iOS 26 SDK; the app targets iOS 18.0+),
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and `curl`/`tar`.

```sh
git clone https://github.com/MuhALmoxx/Sable.git
cd Sable
./scripts/fetch-vlckit.sh     # MobileVLCKit 3.7.5 -> Vendor/ (pinned URL + SHA-256, idempotent)
xcodegen generate             # creates Sable.xcodeproj from project.yml
open Sable.xcodeproj          # select your team under Signing & Capabilities, then Run
```

- Core tests, no Xcode needed (macOS or Linux, Swift 6.1+):
  `swift test --package-path Packages/SableKit`
- App unit + UI tests: `xcodebuild test -project Sable.xcodeproj -scheme Sable -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
  ([docs/TESTING.md](docs/TESTING.md))
- Unsigned device build, as CI does it:
  `xcodebuild -project Sable.xcodeproj -scheme Sable -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- Test fixtures are regenerated with `Fixtures/make_fixtures.sh` (needs ffmpeg).

## Continuous integration

`.github/workflows/ios.yml` runs on every push to every branch. Pushes that touch only docs are
skipped.

| Job | Steps |
|---|---|
| **Core tests (Linux)** | `swift test` for SableKit in the `swift:6.1.2` container |
| **iOS build, tests, IPA** (macOS) | package tests → XcodeGen → **unsigned Release device build** → IPA packaging → **IPA verification** (Payload/Sable.app, arm64 device Mach-O, iOS platform, MobileVLCKit embedded and dynamically linked, `DTPlatformName = iphoneos`, fonts present, no test fixtures) → artifact `Sable-unsigned-ipa-<sha>` → simulator **build-for-testing** (compiles AppTests/UITests on every branch) → on `main` or manual dispatch: **simulator unit + UI tests** with screenshot export (`logs-and-screens-<sha>`) → optional **signed IPA** when signing secrets exist → on `main`: **rolling `latest` pre-release** |

The job summary shows the IPA's size, SHA-256, architectures and platform, plus the test results.
The simulator is chosen to match the Xcode SDK, and one is created if none exists. Long-running
steps have timeouts, and each test has a time limit, so a hung simulator fails fast instead of
using the whole job budget.

Manual run with simulator tests on any branch:
`gh workflow run ios.yml --ref <branch> -f ui_tests=true [-f only_testing="SableTests"]`.

## Project structure

```
App/                    iOS app (SwiftUI; UIKit where needed)
  Core/                 AppServices (dependency container), AppSettings, RootView,
                        accessibility identifiers, UITestSupport (DEBUG only)
  DesignSystem/         Palette/Spacing/Typo tokens, fonts, PixelIcon glyphs, components
  Library/              library grid, import, search/sort/remove
  Player/               AVFoundation + VLC engines, PlayerSession, controls, gestures, PiP,
                        track pickers, subtitle overlay, probing, thumbnails
  Translation/          translation service + sheet, settings section, Keychain store
  Sync/                 timing panel, guided sync
  Settings/             settings, about and licenses
  Resources/            asset catalog, bundled fonts
Packages/SableKit/      Foundation-only Swift package, tested on Linux and macOS
  SubtitleKit/          cue model, SRT/VTT/ASS parsers, SRT writer, Matroska reader,
                        tx3g decoder, timing + sync math
  TranslationKit/       provider protocol, chunking, validation, resumable engine, Claude provider
  LibraryKit/           media items, playback memory, library store, timing store
AppTests/, UITests/     hosted unit tests and XCUITest journeys
Fixtures/               ffmpeg-generated sample media + subtitles (Debug-only bundle)
scripts/                fetch-vlckit.sh
tools/ci/               IPA verification, simulator picker, signing, test summaries
docs/                   CONTRACTS (architecture), SUBTITLES, TRANSLATION, SYNC, TESTING, SIGNING
licenses/               third-party license texts
```

## Licenses

- **Sable** is MIT-licensed. See [LICENSE](LICENSE).
- **MobileVLCKit 3.7.5** (VideoLAN) is LGPL-2.1. It is the official binary, unmodified, embedded as
  a dynamically linked framework, so you can replace it with your own build.
- **IBM Plex Sans Arabic, Pixelify Sans and Silkscreen** are licensed under the SIL Open Font
  License 1.1.

Copyright lines, source links and relinking instructions are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The license texts are in [`licenses/`](licenses/).
