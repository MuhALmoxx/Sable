# Testing Sable

| Layer | Where | Runs on | What it covers |
|---|---|---|---|
| Core (SableKit) | `Packages/SableKit/Tests` | Linux + macOS, every push | parsing, Matroska extraction, timing/sync math, translation engine, library store |
| Hosted unit tests | `AppTests/` (`SableTests`) | iPhone simulator | app services with the real fixtures, design system, settings, test hooks |
| UI journeys | `UITests/` (`SableUITests`) | iPhone simulator | the user journeys below, with screenshots |

```sh
swift test --package-path Packages/SableKit                      # core, any platform
xcodegen generate && ./scripts/fetch-vlckit.sh
xcodebuild test -project Sable.xcodeproj -scheme Sable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'        # unit + UI tests
xcodebuild test ... -only-testing:SableUITests/GuidedSyncUITests  # one journey
```

## Launch arguments (DEBUG builds only, `App/Core/UITestSupport.swift`)

| Argument | Effect |
|---|---|
| `-uiTesting` | before services exist: deletes the library root, the app's UserDefaults domain, the app's Keychain items and files in Documents; disables UIKit animations |
| `-seedLibrary` | imports `night-roof.mkv` and `night-roof.mp4` (copies) as **"Night Roof (MKV)"** and **"Night Roof (MP4)"**, attaches `night-roof.late.en.srt` to the MP4, then generates durations and thumbnails in the background. Idempotent |
| `-mockTranslation` | the translation feature registers its offline mock provider, which returns `UITestSupport.referenceTranslations()` |
| `-mockTranslationDelay <s>` | seconds the mock waits per chunk (`UITestSupport.mockTranslationDelay`, default 0.8) so tests can watch progress and cancel mid-way |

A relaunch **without** `-uiTesting` keeps everything, which is how persistence is tested.

## Fixtures (`Fixtures/UITestFixtures`, Debug bundle only)

| File | Content |
|---|---|
| `night-roof.mkv` | 40 s H.264 960×540; audio "Dialogue" + "Commentary" (AAC); subtitles TrackNumber 4 SRT en (default), 5 ASS en (styled, 10 lines incl. a sign), 6 SRT fr |
| `night-roof.mp4` | same video/audio; mov_text en (track ID 4) |
| `night-roof.late.en.srt` | the English dialogue **2.5 s late**: cue "2" ("I can't sleep. …") starts at 10.0 s, but its speech burst in the audio starts at 7.5 s |
| `reference-translations.ar.json` | human-written Arabic for every line, used only by the mock provider |

The audio "speech" bursts start exactly at each cue start of `Fixtures/src/sample.en.srt` (3.0, 7.5,
12.0, 16.5, 17.6, 21.0, 25.5, 30.0, 34.5 s).

## Journeys and screenshots

| Test | Verifies | Screenshots |
|---|---|---|
| `SmokeUITests` | app launches to the library | `00-launch` |
| `LibraryUITests` | empty state after `-uiTesting`; both seeded items listed; Settings opens and the licenses mention VLC | `01-library`, `09-settings` |
| `PlaybackUITests` | MP4 opens, playback time advances by ≥ 2 s, duration ≈ 40 s, landscape layout, pause stops the clock, MKV lists both audio tracks | `02-player-portrait`, `03-player-landscape` |
| `SubtitleTracksUITests` | MKV lists `emb:mkv:4/5/6` + Off; French then English text appears; Off clears it; MP4 lists `emb:mp4:4` and the external SRT, whose text appears | `04-tracks`, `04b-external-srt` |
| `TranslationUITests` | mock translation of the English track reaches 100 % and Arabic text is shown; cancel mid-way → Resume continues from the checkpoint (never below it, never from 0); export shows an `.srt` path | `05-translation-progress`, `05b-translation-cancelled`, `05c-translation-exported`, `06-arabic-subtitles` |
| `TimingUITests` | `0.000 s` → +0.1 → `+0.100 s` ("later") → −0.1 → `0.000 s`; typed `-2.5` → `−2.500 s` ("earlier"), +1 → `−1.500 s`, Reset → `0.000 s`, Undo, Undo | `07-timing` |
| `GuidedSyncUITests` | on the late SRT: park playback at the spoken line, Mark, pick cue "2", computed offset = marked − 10.000 s (negative), Apply; timing panel shows it; Undo → `0.000 s` | `08-sync-candidates` |
| `PersistenceUITests` | +0.1 s timing, external SRT selected, play past 12 s, close; terminate + relaunch without `-uiTesting`: position resumes (≥ saved − 3 s within 5 s), the external row is still selected, offset still `+0.100 s` | `10-relaunch-resumed` |
| `ParsingHelperUITests` | the label parsers used by the journeys (no app launch) | none |

CI exports the screenshots to the `logs-and-screens-<sha>` artifact (`screens/NN-name.png`), and the
job summary lists every test with its result and skip reason.

## What the journeys expect from the UI

The tests find everything through the identifiers in `App/Core/AccessibilityIDs.swift` and wait with
predicates, never fixed sleeps. They rely on these behaviours:

- **Library:** each item is tappable with identifier `AX.Library.item(title)`.
- **Player chrome** may auto-hide. A single tap on the upper part of `AX.Player.surface` shows it.
  Translate / Timing / Sync may sit directly in the chrome or behind `AX.Player.moreButton`.
  `AX.Player.playPause` is labelled "Pause" while playing and "Play" while paused.
  `AX.Player.currentTime` / `duration` labels are clock strings (`0:07`, `1:02:03`).
- **Sheets** close with their close button (accessibility label "Close") or a downward swipe.
  Selecting a track row may close the sheet itself.
- **Track rows** `AX.Tracks.subtitle(id)` use the track ids from the contracts. The selected row
  carries the `.isSelected` accessibility trait (or an accessibility value containing "selected").
- **Subtitle overlay:** `AX.Player.subtitleText` is present while a cue is visible, and its label is
  the cue text.
- **Translation:** `AX.Translation.progressLabel` contains a percentage or "n / total" (the
  progress bar's value "NN percent" also works). `cancel` stops after the current chunk, and
  `resume` appears afterwards. `showArabic` (or the `tr:ar:` track row) activates the result.
  `exportedPath` shows the written file's path or name, ending in `.srt`. With `-mockTranslation`
  the free mock provider is preselected, so no paid confirmation appears. The mock must pace its
  chunks with `UITestSupport.mockTranslationDelay` and use chunks small enough (≤ 3 lines) that a
  9-line track takes several chunks.
- **Timing:** `AX.Timing.offsetValue` shows `TimecodeFormatter.signedOffset` (`+0.100 s`,
  `−2.500 s`, `0.000 s`). `offsetMeaning` contains "later" / "earlier". Submitting the entry field
  with Return or tapping Apply applies a typed value. Every change is undoable.
- **Sync:** `AX.Sync.mark` marks the current playback position. `markedTime` shows it as a clock
  string, ideally with milliseconds. Candidates are `AX.Sync.candidate(cueID)`. `computedOffset`
  uses the signed-offset format. `apply` (+ optional `confirm`) applies it and the flow closes.

## Skips

Hosted unit tests that exercise another owner's code detect skeleton stubs at run time
(`SubtitleError.notImplemented`, the placeholder probe result, an empty track list) and call
`XCTSkip`, so the suite stays green before integration and becomes live after it. The skip reason
appears in the CI summary. UI journeys are not skipped. They need the integrated app.

## Running a subset on CI

Simulator tests run automatically on `main`. On another branch, dispatch the workflow:

```sh
gh workflow run ios.yml --ref <branch> -f ui_tests=true \
  -f only_testing="SableTests SableUITests/TimingUITests"
```
