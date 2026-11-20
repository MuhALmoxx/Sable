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

### ChatGPT plan (OpenAI preview)

Protocol layer in `TranslationKit` (`ChatGPTPlan*.swift`, `ChatGPTAuth.swift`,
`ChatGPTProvider.swift`); the app's sign-in and usage UI is described separately. It follows
OpenAI's "ChatGPT plan usage" rules for open-source apps (preview).

- **What it is.** Eligible ChatGPT **Plus or Pro** users sign in with ChatGPT, and requests count
  against their ChatGPT plan's usage limits (for Plus, one five-hour total shared with every other
  app). It is not OpenAI API access and not API billing, so the descriptor sets
  `usesSubscriptionAllowance` (the UI discloses it and asks before a job) and `isPaid` is false.
- **Sign-in.** OAuth authorization code with PKCE (S256) in the system browser:
  `GET https://auth.openai.com/api/accounts/authorize` with `client_id=dynamic_agent_client` and
  `agent_name_hint=Sable` on the first registration, then the issued client id (from the callback's
  `client_id`) on every later sign-in, with `id_token_hint`/`login_hint` when known and
  `prompt=consent` after a decline. Every attempt has a fresh `state`, `nonce` and verifier. The
  per-installation `ext_agent_host_id` is `urn:uuid:<UUIDv4>` (`ChatGPTPlan.newHostID()`), and the
  redirect is `http://127.0.0.1:<port>/auth/callback`: never `localhost`, only the port may vary.
  `error=access_denied` stops the attempt. There is no client secret.
- **Tokens.** `POST /api/accounts/oauth/token` (form-encoded, `resource=https://api.openai.com/v1`).
  The ID token's claims are validated (issuer, audience contains the client id, expiry, nonce, and
  on refresh the same subject). Its signature is not checked: the token comes straight from the
  token endpoint over TLS (OIDC Core 3.1.3.7). Access tokens last about 1 h and are refreshed
  within 5 min of expiry (not before `earliest_refresh_at`). Every refresh returns a **replacement**
  refresh token. `ChatGPTTokenProvider` runs one refresh at a time (concurrent callers share it)
  and saves the new pair through the app's Keychain store before using it. Terminal refresh errors
  (`invalid_grant`, `refresh_token_expired`/`_reused`/`_invalidated`, …) delete the tokens and ask
  for a new sign-in. Network errors keep them.
- **Sign-out** deletes the local tokens, keeps the account/client-id mapping, and then revokes the
  refresh token at the discovery document's `revocation_endpoint`, retrying network and 5xx
  errors twice. A failed revocation is reported in `lastRevocationError`.
- **Models.** `GET /v1/models` with the bearer token, keeping entries with `visibility == "list"`
  (`slug` is the id, `display_name` the label). TranslationKit has no built-in default model: the
  app uses the model the user picked, else the first one the signed-in account lists.
- **Request.** `POST https://api.openai.com/v1/responses` with `stream: true`, `store: false`, the
  same translator brief and Arabic guide as Claude in `instructions` (no `system` role), one user
  `input_text` with the JSON payload, and `text.format` set to the same JSON schema (strict). If the
  server rejects that field (`subscription_sharing_unsupported_capability` with `param` "text…"),
  Sable retries once without it (JSON described in the instructions only) and keeps that setting
  for the rest of the provider's lifetime. The server never receives `temperature`, `top_p`,
  `max_output_tokens`, `metadata`, `user`, `previous_response_id` or the other forbidden fields.
  The event stream is buffered: `response.output_text.delta` texts are joined, and a chunk counts
  as done only after `response.completed`. 40 lines per request, with context, as for Claude.
- **Errors.** A 401 (or `subscription_sharing_invalid_user`) forces one refresh and one retry;
  after that the job stops with "Sign in with ChatGPT again in Settings › Translation." A 429 or
  `subscription_sharing_usage_limit_exceeded` stops the job with `planUsageLimitReached` (no
  retry and no guessed reset time; the app links to Manage usage). `…_user_not_eligible` gives
  `planNotEligible` (Plus or Pro is required). The engine retries `…_usage_unavailable`,
  `…_user_unavailable` and 503 with its usual backoff. `…_route_not_supported`, `chatpass_v2_*` and
  403 policy or region errors stop with an explanation. In every stopped case the checkpoint is
  kept, so **Resume** continues later. Tokens never appear in error messages or descriptions.
- **Not verified live.** No real sign-in or plan-backed request has been made yet (preview). The
  package tests (`ChatGPTAuthTests`, `ChatGPTProviderTests`) cover the protocol against a fake
  HTTP client, and the exact shape of `/v1/models` and `earliest_refresh_at` is parsed leniently.

#### ChatGPT plan in the app (sign-in and usage UI)

App side: `App/Translation/ChatGPT*.swift` (account service, loopback receiver, Keychain store,
views) plus the provider wiring in `TranslationService`.

- **Settings › Translation › ChatGPT plan** (tagged *OpenAI preview*). Signed out it explains:
  "Use your ChatGPT Plus or Pro plan instead of an API key. Translations count toward your ChatGPT
  usage limits (on Plus, the 5-hour limit is shared with other apps). This is not OpenAI API access;
  Sable never sees your password." It states that Sable is free and that an eligible Plus or Pro
  plan is required, and offers **Sign in with ChatGPT**. While the browser is open it shows
  progress and **Cancel**; errors (for example a declined consent) appear inline. Signed in it shows
  "Signed in as <email>", the **model** picker (`display_name` shown, `slug` stored in
  `settings.chatGPTModel`), "Using ChatGPT plan" with a **Manage usage** link
  (`https://chatgpt.com/settings/usage`) and **Sign out**.
- **Model.** Until one is picked, jobs use the first model the account lists; a saved choice that
  the account no longer lists falls back to the first listed model. Without any model the provider
  is unavailable ("No ChatGPT model is available to this account").
- **Translate sheet.** The provider row "ChatGPT plan" is tagged *Plus or Pro* and *Preview*.
  Signed out it is unavailable with "Sign in with ChatGPT in Settings › Translation". Selected, it
  shows the model picker and "Using ChatGPT plan · Manage usage". The first time it is used, a
  notice appears once: "You're using your ChatGPT plan" / "Eligible usage in this app uses your
  ChatGPT plan. Manage usage in your ChatGPT settings." / **Got it** (remembered in
  `settings.chatGPTPlanNoticeShown`).
- **Confirmation.** Like a paid job, every new plan-backed job (and every change of model) needs an
  explicit **Confirm and translate** that shows the lines and requests and says that the requests
  count toward the ChatGPT plan's usage limits, may use credits if the person allowed credits for
  apps in ChatGPT settings, and that Sable charges nothing. It never claims that the plan includes
  API usage.
- **Usage limit reached.** The job stops with its checkpoint; the banner's primary action is
  **Manage usage**, with **Resume** next to it. No reset time is shown. Other running plan-backed
  jobs are paused (checkpoints kept). **Not eligible** explains that Plus or Pro is required.
  **Sign-in ended** (terminal refresh error or confirmed revocation) clears the tokens, shows the
  signed-out block with "Your ChatGPT sign-in has ended…" and the job says to sign in again, then
  Resume.
- **Sign-in on the iPhone.** Sable starts a receiver on `127.0.0.1` (port 1455, or one the OS
  assigns when 1455 is busy; bound to the loopback interface only, no port sharing), builds the
  authorize request for `http://127.0.0.1:<port>/auth/callback` and opens it with
  `ASWebAuthenticationSession` (no callback URL scheme, not ephemeral, so the browser's ChatGPT
  login can be reused). The receiver answers only `GET /auth/callback` with this attempt's `state`
  (other paths 404, other methods 405, a foreign `state` 400), replies with a small black page
  ("Signed in. You can return to Sable.") and `Connection: close`, hands the query to the app once
  and stops; it also stops when the attempt is cancelled or after 10 minutes. Sable then closes the
  browser sheet, exchanges the code and saves the tokens. Closing the browser first returns to
  signed out without a message. OpenAI's docs describe this loopback flow for locally hosted apps
  and do not mention iOS specifically; Sable runs the documented receiver on the device itself.
  Loopback traffic is not subject to iOS local-network privacy, so no Info.plist key is added.
- **Storage.** Keychain items (service `com.murisixz.sable`, the same as the Claude key,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`): `chatgpt-plan-credential` (tokens and
  identity, deleted on sign-out), `chatgpt-plan-account` (issued client id, email, subject; kept on
  sign-out so the next sign-in reuses the client id) and `chatgpt-plan-host-id` (the
  `ext_agent_host_id`, created once before the first sign-in). Tokens are never written to
  UserDefaults, files or logs. The `-uiTesting` reset deletes every item of the service, these
  included.
- **Branding.** OpenAI asks for its approved branding and assets. Sable bundles none, so the button
  is the text label "Sign in with ChatGPT" in Sable's own pixel style; no ChatGPT or OpenAI logo is
  drawn or imitated.
- **Not verified end-to-end.** No ChatGPT account or device was available during development or in
  CI. The UI test only checks the signed-out block (the button is never tapped); hosted unit tests
  cover the Keychain store and the loopback receiver.

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
