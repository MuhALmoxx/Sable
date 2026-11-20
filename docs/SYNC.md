# Subtitle timing and guided synchronisation

When subtitles appear too early or too late, Sable offers two ways to fix it. **Manual timing**
lets you nudge or type an offset. **Guided sync** works out the offset from one spoken line.
Neither one changes the subtitle file.

> **TODO(sync)** markers are details the sync engineer's report has to confirm. The rest follows
> from the contracts (`SubtitleTiming`, `SyncMath`, `TimingStore` in SableKit).

## The model

```
effective time = original time × scale + offset
```

- **Positive offset = subtitles appear LATER.** Negative = earlier. The timing panel explains the
  sign in words next to the number ("later" / "earlier").
- `scale` is 1 unless a two-point correction is applied (see *Drift* below).
- Cue timestamps in the file are **never rewritten**. Display and export apply the timing, so you
  can undo, reset or re-sync at any time without losing the original.
- Offsets are rounded to the millisecond, so tapping ±0.1 s repeatedly never drifts by floating-point
  error.

### Where timing is stored

- Per **video** and per **timing group**, in `timing.json` in the library. The key is
  `<video UUID>|<timing group>`.
- A translated track shares its source track's group. An offset tuned while watching the English
  track also fixes its Arabic translation, and the other way round. Other tracks keep their own
  timing: fixing the French track does not move the English one.
- Every change can be undone (up to 50 steps per key). Reset is itself undoable.
- Deleting a video removes its timing.

## Manual timing

Open **Timing** in the player. The panel is compact, so the video keeps playing while you adjust:

| Control | Effect |
|---|---|
| −1 s / −0.1 s / +0.1 s / +1 s | shift the offset; applied immediately |
| entry field + Apply | type an exact signed offset (formats below) |
| Reset | back to 0.000 s (undoable) |
| Undo | restore the previous timing |

Accepted entry formats (`OffsetInput.parse`): `1.5`, `+1.5`, `-1.5`, `−1.5` (U+2212), `-90`,
`1:02.5` (m:ss.fff), `-1:02:03.25`, `250ms`, `-2s`, and a comma as decimal separator (`,5`,
`0,5`). There is no arbitrary limit, so a subtitle file made for a version with a different intro
can be offset by minutes.

The readout uses the format `+1.300 s` / `−0.100 s` / `0.000 s`.

## Guided sync: match one spoken line

This is the fastest way to fix a constant delay when you do not know how large it is:

1. Open **Sync** in the player while a subtitle track is shown. Play (or **Replay** the last few
   seconds) and tap **Mark** the moment someone **starts speaking**. Use **◀ / ▶** to nudge the mark
   if you were late.
2. Sable lists the subtitle lines around the mark: every cue whose current on-screen interval
   overlaps **±10 s** of it. If the right line is not there, **Widen** the window (30 s, 60 s, then
   all lines) or **Search** the text. Search also matches the original English while a translation
   is shown.
3. Pick the line that was spoken. Sable computes

   ```
   offset = marked speech start − the line's ORIGINAL start time
   ```

   and shows it (for example `−2.500 s`, subtitles earlier).
4. **Preview** it, **Apply** it, and **Undo** if it is not right. The result goes into the same
   undo history as manual timing.

Image-based tracks (PGS/VobSub) cannot be used for guided sync, because Sable cannot read their
text. Use manual timing for them. The VLC engine applies your offset as its subtitle delay.

### Worked example (the test fixture)

`Fixtures/UITestFixtures/night-roof.late.en.srt` is the fixture dialogue shifted **2.5 s late**.
In the audio, the line "I can't sleep." starts speaking at **7.5 s**, but the late file starts that
cue at **10.0 s**. Marking at 7.5 s and choosing that line gives

```
offset = 7.5 − 10.0 = −2.500 s   (subtitles earlier)
```

after which the line appears on time. The UI test `GuidedSyncUITests` follows exactly this
journey, and then checks that Undo restores `0.000 s`.

**TODO(sync):** confirm the nudge step size, the Replay length and whether the window choice is
remembered.

## Limitation: constant offset vs drift

A single offset fixes a **constant** delay, where every line is late (or early) by the same amount.
It cannot fix **drift**, where the error grows over the film. Drift usually comes from a frame-rate
mismatch: subtitles timed for a 25 fps (PAL) release played against a 23.976 fps video slip by
about 4 % (≈ 2.5 s after one minute, ≈ 4 min over 1.5 h). The usual sign: after a correct sync at
the start, the subtitles are off again later in the film.

A drift fix needs **two** reference points, one early and one late:

```
scale  = (markB − markA) / (cueStartB − cueStartA)
offset = markA − cueStartA × scale
```

`SyncMath.twoPointTiming` implements this in the core. It rejects points less than 1 s apart and
scales outside 0.9–1.1, which would point to the wrong line rather than real drift. Guided sync
keeps an existing scale when you re-sync a single point.

**TODO(sync):** state whether the current UI offers the second point, and how. If it does not,
the practical workaround for drifting subtitles is a subtitle file made for your exact release.

## Export

Exporting a track to SRT can **bake in** the current timing, writing effective times, so other
players show the corrected subtitles. See SUBTITLES.md › Export.
