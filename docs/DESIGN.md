# Sable design system

Black pixel-art chrome around a video player. Source of truth: `App/DesignSystem/*.swift`.
Tools: `design/tokens/contrast.py`, `design/icons/contact_sheet.py`, `design/icon/make_icon.py`
(Python 3; the last two need Pillow).

## Principles

1. **Black first.** True black (`Palette.background`) behind everything; content and video carry
   the colour. Surfaces step up in three warm-neutral levels; no gradients, glass or card stacks.
2. **One accent.** Phosphor amber marks the single primary action, the active choice, progress
   and focus — never decoration. If two things on screen are amber, one of them is wrong.
3. **Pixels on pixels.** Every border, glyph cell and art pixel lands on whole device pixels.
   Pixel type is for chrome; reading text and all Arabic use IBM Plex Sans Arabic.
4. **Generous and calm.** 4-pt spacing grid, 16-pt screen margins, 44-pt minimum targets, 1-pt
   lines. Fewer, larger things.
5. **Accessible by construction.** Text meets WCAG AA on every surface, controls that rely on a
   boundary meet 3:1, every control has a label, fonts scale with Dynamic Type, motion respects
   Reduce Motion.

## Tokens

### Colour (`Palette`)

| Token | Hex | Use |
|---|---|---|
| `background` | `#000000` | App and player background (OLED black) |
| `surface` | `#0D0C0B` | Inset areas, text-field fill |
| `surfaceRaised` | `#161513` | Panels, secondary buttons, pressed rows |
| `surfaceHigh` | `#201E1B` | Highest layer: toasts, pressed secondary buttons, switch track (off) |
| `border` | `#2E2C29` | Decorative 1-pt separators and panel outlines |
| `borderStrong` | `#6E6A62` | Boundaries that identify a control (field, switch, slider, segmented) — >= 3:1 |
| `textPrimary` | `#F2F1EC` | Titles, body, icons |
| `textSecondary` | `#A3A29C` | Subtitles, values, inactive segments |
| `textTertiary` | `#8E8B84` | Section labels, hints, disabled controls (still AA) |
| `accent` | `#FFB43C` | Primary action, active state, progress, focus |
| `accentDim` | accent @ 16 % | Selected segment fill |
| `accentPressed` | `#D9952B` | Pressed primary fill |
| `onAccent` | `#120C00` | Text/icons on accent fills |
| `danger` / `dangerDim` | `#FF5D52` / @ 16 % | Destructive actions, errors |
| `success` | `#7BD88F` | Completed states |
| `focus` | `#FFB43C` | Keyboard / Switch Control focus ring |
| `scrim` / `scrimStrong` | black @ 55 % / 80 % | Player chrome / text panels over video |

### Contrast (WCAG 2.x, computed by `python3 design/tokens/contrast.py --write`)

Text needs 4.5:1 (AA, normal size); control boundaries 3:1 (1.4.11). Alpha tokens are composited
over the surface they sit on. The script fails if any requirement is missed.

<!-- contrast:start -->
| Token | Hex | background | surface | surfaceRaised | surfaceHigh | Needs |
|---|---|---:|---:|---:|---:|---|
| `textPrimary` | #F2F1EC | 18.57 | 17.28 | 16.14 | 14.70 | >= 4.5 (AA text) |
| `textSecondary` | #A3A29C | 8.21 | 7.64 | 7.13 | 6.50 | >= 4.5 (AA text) |
| `textTertiary` | #8E8B84 | 6.18 | 5.75 | 5.37 | 4.89 | >= 4.5 (AA text) |
| `accent` | #FFB43C | 11.85 | 11.02 | 10.29 | 9.38 | >= 4.5 (AA text) |
| `danger` | #FF5D52 | 6.94 | 6.46 | 6.03 | 5.49 | >= 4.5 (AA text) |
| `success` | #7BD88F | 12.06 | 11.22 | 10.48 | 9.55 | >= 4.5 (AA text) |
| `borderStrong` | #6E6A62 | 3.90 | 3.63 | 3.39 | 3.09 | >= 3.0 (non-text) |
| `border` | #2E2C29 | 1.51 | 1.40 | 1.31 | 1.19 | decorative |

| Pair | Ratio | AA |
|---|---:|---|
| `onAccent` on `accent` (primary button) | 10.99 | pass |
| `onAccent` on `accentPressed` | 7.68 | pass |
| `accent` on `accentDim` over background (#291D0A, selected segment) | 9.30 | pass |
| `accent` on `accentDim` over surfaceRaised (#3B2E1A) | 7.44 | pass |
| `danger` on `dangerDim` over surfaceRaised (#3B211D, pressed destructive) | 4.88 | pass |
| `textPrimary` on `accentDim` over background | 14.57 | pass |
| `accent` focus ring / switch track vs `surfaceHigh` (non-text) | 9.38 | pass |
<!-- contrast:end -->

### Spacing (`Spacing`)

`px 2` (art pixel / stepped corner) · `xxs 4` · `xs 8` · `sm 12` · `md 16` (screen margin) ·
`lg 24` · `xl 32` · `xxl 48` · `touch 44` (minimum target) · `line 1` (border/divider) ·
`iconSmall 16` · `icon 20` · `iconLarge 24` · `rowTall 56` (two-line row).

### Typography (`Typo`)

| Role | Face | Size (pt) | Scales with | Use |
|---|---|---|---|---|
| `display` | Pixelify Sans Bold | 32 | largeTitle | Screen titles ("Sable") |
| `title` | Pixelify Sans SemiBold | 22 | title2 | Sheet titles |
| `headline` | Pixelify Sans SemiBold | 17 | headline | Row titles with emphasis, empty-state titles |
| `body` / `bodyMedium` | Pixelify Sans Regular / Medium | 16 | body | Chrome text, button labels (`bodyMedium`) |
| `callout` | Pixelify Sans Regular | 14 | callout | Secondary chrome, compact buttons, segments |
| `micro` / `microBold` | Silkscreen | 32/3 ≈ 10.67 | caption2 | UPPERCASE section labels and tags only |
| `mono` / `monoLarge` / `monoSmall` | SF Mono (system monospaced) | 13 / 28 / 12 | footnote / title / caption | Timecodes, offsets, numeric readouts |
| `reading` / `readingMedium` | IBM Plex Sans Arabic | 15 | body | Explanations, typed text (Latin + Arabic) |
| `arabic` / `arabicSmall` | IBM Plex Sans Arabic Medium / Regular | 17 / 14 | body / callout | Arabic content |

Font findings (checked with fontTools):

- **No tabular digits in the pixel faces.** Silkscreen digits advance 750 units except "1" (625);
  Pixelify Sans digits 586 except "1" (404), and neither has a `tnum` feature. Timecodes therefore
  use the system monospaced face so digits never jitter.
- **Silkscreen is strictly gridded** (125 units = 1/8 em; caps are 5 art pixels). At 32/3 pt an art
  pixel is exactly 4 device pixels on @3x screens (every iPhone that runs iOS 18 except the SE,
  XR and 11, which are @2x), and every advance is a multiple of 4 px, so labels render without grey
  fringes. 8 pt and 16 pt are exact on @2x too; 10 and 12 pt are not.
- **Pixelify Sans is pixel-styled, not gridded** (unit ≈ 90 units with optical offsets), so it is
  kept at 14 pt and up where anti-aliasing is negligible.
- Arabic is never set in a pixel face. Use `AdaptiveText` (or `Typo.arabic*` + `ArabicScript.rtlLines`):
  it switches to Plex Sans Arabic, prefixes each line with U+200F and sets right-to-left layout.

## Pixel rendering rules

- `PixelRect(step:)` cuts each corner with two stairs of `step/2` pt (default 2 pt → a one-pixel
  "rounded" corner). `step: 0` is a plain rectangle.
- Borders are drawn **inside** the frame as an even-odd ring (`PixelBorderShape`, `.pixelBorder()`,
  `.pixelPanel()`), so a 1-pt border covers exactly 2 or 3 whole device pixels. Do not use
  `.stroke` for pixel borders: a centred stroke straddles pixel boundaries and blurs at @3x.
- `PixelSnap.round` / `PixelSnap.lineWidth` snap geometry to the device-pixel grid; glyphs,
  progress blocks, spinner cells and empty-state art all use it.

## Icons (`PixelIcon` / `PixelGlyph`)

- **Grid:** 12 × 12 cells, `#` = ink, `.` = empty, one empty cell of margin on every side (10 × 10
  live area). Optical centre is the grid centre (6, 6); triangles sit half a cell right of the
  box centre, bubbles sit high with the tail below.
- **Weight:** object pictograms (file, folder, film, clock, lock, screen) use 1-cell outlines;
  marks and actions (play, pause, close, plus, minus, check, chevrons, arrowheads) are solid or
  use 2-cell strokes. Containers have notched corners.
- **Metaphors:** subtitles = speech box with two lines · translate = solid glyph block → arrow →
  outlined glyph block · sync = two offset bars with opposing arrowheads · timer = clock ·
  speed = gauge · aspect = corner brackets · pip = nested rectangles · fullscreen / exit = corner
  triangles pointing out / in · flag = mark · audio = headphones · volume / mute = speaker with
  waves / ×. 56 glyphs; the 7 added (`volume, mute, brightness, edit, eye, eyeOff, loop`) cover
  player gestures and visibility toggles.
- **Rendering:** `Canvas`, one path of horizontal runs, every cell a whole number of device
  pixels. The cell is `floor(frame / 12)` px, or one pixel more when the 10 × 10 live area still
  fits the frame (the empty margin may overhang). The choice ignores each glyph's own ink, so all
  glyphs share one cell size at a given point size: 12 pt → 3 px @3x · 16 pt → 3 px @2x, 4 px @3x ·
  20 pt → 4 px @2x, 6 px @3x · 24 pt → 4 px @2x, 7 px @3x.
- **Validation:** `PixelGlyphArt.validationErrors()` (Swift, unit-testable) and
  `python3 design/icons/contact_sheet.py --check` both verify N rows of N characters, only `#`/`.`,
  ink present, clear margin, no duplicates, art for every case. The script also renders
  `design/icons/contact-sheet.png` (each glyph at 6 px/cell with grid, 20 pt@3x, 16 pt@2x, amber).
- Icons are decorative (`accessibilityHidden`); the button around them carries the label.

## Components

| Component | API | States and accessibility |
|---|---|---|
| `PixelButtonStyle(kind:compact:)` | `.primary` (one per screen), `.secondary`, `.ghost`, `.destructive` | Pressed: darker fill, label sinks 1 pt. Focused: 2-pt amber ring. Disabled: `textTertiary`, no fill. `compact` draws 36 pt but keeps a 44-pt hit area. |
| `PixelIconButton(_:label:size:tint:isActive:action:)` / `PixelIconButtonStyle` | Icon-only button | ≥ 44 pt, label required, active = amber + `.isSelected`, pressed square, disabled tertiary. |
| `PixelToggleStyle` (`.toggleStyle(.pixel)`), `PixelToggle(_:subtitle:isOn:)`, `PixelSwitch` | Switch row | Whole row toggles; `.isToggle` trait, value On/Off; amber track when on; Reduce Motion = no slide. |
| `PixelSegmented(_:selection:options:title:identifier:)` | Segmented picker for any `Hashable` | Selected = amber label on `accentDim` + 2-pt base line, `.isSelected`; ≥ 44 pt; optional AX identifier per option. |
| `PixelSlider(_:value:in:step:valueText:onEditingChanged:)` | Stepped block track, square thumb | Snaps to `step` (block per step up to 24 steps); VoiceOver adjustable by one step; thumb turns amber while dragging. |
| `PixelTextFieldStyle(isFocused:isInvalid:)`, `PixelTextField(_:text:prompt:isSecure:isInvalid:message:)` | Text / secure field | `borderStrong` boundary, amber when focused, red when invalid, helper/error line; ≥ 44 pt. |
| `PixelSpinner(size:color:label:)` | 3 × 3 pixel loader | One "Loading" element, `.updatesFrequently`; Reduce Motion shows a static pattern. |
| `PixelProgressBar(value:height:tint:)` | Segmented progress | Square blocks on whole pixels, partial block at half strength; value read as percent. |
| `PixelToast` + `.pixelToast($item, edge:)` with `PixelToastItem(_:kind:duration:actionTitle:action:)` | Banner | `.info/.success/.warning/.error`; announced to VoiceOver; auto-dismiss (≥ 6 s with VoiceOver); dismiss button. |
| `PixelListRow(glyph:title:subtitle:isActive:accessory:)` + `PixelAccessory` + `PixelRowButtonStyle` | Row | ≥ 44 pt (56 with subtitle), combined AX element, active = amber glyph + leading bar + `.isSelected`; Arabic titles via `AdaptiveText`. |
| `PixelDivider(color:axis:style:inset:)` | 1-pt rule | `.solid` or `.dotted` pixel dashes; hidden from AX. |
| `SectionLabel(_:trailing:)` | UPPERCASE micro header | `.isHeader`. |
| `PixelTag(_:tint:)` | Small outlined tag | Single line micro text. |
| `PixelSheet(title:subtitle:onClose:content:)` | Sheet chrome | Title is a header; close button labelled "Close". |
| `PixelMessage(glyph:title:message:actionTitle:action:)` | Empty / error state | Text combined into one element; optional primary action. |
| `PixelEmptyArt(_:pixelSize:)` with `PixelArtwork.library/.player/.subtitles` | Pixel illustration | Multi-ink grids (`+` frame, `#` detail, `o` highlight, `a` one amber element); decorative. |
| `.pixelPanel(fill:border:)`, `.pixelBorder(_:lineWidth:step:)`, `.pixelFocusRing(_:)` | Modifiers | Crisp inside borders / focus ring. |
| `AdaptiveText(_:font:arabicFont:)` | Text | Latin in the given font; Arabic in Plex Sans Arabic, RTL. |

`DesignGallery()` (App/DesignSystem/DesignGallery.swift) shows every component and glyph on one
screen — use its Xcode preview, or host it from a UI test to screenshot the system.

## App icon

`design/icon/make_icon.py` builds the icon from a 32 × 32 grid upscaled with nearest neighbour to
1024 px (32 px per cell): a near-equilateral amber play triangle (rows grow 2, 1, 2, 1… cells, so
every stair is crisp; centroid on the centre column) with a lighter upper edge, a deeper lower
edge and a one-cell brown drop shadow, above two cream subtitle bars of different lengths — the
upper flush left, the lower flush right, a quiet nod to left-to-right English and right-to-left
Arabic. Flat warm near-black (`#0E0C0A`), no text, no tiny detail, opaque, square, no baked
corners. It reads at 40 px as "play + subtitles" and borrows nothing from other players' marks.

Appearances (iOS 18 `Contents.json` format, single 1024 universal entries): light (master,
opaque), dark (same art on transparent so the system backdrop shows) and tinted (grayscale on
black; the play triangle is brightest so the user's tint lands there).
`python3 design/icon/make_icon.py --install` regenerates everything and copies the three images
into `App/Resources/Assets.xcassets/AppIcon.appiconset/`; `design/icon/preview-sheet.png` shows
them on a rounded mask at 280/180/120/87/60/40 px.
