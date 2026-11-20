# Subtitles in Sable

This document covers where subtitle tracks come from, how they are parsed, rendered and exported,
and what formatting is not reproduced. Timing and sync are in [SYNC.md](SYNC.md) and translation
is in [TRANSLATION.md](TRANSLATION.md).

## Track sources

| Source | Track id | Where the text comes from |
|---|---|---|
| Matroska / WebM embedded text track | `emb:mkv:<TrackNumber>` | SubtitleKit's own EBML reader (`MatroskaReader`), on demand |
| MP4 / MOV embedded timed text (`tx3g` / `mov_text`, WebVTT `wvtt`) | `emb:mp4:<trackID>` | `AVAssetReader` + `TX3GDecoder` (or the `vttc`/`payl` box decoder for `wvtt`) |
| External file you add (SRT, WebVTT, ASS, SSA) | `ext:<uuid>` | Copied into the library's `Subtitles/` folder and parsed |
| Translation produced by Sable | `tr:<lang>:<source id>` | JSON document in `Subtitles/`, same cue ids and timestamps as the source |

External files can be added in three ways: **Import subtitle file…** in the player's track list, **Add
subtitle file** on a library row, or by opening a subtitle file in Sable from another app (it is
attached to the playing video, the only video, or a video you choose). The language is guessed from
the file name (`movie.ar.srt`, `movie.eng.srt`, `movie.en-US.srt`, `Movie_English.srt`). Empty,
oversized and non-subtitle files are rejected.

The track list shows **Off**, then *Embedded*, *External files* and *Translations*. Each row shows
the title, language, format and the tags `DEFAULT`, `FORCED`, `TRANSLATED` or `IMAGE` (with a line
explaining what an image-based track can and cannot do). Embedded tracks Sable cannot use at all,
such as CEA-608/708 captions in MP4, are listed separately as unsupported. A translation is titled
"Arabic (translated)", with "· from <source>" added when several translations share a language.

**Default choice.** If you never picked a track for a video, Sable selects the embedded text track
flagged *default* (preferring a non-forced one), otherwise the first non-forced English embedded
text track, otherwise none. External files are never selected automatically. Choosing **Off** is
remembered as an explicit choice (`PlaybackMemory.subtitleTrackID` is `nil` for "never chosen" and
`"off"` for "turned off").

**Embedded Matroska extraction.** The first time you select a text track of an MKV/WebM file, Sable
extracts **all** of that file's text tracks in one pass and caches each as JSON under
`Extracted/<itemID>/` (for example `emb_mkv_3.json`). Later selections, also after a relaunch, come
from the cache. The pass reads the clusters with seeks (at most about 4 KB per skipped block) and
never loads the whole file, but it is a linear scan without the `Cues` index, so a multi-GB file
takes seconds. Progress is shown as "Extracting subtitles NN %".

### Embedded codecs

| Matroska CodecID | Kind | Handling |
|---|---|---|
| `S_TEXT/UTF8`, `S_TEXT/ASCII` (SRT) | text | parsed with the SRT markup rules |
| `S_TEXT/ASS`, `S_TEXT/SSA`, `S_ASS`, `S_SSA` | text | `CodecPrivate` supplies the script header and styles; blocks are sorted by `ReadOrder` |
| `S_TEXT/WEBVTT`, `D_WEBVTT/SUBTITLES` / `CAPTIONS` / `DESCRIPTIONS` | text | parsed (cue settings for `S_TEXT/WEBVTT` are read heuristically from `BlockAdditional`) |
| `S_TEXT/USF` | text | reduced to plain text |
| `S_HDMV/PGS`, `S_VOBSUB`, `S_DVBSUB`, `S_IMAGE/BMP` | **image** | listed as image-based; rendered natively by the VLC engine only |
| `S_HDMV/TEXTST`, `S_KATE`, ARIB | unsupported | listed, not decoded |

Supported: `SimpleBlock` and `BlockGroup` (with `BlockDuration` in any order), Xiph/EBML/fixed
lacing, any `TimestampScale`, unknown-size clusters, and zlib and header-stripping
`ContentEncoding`. A block without a duration ends at the next start, capped at +5 s (+2 s for the
last cue). Truncated files keep what was read, and corrupt data is skipped up to the next cluster.
Tracks compressed with bzlib or lzo, or encrypted, yield an empty track.

In MP4, `tx3g` samples are decoded as UTF-8 or UTF-16 with BOM, and their style boxes are ignored.
WebVTT-in-MP4 (`wvtt`) decoding has not been tested on real files. Image-based tracks inside MP4
are not listed.

## Parsing

- **Encodings**, tried in order: UTF-8 with BOM; UTF-16 LE/BE and UTF-32 with BOM; UTF-16 without
  BOM (recognised by its NUL-byte pattern); valid UTF-8; Windows-1256 (Arabic); Windows-1252;
  ISO-8859-1. Windows-1256 is chosen only when most high bytes are Arabic letters, so accented
  French, German or Spanish text stays Windows-1252. Files in other code pages (Windows-1251,
  Windows-1255, GBK, Shift-JIS) decode as Windows-1252 and show garbled text. Binary data is
  rejected as unreadable.
- **Format detection.** A content signature (a `WEBVTT` header or an ASS `[Script Info]` section)
  wins over a wrong extension. Unknown extensions (`.txt`, none) are sniffed, including SRT timing
  lines. If the declared format yields no cues, the sniffed format is tried.
- **SRT** is parsed leniently: missing, duplicate or zero-padded counters, missing blank lines,
  CRLF or lone CR, stray BOMs from concatenated files, `,` or `.` before the milliseconds, missing
  milliseconds and coordinates after the arrow are all accepted. An end time before the start is
  clamped to the start.
- **WebVTT:** `NOTE`, `STYLE` and `REGION` blocks are skipped, cue identifiers are optional and a
  `Language:` header sets the document language.
- **ASS/SSA:** only `Dialogue` lines are used (`Comment` lines are skipped), mapped through the
  `[Events]` `Format` line.
- **Normalisation.** Cues are sorted by (start, original order) and re-indexed `0..<n`. Cue ids are
  unique per document and survive translation, so English and Arabic lines stay paired:
  - SRT: the counter when present and unique, else `c<n>`;
  - WebVTT: the cue identifier when present and unique, else `c<n>`;
  - ASS/SSA: `a<n>` in Dialogue order; embedded ASS uses `a<ReadOrder+1>`, which matches the
    original file's numbering;
  - embedded SRT/WebVTT without identifiers and MP4 text: `c<n>` in time order.
- **Timestamps are immutable.** Offsets and sync never rewrite a cue. They are applied at display
  and export time (see SYNC.md).
- **Text model.** Plain Unicode with `\n` line breaks, plus the inline tags `<i> <b> <u>`, balanced
  per line. The original markup is kept in `rawText`. A cue may carry a `CueStyleHint`: numpad
  alignment (1–9, `nil` = bottom centre), and for ASS the style name and the style's italic/bold.
  The tags are authoritative: an italic ASS style already produces `<i>` in the text.
- A file with no usable cue is rejected with a clear message instead of creating an empty track.
  MicroDVD, SubViewer, SBV, TTML/DFXP and SAMI are not supported.

## Rendering

Sable draws every **text** subtitle itself, in a SwiftUI overlay above the video, on both playback
engines. Offsets, translations, Arabic shaping and styling therefore behave the same with both.
VLC's own subtitle renderer stays off for text tracks.

- **Placement.** The overlay is laid out inside the part of the picture that is on screen, so it
  follows the aspect mode: letterbox bars are not used, and with Fill only the visible part of the
  cropped picture counts. Lines sit 6 % of the picture height above its bottom edge and move up
  when the player controls are visible. The same rules apply in portrait and landscape.
- **Alignment hints honoured.** Numpad rows 7–9 (`\an8` and friends, or WebVTT `line` near the top)
  go to the top, 4–6 to the middle, everything else to the bottom. For Latin text, columns 1/4/7
  align left and 3/6/9 right. Right-to-left lines are always centred.
- **Inline styling.** `<i>`, `<b>` and `<u>` are rendered from the tags; the hint's italic/bold
  flags are not applied on top. Italics use the system font, because IBM Plex Sans Arabic and the
  pixel fonts have no italic. Arabic is never italicised.
- **Size.** About 5.8 % of the displayed picture height (14–46 pt), times your size setting
  (60–200 %), times a Dynamic Type factor capped at 1.3.
- **Style** (Settings, or per video from the track list): size, background (outline, shadow, or a
  solid 80 % black box) and font (Plex, System, or Pixel for Latin text). It can also show the
  original line in smaller, dimmer type under a translation. The distance from the bottom edge is
  fixed.
- Overlapping cues, such as two speakers at once, are shown together, grouped by position.
- **Arabic and other right-to-left text** is always set in IBM Plex Sans Arabic, never in the pixel
  font. Every line is prefixed with U+200F (RIGHT-TO-LEFT MARK) and laid out right to left, so
  punctuation and mixed Latin/Arabic runs order correctly.

## Formatting that is not reproduced

Sable aims for readable, correctly timed dialogue, not typesetting. What is kept: line breaks,
`<i>`/`<b>`/`<u>` (nested b > i > u) and a numpad alignment hint. Everything else is dropped:

- **ASS/SSA:** colours and alpha, fonts and sizes, positioning (`\pos`, `\move`, `\org`, `\clip`),
  fades (`\fad`), transforms (`\t`), karaoke (`\k`), borders, shadows, blur, strike-out, rotation
  and scaling, margins, layers and `WrapStyle` (a soft break always becomes a line break). Override
  tags `\i`, `\b` (including weights such as `\b700`) and `\u` become inline tags, `\r` resets to a
  style, and `\an`/SSA `\a` set the alignment (the first one wins). `\N` and `\n` become line
  breaks and `\h` a space. Vector drawings (`\p1`) are removed, so lines that contain only a
  drawing disappear. Of the styles, only bold, italic, underline and alignment are used. Signs and
  typesetting lines appear as ordinary text in Sable's own style.
- **WebVTT:** regions, `vertical`, `size`, `::cue` CSS, voice names (`<v Name>`), classes and ruby
  annotations (`<rt>`) are dropped; the text of voice and class spans is kept. `line`, `position`
  and `align` are reduced to a best-effort alignment hint.
- **SRT:** `<font>`, `<span>`, `<s>` and similar wrappers are removed and their text kept; `<em>`
  and `<strong>` become `<i>` and `<b>`; `<br>` becomes a line break. ASS override blocks inside
  SRT are understood: `{\an8}`-style alignment sets the alignment hint, `{\i1}`/`{\b1}`/`{\u1}`
  become tags, and all other overrides are removed. HTML entities are decoded, and a literal `<3`
  or `a < b` is kept.
- **MP4 timed text:** style records (`styl`, `hlit`, `krok`, colours) are ignored, and only the
  text is used. MP4 text samples cannot overlap: when the source had overlapping lines, the muxer
  shortens the earlier one (the fixture's "Is it safe?" ends at 17.6 s in the MP4 instead of
  18.2 s).
- **Image-based subtitles** (PGS, VobSub, DVB): see below.

## Image-based subtitles (PGS / VobSub / DVB)

These tracks are pictures of text, not text. Sable cannot read them without OCR, which is
**not implemented**. As a result they:

- are listed with the `IMAGE` tag and an explanation;
- are rendered **natively by the VLC engine**; Sable's overlay is not used for them. Matroska
  files always play with VLC. Mapping Sable's track to VLC's track assumes VLC lists them in
  Matroska track-number order, which has not been verified on a device;
- are **never offered for translation or guided sync**, and the timing panel shows an explanation
  instead of its controls, so they cannot be re-timed. Their style cannot be changed either.

To translate or fine-tune such a film, import a text version of the subtitles (SRT/ASS/VTT) as an
external file.

## Export

The translation sheet exports the **Arabic translation** to SRT (other tracks have no export):

- the file is written to `Documents/Exports/<video title>.ar.srt`, which the Files app shows as
  *On My iPhone › Sable › Exports*. The sheet shows the saved path and offers **Share or save to
  Files**;
- UTF-8 with BOM and `\r\n` line endings, counters renumbered 1…n in dialogue order, timestamps
  `HH:MM:SS,mmm --> HH:MM:SS,mmm`, inline `<i>/<b>/<u>` tags kept;
- **Apply current offset** (off by default) bakes in the current timing of the source track's
  timing group (`effective = original × scale + offset`). Negative times are clamped to 0, and a
  cue that ends at or before 0 is dropped;
- **RTL compatibility marks** (on by default) wrap each right-to-left line in U+202B…U+202C
  (RLE/PDF), so players that ignore paragraph direction still place punctuation correctly. Lines
  that are already wrapped are left alone.
