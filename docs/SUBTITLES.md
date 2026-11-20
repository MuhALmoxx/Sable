# Subtitles in Sable

This document covers where subtitle tracks come from, how they are parsed, rendered and exported,
and what formatting is not reproduced. Timing and sync are in [SYNC.md](SYNC.md) and translation
is in [TRANSLATION.md](TRANSLATION.md).

> Markers like **TODO(owner)** are details the owning engineer's implementation report has to
> confirm. Everything else follows from the shared contracts (`docs/CONTRACTS.md`,
> `Packages/SableKit/Sources/SubtitleKit`).

## Track sources

| Source | Track id | Where the text comes from |
|---|---|---|
| Matroska / WebM embedded text track | `emb:mkv:<TrackNumber>` | SubtitleKit's own EBML reader (`MatroskaReader`), on demand |
| MP4 / MOV embedded timed text (`tx3g` / `mov_text`) | `emb:mp4:<trackID>` | AVFoundation sample reader + `TX3GDecoder` |
| External file imported by you (SRT, WebVTT, ASS, SSA) | `ext:<uuid>` | Copied into the library's `Subtitles/` folder and parsed |
| Translation produced by Sable | `tr:<lang>:<source id>` | JSON document in `Subtitles/`, same cue ids and timestamps as the source |

A video's track list shows its embedded tracks first, then external files, then translations.
Each row shows the language, the format and tags such as `DEFAULT`, `FORCED` or `IMAGE-BASED`.

Embedded Matroska text is read **once**, when you first select the track. Sable scans the file's
clusters with seeks (it never loads the whole file), shows progress, and caches the result as JSON
under `Extracted/<itemID>/`. Later selections come from the cache.

### Embedded codecs

| Matroska CodecID | Kind | Handling |
|---|---|---|
| `S_TEXT/UTF8` (SRT) | text | parsed, drawn by Sable |
| `S_TEXT/ASS`, `S_TEXT/SSA` | text | `CodecPrivate` used as the script header, block payloads parsed |
| `S_TEXT/WEBVTT`, `D_WEBVTT/SUBTITLES` | text | parsed |
| `S_HDMV/PGS`, `S_VOBSUB`, `S_DVBSUB` | **image** | listed as image-based; rendered natively by the VLC engine only |

Header-stripping and zlib `ContentEncoding` are supported, and so are both `SimpleBlock` and
`BlockGroup` (with `BlockDuration`).

## Parsing

- **Encodings**, tried in order: UTF-8 (with or without BOM), UTF-16 LE/BE with BOM, then
  Windows-1256 (Arabic), Windows-1252 and ISO-8859-1.
- **Format detection** uses the file extension first and content sniffing second (`WEBVTT`
  header, `[Script Info]`, SRT `-->` arrows).
- **Normalisation.** Cues are sorted by (start, original order) and re-indexed `0..<n`. A cue's
  **id** is its SRT counter when it has one, otherwise `c<index>`. Ids survive translation, so
  the English and Arabic lines stay paired.
- **Timestamps are immutable.** Offsets and sync never rewrite a cue. They are applied at display
  and export time (see SYNC.md).
- **Text model.** Plain Unicode with `\n` line breaks, plus the inline tags `<i> <b> <u>`. Other
  markup (ASS override blocks, WebVTT voice/class spans, `<font>`) is removed from the display
  text and kept in `rawText`. Each cue may carry a `CueStyleHint`: numpad alignment (ASS `\anN`
  semantics), ASS style name, italic and bold.
- Files with no usable cue are rejected with a clear message instead of creating an empty track.

## Rendering

Sable draws every **text** subtitle itself, in a SwiftUI overlay above the video. Offsets,
translations, Arabic shaping and styling therefore behave the same with both playback engines.
VLC's own subtitle renderer stays off for text tracks.

- Overlapping cues, such as two speakers at once, are shown together, in start order.
- **Style** (Settings, or per video from the player): size (0.6–2×), distance from the bottom
  edge, outline / shadow / box background, and font (IBM Plex Sans, system, or pixel font for
  Latin text). It can also show the original line in smaller type under a translation.
- **Arabic and other right-to-left text** is always set in IBM Plex Sans Arabic, never in the pixel
  font. Every line is prefixed with U+200F (RIGHT-TO-LEFT MARK) and laid out right-to-left, so
  punctuation and mixed Latin/Arabic runs order correctly.
- **TODO(playback):** list which `CueStyleHint` fields the overlay honours (for example top
  placement for `\an8`, italic, bold) and how cues are positioned in landscape and with Fill
  aspect.

## Formatting that is not reproduced

Sable aims for readable, correctly timed dialogue, not typesetting. Known limitations:

- **ASS/SSA:** the following override tags are stripped and not rendered: positioning (`\pos`,
  `\move`, `\org`), rotation/scaling (`\frz`, `\fscx`, …), colours and alpha (`\c`, `\1c`,
  `\alpha`), font changes (`\fn`, `\fs`), borders/shadows (`\bord`, `\shad`), fades (`\fad`),
  karaoke (`\k`) and vector drawing (`\p`). Of the `[V4+ Styles]`, only alignment, italic and bold
  can affect display. Fonts, colours, outlines and margins defined in the script are ignored, and
  Sable's own subtitle style applies instead. `\N` becomes a line break. Signs and typesetting
  lines appear as ordinary text.
- **WebVTT:** cue settings (`line`, `position`, `size`, `align`), regions and `::cue` CSS are not
  applied. Voice spans (`<v Name>`) are removed, so the speaker name is not shown.
- **SRT:** `<font color/face/size>` is removed. **TODO(subtitles-core):** confirm how `{\anN}` tags
  inside SRT files are treated.
- **MP4 timed text:** style records (`styl`, `hlit`, `krok`, colours) are ignored, and only the
  text is used. MP4 text samples cannot overlap: when the source had overlapping lines, the muxer
  shortens the earlier one (the fixture's "Is it safe?" ends at 17.6 s in the MP4 instead of
  18.2 s).
- **Image-based subtitles** (PGS, VobSub, DVB): see below.

## Image-based subtitles (PGS / VobSub / DVB)

These tracks are pictures of text, not text. Sable cannot read them without OCR, which is
**not implemented**. As a result they:

- are listed and labelled **image-based**;
- are rendered **natively by the VLC engine**, with your subtitle offset applied as VLC's subtitle
  delay. With the AVFoundation engine they are not shown;
- are **never offered for translation or guided sync**, and their style cannot be changed.

To translate or fine-tune such a film, import a text version of the subtitles (SRT/ASS/VTT) as an
external file.

## Export

The translation sheet exports any text track to **SRT**:

- counters are renumbered 1…n in dialogue order, with timestamps `HH:MM:SS,mmm --> HH:MM:SS,mmm`;
- you can bake in the current timing (`effective = original × scale + offset`) or keep the
  original times. Cues pushed before 0 are clamped, and a cue that would end before 0 is dropped;
- right-to-left lines can be wrapped in U+202B…U+202C (RLE/PDF), so players that ignore paragraph
  direction still place punctuation correctly;
- `\r\n` line endings by default; inline `<i>/<b>/<u>` tags can be kept or stripped.

**TODO(translation):** document where the exported file is written (folder visible in the Files
app via `UIFileSharingEnabled`) and which export options the sheet exposes.
