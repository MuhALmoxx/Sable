# Sable — engineering contracts and ownership

Sable is a native iPhone video player (SwiftUI, iOS 18+) with a black pixel-art interface,
whole-track English→Arabic subtitle translation, precise manual timing and guided subtitle sync.

## Architecture

```
Packages/SableKit            Foundation-only, builds + tests on Linux and macOS
  SubtitleKit                cue model, SRT/VTT/ASS parsers, SRT writer, Matroska text-track
                             extraction, tx3g decoding, timing math (SubtitleTiming, SyncMath, CueIndex)
  TranslationKit             provider protocol, chunk planner, validation/repair, resumable
                             TranslationEngine (checkpoints + cache), Claude provider (HTTP)
  LibraryKit                 MediaItem, PlaybackMemory, LibraryStore (JSON), TimingStore
App/                         iOS app target (SwiftUI + UIKit where needed)
  Core/                      AppServices (DI), AppSettings, RootView, AX ids, UITestSupport
  DesignSystem/              Palette, Spacing, Typo, SableFonts, PixelIcon/PixelGlyph, components
  Library/                   library screen, import (Files picker), search/sort/remove
  Player/                    engines (AVFoundation + VLCKit), PlayerSession, PlayerScreen,
                             controls, gestures, PiP, track pickers, subtitle overlay,
                             MediaProbeService, ThumbnailService, SubtitleRepository
  Translation/               TranslationService, TranslationSheet, settings section,
                             KeychainStore, Apple on-device provider bridge
  Sync/                      TimingPanel (manual offsets), GuidedSyncView (match a spoken line)
  Settings/                  settings + about/licenses
Fixtures/                    fixture generation (ffmpeg) + UITestFixtures (Debug-only bundle resources)
UITests/, AppTests/          XCUITest journeys with screenshots, hosted unit tests
```

Engines: `AVFoundationEngine` (AVPlayer) for files AVFoundation can play (MP4/MOV/M4V with
H.264/HEVC/AAC…) — hardware decoding and system Picture in Picture. `VLCEngine` (MobileVLCKit 3.7.5,
LGPL-2.1, dynamic framework embedded in the app) for everything else (MKV, WebM, AVI, …) and as a
fallback. Sable draws all TEXT subtitles itself (SwiftUI overlay) so offsets, translation and Arabic
shaping behave identically on both engines; VLC's own subtitle renderer is disabled except for
image-based tracks (PGS/VobSub), which VLC renders natively with the user's delay applied.

## Ownership (edit only the files you own)

| Agent | Owns |
|---|---|
| subtitles-core | `Packages/SableKit/Sources/SubtitleKit/**` (except Models.swift/Timing.swift: integrator), `Tests/SubtitleKitTests/**`, `Fixtures/make_fixtures.sh` + generated fixtures |
| translation | `Packages/SableKit/Sources/TranslationKit/**`, `Tests/TranslationKitTests/**`, `App/Translation/**` |
| playback | `App/Player/**`, `App/Subtitles/**` |
| sync | `App/Sync/**`, `Packages/SableKit/Sources/LibraryKit/TimingStore.swift` (+ its tests `Tests/LibraryKitTests/TimingStoreTests.swift`) |
| library | `App/Library/**`, `App/Settings/**`, `App/Core/{SableApp is App/SableApp.swift, AppServices, AppSettings, RootView}`, `Packages/SableKit/Sources/LibraryKit/**` (except TimingStore.swift), `Tests/LibraryKitTests/**` (except TimingStoreTests) |
| design | `App/DesignSystem/**`, `App/Resources/Assets.xcassets/**`, `design/**` (icon source + generator) |
| build-qa | `project.yml`, `.github/**`, `scripts/**`, `tools/**`, `UITests/**`, `AppTests/**`, `App/Core/UITestSupport.swift`, `README.md`, `THIRD_PARTY_NOTICES.md`, `docs/` (except this file) |
| integrator | `docs/CONTRACTS.md`, `SubtitleKit/Models.swift`, `SubtitleKit/Timing.swift`, `App/Core/AccessibilityIDs.swift` (others may ADD identifiers there) |

Need a change in a file you don't own? Write it in your final report ("CONTRACT CHANGE REQUEST")
with the exact diff; the integrator applies it. Adding new files inside your own folders is free.

## Semantics everyone relies on

- Cue timestamps are ORIGINAL and immutable. Display/export uses `SubtitleTiming`:
  `effective = original * scale + offset`. **Positive offset = subtitles appear LATER.**
- Timing is stored per (video, `timingGroupID`). A translated track shares its source track's group,
  so English and its Arabic translation stay in sync together. Key: `TimingStore.key(videoID:timingGroupID:)`.
- Guided sync: `offset = markedSpeechStart − originalCueStart` (`SyncMath.timing`). Candidate cues:
  `SyncMath.candidateCues(... window: 10 ...)` over EFFECTIVE times; widen to 30 s, 60 s, ∞, or text search.
  A single offset fixes constant delay only; drift needs a second point (`SyncMath.twoPointTiming`).
- A guided-sync session is ONE undo step: its first change is `setTiming(_, undoable: true)`, later
  changes in the flow use `undoable: false`, and its Undo calls `undoTiming()`. PlayerSession updates
  `timing`/`canUndoTiming` synchronously in setTiming/undoTiming/resetTiming/nudgeOffset and passes
  `undoable` straight to TimingStore (which skips no-op pushes).
- `TimingPanel(session:onClose:onChooseTrack:)` / `GuidedSyncView(session:onClose:onChooseTrack:)`:
  `onChooseTrack` opens the player's subtitle track list from their empty state. Both views set their
  own presentation detents + background interaction; present them with a plain `.sheet`.
- Track ids: `ext:<uuid>`, `emb:mkv:<trackNumber>`, `emb:mp4:<trackID>`, `tr:<lang>:<sourceTrackID>`.
- Image-based subtitle tracks (`kind == .image`) are listed and labelled "image-based", are never
  offered for translation/guided sync, and on VLC are rendered natively.
  When one is selected, `PlayerSession.activeSubtitle` holds it with an EMPTY document (VLC draws it);
  Sync/Translation must check `activeSubtitle?.descriptor.kind == .text` before using its cues.
- `PlaybackMemory.subtitleTrackID`: nil = never chosen (auto default), "off" = explicitly off.
- Switching subtitle tracks (`PlayerSession.selectSubtitleTrack`) never pauses or seeks. The previous
  track leaves the screen at once: while the new document loads, `activeSubtitle` is nil and
  `loadingSubtitleTrackID` names the track; once loaded it is drawn at the current position. A failed
  load puts the previous track back and reports the error in `subtitleLoadState`.
- Translation never mutates the source track; it produces a new track with identical cue ids/timestamps.
- Paid providers never run without an explicit confirmation sheet showing cue count and estimated tokens.
  API keys live only in the Keychain (`KeychainStore`), never in code, logs or UserDefaults.
- Arabic text always renders with IBM Plex Sans Arabic (`SableFonts.arabic*`), right-to-left paragraph
  direction (prefix U+200F per line when drawing in SwiftUI), never with pixel fonts.

## Design rules

- Black (`Palette.background`) first; surfaces `surface/surfaceRaised/surfaceHigh`; 1-px borders.
- One accent (`Palette.accent`, phosphor amber) for the primary action, progress and active state only.
- Pixel type (`Typo.display/title/headline/body/micro`) for chrome; `Typo.reading` for explanations;
  `Typo.mono` for timecodes. No gradients, no glassmorphism, no card soup.
- Icons are `PixelIcon(.glyph)` only (no SF Symbols in visible chrome) — crisp, integer-scaled.
- Every interactive control: ≥ 44 pt hit area, `accessibilityLabel`, and an `AX.*` identifier when
  UI tests need it.

## Build and verify

- Local (Linux) core tests: `source ~/.local/swift-tc/env.sh && swift test --package-path Packages/SableKit`
- CI (GitHub Actions, macOS): every pushed branch runs Linux core tests, an unsigned Release device
  build + IPA verification (`tools/ci/verify_ipa.sh`) and a simulator `build-for-testing` (compiles
  AppTests/UITests). `main` (or a manual dispatch with `ui_tests`, optionally `only_testing`) also
  runs simulator unit/UI tests, exports screenshots and publishes the IPA. iOS code can only be compiled on CI: push your branch
  (`git push origin HEAD:refs/heads/agent/<name>`), then `gh run watch` / `gh run view --log-failed`.
- Swift 5 language mode everywhere (app `SWIFT_VERSION 5.0`, package `swiftLanguageModes [.v5]`).
- MobileVLCKit headers for reference (Swift module `MobileVLCKit`): see
  `Vendor/MobileVLCKit.xcframework/ios-arm64_armv7_armv7s/MobileVLCKit.framework/Headers/` after
  `scripts/fetch-vlckit.sh`.
- DEBUG launch arguments `-uiTesting`, `-seedLibrary`, `-mockTranslation`, `-mockTranslationDelay <s>`
  are defined in `App/Core/UITestSupport.swift`; docs/TESTING.md lists what the UI journeys expect.
