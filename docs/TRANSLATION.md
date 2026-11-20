# Subtitle translation

Sable translates a **whole subtitle track** from English to Arabic and saves the result as a new
track. Arabic is the first target that is fully implemented; each target language is described
by a `TargetLanguageProfile` (prompt guidance, maximum line length, right-to-left), so others can
be added later.

> **TODO(owner)** markers are details the translation engineer's report has to confirm. The rest
> follows from the contracts in `Packages/SableKit/Sources/TranslationKit/Contracts.swift`.

## What happens when you translate

1. In the player, open **Translate**. Pick the source track (any *text* track: embedded, external
   or a previous result) and the provider.
2. Sable plans the job and shows an estimate: number of lines, characters, requests and estimated
   input/output tokens.
3. **Paid providers never start without confirmation.** For Claude, a confirmation sheet shows the
   line count, the estimated tokens and an approximate cost from the model's list price. Nothing
   is sent until you confirm. This happens before **every** job.
4. Progress is shown per chunk. You can **cancel** at any time and **resume** later.
5. The result is saved as a new track `tr:ar:<source track id>`. It has the same cue ids and the
   same original timestamps as the source, which is never modified. Choose **Show Arabic** to
   switch to it. The subtitle style can also show the English line in smaller type under the
   Arabic one.
6. **Export** writes the translated track as an SRT file (see SUBTITLES.md › Export).

A translation shares its source track's **timing group**: an offset tuned on the English track also
applies to the Arabic one, and the other way round (see SYNC.md).

## Providers

### Apple on-device (default, free, private)

- Uses Apple's on-device Translation framework (iOS 18). Subtitle text never leaves the phone, and
  no account or key is needed. The first use may show the system's download prompt for the
  English→Arabic language assets.
- Translates **line by line** without context or glossary. It is fast and free, but names and terms
  can come out inconsistently, and some lines lose their tone.
- **TODO(translation):** batching per request, behaviour when the language assets are missing or
  the device does not support the pair.

### Claude (Anthropic), with your own API key

- Context-aware translation. Each request carries surrounding lines and a glossary, so names,
  terms and the form of address (for example the gender of "you" in Arabic) stay consistent.
- **Billed to you.** Requests go directly from the iPhone to Anthropic's Messages API
  (`api.anthropic.com`) using **your** API key, and usage is charged to **your** Anthropic account
  at Anthropic's prices. Sable has no server and adds no fee. The pre-job estimate is only an
  estimate. Your Anthropic console shows the actual bill.
- **Key storage.** Paste the key in Settings › Translation. It is stored only in the iOS
  **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), so it is not synced to iCloud
  or moved to another device. It is never written to UserDefaults, files or logs, and you can
  remove it at any time. When saved, the key is checked with `GET /v1/models`, which spends no
  tokens.
- **Model:** Claude Opus 5.5 (`claude-opus-5-5`) by default. The model can be changed in Settings.
- Only the subtitle **text** is sent, never video, audio or file names.

### Mock provider (tests only)

DEBUG builds launched with `-mockTranslation` (UI tests) get an offline, deterministic provider. It
is clearly labelled as a mock and returns the human-written reference Arabic in
`Fixtures/UITestFixtures/reference-translations.ar.json`. It does not exist in Release builds.

## How a job runs

### Chunking with context

- The cues are split into chunks of `chunkSize` units. The default comes from the provider's
  `recommendedChunkSize`: 40 lines for Claude.
- Each unit is the cue's id plus its cleaned text. ASS overrides are removed, `<i>` is kept, and
  `\n` line breaks are kept.
- Context providers (Claude) also receive up to `contextSize` (6) **preceding** lines with their
  translations and the following lines. Context lines are read-only and never translated twice.
- A **glossary** of names and terms fixed by earlier chunks is passed forward, and each response
  can add entries to it.
- The Arabic profile's guidance (register, punctuation, names, maximum about 42 characters per
  line) is part of the prompt. Line breaks are kept readable.

### Validation and repair

- Every unit id sent must come back **exactly once**. Missing ids, unexpected ids or empty lines
  are a mapping mismatch (`TranslationError.mappingMismatch`).
- **TODO(translation):** describe the repair strategy (for example re-requesting only the missing
  ids in smaller chunks, how many attempts are made, and what is shown if a line still fails), and
  the retry/backoff policy for `rateLimited` / server errors.
- The final document always has the same cue ids, order and timestamps as the source, and its
  language is `ar`.

### Checkpoints and resume

- A **checkpoint** is written after **every** completed chunk, in the library's `Translations/`
  folder, keyed by the source content, target, provider and model.
- **Cancel**, a crash, or iOS ending the app keeps every completed chunk. **Resume** continues with
  the next chunk, and progress continues from where it stopped, not from 0. Completed chunks are
  never sent again, so they are never billed twice.
- Starting over (discarding the checkpoint) is a separate, explicit choice.

### Cache

- A finished translation is cached under the same key. Translating the same track with the same
  provider and model again is instant and free.
- Changing the provider or the model, or editing the source file, produces a new job.

## Errors you may see

| Error | Meaning / what to do |
|---|---|
| Add your API key first | Claude selected without a key: add it in Settings › Translation |
| The API key was rejected | Invalid or revoked key: replace it |
| Rate limited | Wait (the message shows how long if Anthropic says), then resume |
| No remaining credit or quota | Top up your Anthropic account, then resume |
| Network problem | Check the connection, then resume (completed chunks are kept) |
| Did not line up with the original cues | The provider returned a different set of lines than requested (see repair above) |
| Provider declined | The provider refused the content, so that chunk cannot be translated with it |
| This track has no text to translate | Empty or image-based source |

## Privacy summary

- Apple on-device: no subtitle text leaves the device.
- Claude: the subtitle text of the chosen track goes to Anthropic under your account and is handled
  under Anthropic's terms for API customers. Nothing goes to the Sable developers.
- Neither the API key nor subtitle contents are logged.
