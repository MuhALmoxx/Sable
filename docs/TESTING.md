# Testing Sable

## Status

All automated tests run on **GitHub Actions**: the SableKit package tests on Linux (`swift:6.1.2`
container) and macOS, and the hosted unit tests and XCUITest journeys on an iOS simulator (on
`main`, or on a manual dispatch with `ui_tests`). The job summary lists every test with its result
and any skip reason. UI journeys share a 40-second sample clip and slow, shared simulators, so CI retries a failed
test once (`-retry-tests-on-failure -test-iterations 2`); a retried test shows both attempts in the log.

**No testing has been done on a physical iPhone.** Behaviour that only a device shows is
unverified: hardware decoding and performance, Picture in Picture, background behaviour, rotation
and gestures on real hardware, VLC's aspect/crop modes and native image subtitles, Apple's
on-device translation (it does not run in the Simulator, so the UI tests use the mock provider),
installing the sideloaded IPA, and the optional CI signing path (no signing secrets exist). No live
Claude API call has been made; the Claude provider is tested against a fake HTTP client.

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
| `-mockTranslation` | the translation feature registers its offline mock provider ("Mock (UI tests)", free, preselected, 3 lines per chunk), which returns the reference Arabic from `reference-translations.ar.json` |
| `-mockTranslationDelay <s>` | seconds the mock waits per chunk, so tests can watch progress and cancel mid-way. `MockTranslationProvider` reads the argument itself and defaults to 0.4 s (`UITestSupport.mockTranslationDelay` reports 0.8 s, but the mock does not use it) |
| `-mockTranslationPaid` | marks the mock as paid, so the paid-confirmation step (`AX.Translation.confirmPaid`) appears |

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
| `SubtitleTracksUITests` | track switches **during playback** (no pause, rewind or seek around a switch; a rewind happens only before opening the track list when too little of the clip is left). MKV: lists `emb:mkv:4/5/6` + Off, English (default) → French → Off → English; MP4: embedded `emb:mp4:4` → external SRT → Off → external; MKV: English ↔ Arabic translation (mock, `-mockTranslationDelay 0.1`). After each switch the old track's text must be gone (any overlay reading from the old track fails the test) and the new track's text must appear within 12 s; Off must clear the overlay within 2 s and keep it empty for 4 s | `04-tracks`, `04b-external-srt` |
| `TranslationUITests` | mock translation of the English track reaches 100 % and Arabic text is shown; cancel mid-way → Resume continues from the checkpoint (never below it, never from 0); export shows an `.srt` path | `05-translation-progress`, `05b-translation-cancelled`, `05c-translation-exported`, `06-arabic-subtitles` |
| `TimingUITests` | `0.000 s` → +0.1 → `+0.100 s` ("later") → −0.1 → `0.000 s`; typed `-2.5` → `−2.500 s` ("earlier"), +1 → `−1.500 s`, Reset → `0.000 s`, Undo, Undo | `07-timing` |
| `GuidedSyncUITests` | on the late SRT: park playback at the spoken line, Mark, pick cue "2", computed offset = marked − 10.000 s (negative), Apply; timing panel shows it; Undo → `0.000 s` | `08-sync-candidates` |
| `PersistenceUITests` | +0.1 s timing, external SRT selected, play past 12 s, close; terminate + relaunch without `-uiTesting`: position resumes (≥ saved − 3 s within 5 s), the external row is still selected, offset still `+0.100 s` | `10-relaunch-resumed` |
| `ParsingHelperUITests` | the label parsers used by the journeys (no app launch) | none |
| `ChatGPTSignInUITests` | Settings › Translation shows the signed-out ChatGPT plan block after `-uiTesting`: the "Sign in with ChatGPT" button (never tapped — no ChatGPT account or network login on CI, and no fake signed-in mode), the disclosure text (Plus or Pro, counts toward ChatGPT usage limits, not OpenAI API access) and the "OpenAI preview" tag; no sign-out/account controls | `11-settings-chatgpt` |

ChatGPT plan hosted unit tests (`AppTests/`): `ChatGPTKeychainStoreTests` (credential/account
round trip, sign-out keeps the account, `ext_agent_host_id` created once and persisted; one test
uses the real Keychain under a throwaway service and skips with a reason if the unsigned simulator
build has no Keychain access), `ChatGPTLoopbackServerTests` (real TCP on 127.0.0.1: callback
delivered once with a 200 page and the receiver stops; wrong paths 404, other methods 405, a
foreign `state` 400, busy preferred port falls back, timeout; request parsing) and
`ChatGPTPlanOptionTests` (settings keys, provider tags, plan error messages, model choice).

Subtitle switching hosted unit tests (`AppTests/SubtitleSwitchingTests`) drive `PlayerSession`
without an engine (clock at 0 s; each timing group offset so its first line shows at 0 s): embedded
English → French (the English text is gone while French loads) → Off → English; embedded MP4 →
external → Off → external; English ↔ Arabic translation (shared timing group, original text);
library changes leave a shown translation alone while a regenerated one is swapped in place; a
failed switch brings the previous track back with the error.

CI exports the screenshots to the `logs-and-screens-<sha>` artifact (`screens/NN-name.png`), and the
job summary lists every test with its result and skip reason.

## What the journeys expect from the UI

The tests find everything through the identifiers in `App/Core/AccessibilityIDs.swift` and wait with
predicates, never fixed sleeps. They rely on these behaviours:

- **Library:** each item is tappable with identifier `AX.Library.item(title)`.
- **Player chrome** never auto-hides under `-uiTesting` (nor while VoiceOver or Switch Control
  runs). Otherwise it hides after 3 s of playback, and a single tap on `AX.Player.surface` shows it.
  Translate / Timing / Sync may sit directly in the chrome or behind `AX.Player.moreButton`.
  `AX.Player.playPause` is labelled "Pause" while playing and "Play" while paused.
  `AX.Player.currentTime` / `duration` labels are clock strings (`0:07`, `1:02:03`).
- **Sheets** close with their close button (accessibility label "Close") or a downward swipe.
  Selecting a track row may close the sheet itself.
- **Track rows** `AX.Tracks.subtitle(id)` use the track ids from the contracts. The selected row
  carries the `.isSelected` accessibility trait (or an accessibility value containing "selected").
- **Subtitle overlay:** `AX.Player.subtitleText` is present while a cue is visible, and its label is
  the cue text. Under `-uiTesting` (DEBUG) its accessibility value is the id of the track the drawn
  cues come from (the embedded MP4 track and the external SRT share their dialogue).
- **Translation:** `AX.Translation.progressLabel` contains a percentage or "n / total" (the
  progress bar's value "NN percent" also works). `cancel` stops the job, keeping every finished
  line in the checkpoint, and `resume` appears afterwards. `showArabic` (or the `tr:ar:` track row) activates the result.
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

Hosted unit tests that exercise another component detect a missing implementation at run time
(`SubtitleError.notImplemented`, the placeholder probe result, an empty track list) and call
`XCTSkip`. They were written that way so the suite could run before the components were
integrated; in the integrated app these skips should no longer trigger, and any that does is listed
with its reason in the CI summary. UI journeys are never skipped.

## Running a subset on CI

Simulator tests run automatically on `main`. On another branch, dispatch the workflow:

```sh
gh workflow run ios.yml --ref <branch> -f ui_tests=true \
  -f only_testing="SableTests SableUITests/TimingUITests"
```
