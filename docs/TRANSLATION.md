# Subtitle translation

Sable translates a **whole subtitle track** from English to Arabic and saves the result as a new
track. Arabic is the first target that is fully implemented; each target language is described
by a `TargetLanguageProfile` (prompt guidance, maximum line length, right-to-left), so others can
be added later.

## What happens when you translate

1. In the player, open **Translate**. Pick the source track and the provider. Any text track
   (embedded or external) can be the source. Image-based tracks are disabled ("needs OCR, not
   supported"), Arabic tracks are disabled ("Already Arabic"), and existing translations are listed
   with an `AR ready` tag.
2. Sable prepares the job without sending anything: it checks the cache and any checkpoint and
   estimates lines, requests and tokens.
3. **Paid providers never start without confirmation.** For Claude, a confirmation shows the model
   and its price, the number of lines and requests, the estimated tokens and an approximate cost
   range. Nothing is sent until you confirm. This happens before every new job and after
   **Translate again** or a change of model. Resuming a job you already confirmed in the same app
   session does not ask again.
4. Progress is shown per chunk ("312 / 840 lines · request 8 of 21", plus tokens and approximate
   cost so far for Claude). You can **cancel** at any time and **resume** later.
5. The result is saved as a new track `tr:ar:<source track id>`, titled "Arabic (translated)". It
   has the same cue ids, order, start and end times and style hints as the source, which is never
   modified. The sheet shows a right-to-left preview with **Show Arabic** / **Show English**. The
   subtitle style can also show the English line in smaller type under the Arabic one.
6. **Export SRT** writes the Arabic track to `Documents/Exports/<video title>.ar.srt` (Files ›
   On My iPhone › Sable › Exports), optionally with the current offset baked in and with RTL marks
   (see SUBTITLES.md › Export).

A translation shares its source track's **timing group**: an offset tuned on the English track also
applies to the Arabic one, and the other way round (see SYNC.md).

## Providers

### Apple on-device (default, free, private)

- Uses Apple's Translation framework (iOS 18). Subtitle text never leaves the iPhone, and no
  account or key is needed.
- **Availability.** Sable asks iOS whether English→Arabic is installed, downloadable or unsupported.
  If it is unsupported, the provider is not offered. If the languages are not installed yet, iOS
  shows its download prompt when the job starts.
- **Line by line, no context.** Lines are sent in batches of 20, but each line is translated on its
  own, without the surrounding dialogue or a glossary. Tags are removed before translation (only
  whole-line `<i>`/`<b>` are restored afterwards), multi-line cues are joined, and speaker-dash
  lines are translated separately. Names and gender agreement can therefore vary between lines.
- **The Translate sheet must stay open.** The on-device session lives in the sheet. Closing the
  sheet pauses the job with its checkpoint; open it again and tap **Resume**. If the session does
  not start within 20 s, the job fails with "On-device translation did not start".
- **Not in the Simulator.** Apple's Translation framework generally does not translate in the iOS
  Simulator, so this provider only works on a real iPhone.

### Claude (Anthropic), with your own API key

- **Context-aware.** Each request carries surrounding lines and a glossary, so names, terms and the
  form of address (for example the gender of "you" in Arabic) stay consistent.
- **Billed to you.** Requests go directly from the iPhone to Anthropic's Messages API
  (`api.anthropic.com`) using **your** API key, and usage is charged to **your** Anthropic account.
  Sable has no server and adds no fee. The estimate is only an estimate; your Anthropic console
  shows the actual bill.
- **Key storage.** Paste the key in Settings › Translation (or from the Translate sheet). It is
  stored only in the iOS **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), so it
  is not synced to iCloud or moved to another device. It is never written to UserDefaults, files or
  logs, is shown afterwards only as its last 4 characters, and can be removed at any time. Saving
  (or **Test**) checks the key with `GET /v1/models`, which spends no tokens.
- **Models.** Claude Opus 5.5 (`claude-opus-5-5`) by default; Claude Sonnet 5.5 (about half the
  price) or Claude Haiku 5.5 (lowest cost, simpler phrasing) can be chosen in Settings or in the
  Translate sheet.
- **Request.** `POST /v1/messages` with `max_tokens` 16,000, effort `medium`, structured output
  (a JSON schema with `translations[{id, text}]` and `names[{source, target}]`), no sampling
  parameters, thinking budget or prefill, and a 180 s timeout. The system prompt (translator brief,
  input/output contract and the Arabic guidance) is identical for every chunk and marked for prompt
  caching.
- **Refusal fallbacks.** Requests enable Anthropic's server-side refusal fallbacks
  (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`): if the model declines a chunk,
  Anthropic may answer with another model. Such answers are counted and reported in the progress
  and the completion summary, so the model is never switched silently. If no model answers, the
  job stops with "The provider declined this request". Anthropic provides no server-side fallback
  for Claude Haiku 5.5, so there a refusal stops the job directly.
- Only subtitle **text** is sent: the chunk's lines, context lines and glossary entries. No video,
  audio or file names.

### Mock provider (tests only)

DEBUG builds launched with `-mockTranslation` (UI tests) get an offline, deterministic provider. It
is labelled "Mock (UI tests)", preselected and free, translates 3 lines per chunk with a delay
(`-mockTranslationDelay <s>`, default 0.4 s) and returns the human-written reference Arabic in
`Fixtures/UITestFixtures/reference-translations.ar.json`. `-mockTranslationPaid` marks it as paid
so the confirmation step can be tested. It does not exist in Release builds.

## How a job runs

### Chunking with context

- Claude gets **40 lines per request**, with **6 lines of context before** (with their
  translations, for names and gender continuity) and **6 after**. Context lines are read-only and
  never translated twice. Apple uses 20 lines and the mock 3, both without context.
- Lines without letters (empty, music notes, `...`) pass through without a request.
- Lines are cleaned first: `<u>` is removed, `<i>`/`<b>` and line breaks are kept, and bidi
  controls are normalised.
- A **glossary** of names and terms grows from every response (case- and diacritic-insensitive,
  the first rendering wins, at most 200 entries with the least-used dropped first). Each request
  carries only the entries whose source term appears in that chunk or its context.
- The Arabic guidance is part of the prompt: natural Modern Standard Arabic rather than literal
  translation, at most about 42 characters per line and 2 lines, gender and plural agreement from
  context, consistent transliteration of names, Arabic punctuation (، ؛ ؟) with Western digits,
  `<i>`/`<b>` kept and sound tags translated in brackets.
- **Post-processing** converts `?` `,` `;` to ؟ ، ؛ on Arabic lines (never inside tags, URLs or
  numbers), fixes spacing around punctuation, strips stray direction marks, restores whole-line
  `<i>`/`<b>` from the source, strips unbalanced tags, and caps each cue at 2 lines.

### Validation and repair

- The response must contain **exactly** the ids that were sent. Every line must be non-empty after
  post-processing, and an Arabic result must contain Arabic script when the source line has two or
  more Latin words. Unexpected ids are ignored and counted.
- **Repair:** missing ids are re-requested on their own, with context, up to 2 times; whatever is
  still missing is then split in half, recursively. A truncated or unparseable reply
  (`max_tokens`, HTTP 413, invalid JSON) is split at once. If a single line still fails, the job
  stops with "Translation did not line up with the original cues". Every finished line, including
  the rest of that chunk, stays in the checkpoint, and **Retry** continues from there.
- **Retries:** when rate-limited, Sable waits for Anthropic's `retry-after` or backs off 2, 4 and
  8 s, up to 4 attempts. A `retry-after` longer than 120 s stops the job with its checkpoint saved.
  Server errors (5xx, 529), 408, 409 and network errors are retried with the same backoff. An
  invalid key, exhausted credit, a refusal and other 4xx errors stop the job immediately.
- The final document always has the same cue ids, order and timestamps as the source, and its
  language is `ar`.

### Checkpoints and resume

- A **checkpoint** is written atomically after **every** chunk to
  `Application Support/Sable/Translations/checkpoints/<key>.json`. The key is a SHA-256 of the
  source content (cue ids, millisecond times and texts), the target, the provider and the model.
- **Cancel**, a failure, a crash or iOS ending the app keeps every finished line, including lines
  from a cancelled or failed chunk. **Resume (x of y lines done)** sends only what is missing, so
  finished lines are never sent or billed twice. **Discard** starts over.
- Claude jobs keep running when the sheet is closed, but only while Sable is in the foreground and
  for the roughly 30 s of background time iOS grants. After that the job pauses with its
  checkpoint. There is no background-processing task.

### Cache

- A finished translation is stored under the same key in `Translations/completed/`. Translating the
  same track with the same provider and model again offers **Already translated — use cached
  result**, which is instant and free, or **Translate again**.
- Changing the provider or the model, or editing the source text or times, produces a new key and
  a new job. Chunk size and the video title are not part of the key.
- Removing a video from the library does not delete these checkpoints and cached results; Settings
  shows the size of the `Translations` folder.

## Costs

The estimate counts about one token per 3.5 characters, plus a per-request prompt overhead of about
1,900 tokens, the repeated context lines and the glossary; output is estimated from the source
length. Opus 5.5 always uses adaptive thinking, which is billed as output and cannot be predicted,
so the high end of the range assumes 2.5× the estimated output.

Example: an 840-line track (about 30 characters per line) with Opus 5.5 is estimated at roughly
60k input and 18k output tokens over 21 requests, **about $0.50–$1.20**. Sonnet 5.5 is about half
that, and Haiku 5.5 costs a few cents. The prices built into the app (`ClaudeModels.options`) are
used only for this estimate; Anthropic bills your account at its current prices. While a job runs,
the sheet shows live token usage (input includes cache reads and writes) and approximate spend.

## Errors you may see

| Error | Meaning / what to do |
|---|---|
| Add your API key in Settings › Translation first | Claude selected without a key |
| The API key was rejected | Invalid or revoked key: replace it |
| Rate limited | Sable already waited and retried; resume later |
| Your API account has no remaining credit or quota | Top up your Anthropic account (or raise its spend limit), then resume |
| Network problem | Check the connection, then resume (finished lines are kept) |
| Translation did not line up with the original cues | A line still failed after repair and splitting; Retry continues from the checkpoint |
| The provider declined this request | The model (and any fallback) refused the content |
| On-device translation did not start / stopped because the Translate sheet was closed | Keep the sheet open, then Resume |
| This track has no text to translate | Empty source, or nothing but non-letter lines |

## Privacy summary

- **Apple on-device:** no subtitle text leaves the iPhone.
- **Claude:** only the chosen track's subtitle text (the lines being translated, their context lines
  and the relevant glossary entries) is sent to `api.anthropic.com`, with your own key, and only
  after you confirm. It is handled under Anthropic's terms for API customers. Nothing goes to the
  Sable developers.
- Neither the API key nor subtitle contents are logged.

## Not yet verified

No live Claude API call was made during development (no key was available): the request and
response handling is covered by package tests against a fake HTTP client. Apple on-device
translation, the API-key flow and the background-time behaviour have not been exercised on a
device; the UI tests use the mock provider.
