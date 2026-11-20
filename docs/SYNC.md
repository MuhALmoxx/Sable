# Subtitle timing and guided synchronisation

When subtitles appear too early or too late, Sable offers two ways to fix it. **Manual timing**
lets you nudge or type an offset. **Guided sync** works out the offset from one spoken line (or
two, for drift). Neither one changes the subtitle file.

## The model

```
effective time = original time × scale + offset
```

- **Positive offset = subtitles appear LATER.** Negative = earlier. The timing panel explains the
  sign in words next to the number ("later" / "earlier" / "Original timing").
- `scale` is 1 unless a two-point correction is applied (see *Drift* below).
- Cue timestamps in the file are **never rewritten**. Display and export apply the timing, so you
  can undo, reset or re-sync at any time without losing the original.
- Nudges and sync results are rounded to the millisecond, so tapping ±0.1 s repeatedly never drifts
  by floating-point error.

### Where timing is stored

- Per **video** and per **timing group**, in `timing.json` in the library. The key is
  `<video UUID>|<timing group>`. The value comes back the next time you play the video.
- A translated track shares its source track's group. An offset tuned while watching the English
  track also fixes its Arabic translation, and the other way round. Other tracks keep their own
  timing: fixing the French track does not move the English one. The panel names the track and the
  group it shares.
- Every change can be undone (up to 50 steps per key). Reset is itself undoable.
- Deleting a video removes its timing. A damaged `timing.json` is kept as `timing.json.corrupt` and
  Sable starts with empty timing.

## Manual timing

Open **Timing** in the player. The sheet opens at 45 % height (it can be pulled to full height) and
leaves the video above it visible and interactive, so you can adjust while it plays. In landscape,
iOS shows such sheets at full height and covers the video.

| Control | Effect |
|---|---|
| −1 s / −0.1 s / +0.1 s / +1 s | shift the offset (labelled *Earlier* / *Later*); applied immediately. Hold to repeat: a whole hold is one undo step |
| entry field + Apply | type an exact signed offset (formats below); the keypad has ± and `:` keys. The current scale is kept |
| Undo | restore the previous timing (disabled when there is nothing to undo) |
| Reset | back to 0.000 s and scale 1 (undoable) |

Accepted entry formats (`OffsetInput.parse`): `1.5`, `+1.5`, `-1.5`, `−1.5` (U+2212), `-90`,
`1:02.5` (m:ss.fff), `-1:02:03.25`, `250ms`, `250 ms`, `-2s`, `1.5 s`, `2 sec`, and a comma as decimal
separator (`,5`, `0,5`). There is no arbitrary limit, so a subtitle file made for a version with a
different intro can be offset by minutes. Invalid input shows a message instead of being applied.

The readout uses the format `+1.300 s` / `−0.100 s` / `0.000 s` and turns amber while a correction
is active. When a drift scale is set, a note under it says so.

The panel needs an active **text** track. With subtitles off, a track still loading or an
image-based track, it explains why and offers **Choose a subtitle track**, which opens the player's
track list.

## Guided sync: match one spoken line

*You mark the moment; Sable does the math.* Open **Sync** in the player while a text subtitle track
is shown. The sheet opens at 55 % height with the video playing above it.

1. **Mark.** Play (or **Replay last 5 s**, or step ±0.1 s) and tap **Mark speech start** the moment
   someone starts speaking. Playback pauses and the mark is shown to the millisecond. Most taps land
   0.1–0.3 s late, so refine it with −0.1 / −0.01 / +0.01 / +0.1 s and **Hear it again**, which
   plays from 1.5 s before the mark. A zoomed timeline (±5 s, ticks every 0.1 s) shows the track's
   lines, your mark and the playhead, and can be dragged to scrub.
   - **Onset suggestion** (AVFoundation media only): Sable analyses the audio ±3 s around the mark
     and may offer "Suggested onset 00:00:07.512 — Use". It is a **loudness heuristic, not speech
     recognition**: music or effects can trigger it, and speech without a short quiet gap before it
     gets no suggestion. Files played with VLC (MKV and others) show "not available". Sable never
     moves your mark by itself.
2. **Which line did the character say?** Sable lists every line whose current on-screen interval
   overlaps **±10 s** of the mark, with its text (and the original English line for a translation),
   its original start–end times and its distance from the mark; the closest is tagged *Nearest*.
   If the right line is not there, **Widen** to ±30 s, ±60 s, then the whole track, or **Search** the
   whole track (English or Arabic text). Each time you come back to this step the window starts at
   ±10 s again; the choice is not remembered.
3. **Check.** Sable computes

   ```
   offset = marked speech start − the line's ORIGINAL start time
   ```

   (with an existing drift scale: `offset = mark − original start × scale`, keeping the scale) and
   shows the value, its meaning and the arithmetic. **Apply & preview** applies it and plays from
   2 s before the mark so you see the line appear. Then **Preview again**, fine-tune ±0.1 s,
   **Looks right** (closes the sheet) or **Undo**, which restores the exact timing from before the
   sync and returns to step 1.

The whole guided-sync session counts as **one undo step**: the timing panel's Undo after a finished
sync reverts all of it in one press. Switching between an English track and its Arabic translation
mid-flow keeps your progress; switching to a track in another timing group restarts the flow.

Image-based tracks (PGS/VobSub) cannot be used for guided sync or manual timing, because Sable
cannot read their lines. The Sync sheet explains this and offers to choose a text track.

### Worked example (the test fixture)

`Fixtures/UITestFixtures/night-roof.late.en.srt` is the fixture dialogue shifted **2.5 s late**.
In the audio, the line "I can't sleep." starts at **7.5 s**, but the late file starts that cue at
**10.0 s**. Marking at 7.5 s and choosing that line gives

```
offset = 7.5 − 10.0 = −2.500 s   (subtitles earlier)
```

after which the line appears on time. The UI test `GuidedSyncUITests` follows this journey (it
checks `computed offset = marked time − 10.000 s`, because a test cannot tap at an exact instant)
and then checks that Undo restores `0.000 s`.

## Limitation: constant offset vs drift

A single offset fixes a **constant** delay, where every line is late (or early) by the same amount.
It cannot fix **drift**, where the error grows over the film. Drift usually comes from a frame-rate
mismatch: subtitles timed for a 25 fps (PAL) release played against a 23.976 fps video slip by
about 4 % (≈ 2.5 s after one minute, ≈ 4 min over 1.5 h). The usual sign: after a correct sync at
the start, the subtitles are off again later in the film. A single-point sync keeps any existing
scale and never claims to fix drift.

To fix drift, use **Add a second point** after the first sync is applied. You repeat the three steps
for a second line at least **60 s** away from the first (both the marks and the lines must be that
far apart), ideally one near the start and one near the end. Sable then computes a linear correction:

```
scale  = (markB − markA) / (cueStartB − cueStartA)
offset = markA − cueStartA × scale
```

(`SyncMath.twoPointTiming`). A scale outside **0.9–1.1** (±10 %) is rejected, because it points to
the wrong line rather than real drift; so are two points on the same line or too close together.
Sable explains which problem it found, and you can drop the second point and keep the first.

## Precision

The mark is limited by how often the player publishes its time (about 30 times a second, so up to
33 ms) and by your reaction time; the millisecond nudges let you go finer. With the VLC engine the
player's clock is interpolated between VLC's time reports and is accurate to roughly 0.1–0.3 s
(up to 0.5 s right after a seek).

## Export

Exporting the Arabic translation to SRT can **bake in** the current timing, writing effective
times, so other players show the corrected subtitles. See SUBTITLES.md › Export.
