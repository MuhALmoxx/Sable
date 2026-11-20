#!/usr/bin/env bash
# Regenerates every media fixture from Fixtures/src with ffmpeg (no third-party footage).
#   Fixtures/UITestFixtures/   bundled into DEBUG app builds for UI tests (seeded with -seedLibrary)
#   Packages/SableKit/Tests/SubtitleKitTests/Fixtures/   used by Linux/macOS unit tests
# Video: Conway's Game of Life in the app accent colour (nearest-neighbour upscaled -> pixel art).
# Audio: "speech" bursts that start exactly at each cue start in src/sample.en.srt, so guided sync
#        can be exercised; track 2 is a different-pitch "commentary" track for audio switching.
set -euo pipefail
cd "$(dirname "$0")"
OUT_UI=UITestFixtures
OUT_UNIT=../Packages/SableKit/Tests/SubtitleKitTests/Fixtures
mkdir -p "$OUT_UI" "$OUT_UNIT" .work
DUR=40

python3 - "$DUR" <<'PY'
import re, sys
dur = int(sys.argv[1])
srt = open('src/sample.en.srt', encoding='utf-8').read()
spans = []
for a, b in re.findall(r'(\d\d:\d\d:\d\d,\d\d\d) --> (\d\d:\d\d:\d\d,\d\d\d)', srt):
    def sec(x):
        h, m, s = x.split(':'); s, ms = s.split(',')
        return int(h)*3600 + int(m)*60 + int(s) + int(ms)/1000
    s, e = sec(a), sec(b)
    spans.append((s, s + min(1.6, (e - s) * 0.8)))
def expr(base):
    gate = '+'.join(f'between(t,{s:.3f},{e:.3f})' for s, e in spans)
    # vowel-like harmonic stack with syllable-rate amplitude modulation
    voice = f'(0.5*sin(2*PI*{base}*t)+0.3*sin(2*PI*{base*2}*t)+0.2*sin(2*PI*{base*3}*t))*(0.6+0.4*sin(2*PI*5*t))'
    return f'0.6*({gate})*{voice}'
open('.work/voice1.txt', 'w').write(expr(180))
open('.work/voice2.txt', 'w').write(expr(260))
PY

ffmpeg -hide_banner -loglevel error -y -f lavfi -i "aevalsrc=exprs='$(cat .work/voice1.txt)':s=48000:d=$DUR" -c:a aac -b:a 64k .work/a1.m4a
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "aevalsrc=exprs='$(cat .work/voice2.txt)':s=48000:d=$DUR" -c:a aac -b:a 64k .work/a2.m4a
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "life=s=96x54:mold=12:r=24:ratio=0.12:seed=7:life_color=#FFB43C:death_color=#000000:mold_color=#2A1D08" \
  -t $DUR -vf "scale=960:540:flags=neighbor,format=yuv420p" -c:v libx264 -preset veryslow -crf 30 -tune animation \
  -g 48 -movflags +faststart .work/v.mp4

# MKV: H.264 + 2 audio + SRT(en, default) + ASS(en) + SRT(fr)
ffmpeg -hide_banner -loglevel error -y -i .work/v.mp4 -i .work/a1.m4a -i .work/a2.m4a \
  -i src/sample.en.srt -i src/sample.en.ass -i src/sample.fr.srt \
  -map 0:v -map 1:a -map 2:a -map 3 -map 4 -map 5 -c:v copy -c:a copy -c:s:0 srt -c:s:1 ass -c:s:2 srt \
  -metadata title="Night Roof (Sable sample)" \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="Dialogue" \
  -metadata:s:a:1 language=eng -metadata:s:a:1 title="Commentary" \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" -disposition:s:0 default \
  -metadata:s:s:1 language=eng -metadata:s:s:1 title="English (styled)" -disposition:s:1 0 \
  -metadata:s:s:2 language=fre -metadata:s:s:2 title="Français" -disposition:s:2 0 \
  "$OUT_UI/night-roof.mkv"

# MP4: H.264 + 2 audio (alternate group) + mov_text (en)
ffmpeg -hide_banner -loglevel error -y -i .work/v.mp4 -i .work/a1.m4a -i .work/a2.m4a -i src/sample.en.srt \
  -map 0:v -map 1:a -map 2:a -map 3 -c:v copy -c:a copy -c:s mov_text \
  -metadata title="Night Roof (MP4)" \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="Dialogue" \
  -metadata:s:a:1 language=eng -metadata:s:a:1 title="Commentary" -disposition:a:1 0 \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
  -movflags +faststart "$OUT_UI/night-roof.mp4"

# WebVTT inside Matroska (D_WEBVTT/SUBTITLES) and WebM, subtitle-only. Stream copy keeps cue ids,
# settings and markup verbatim in the blocks ("id\nsettings\npayload"), as real muxers store them.
for EXT in mkv webm; do
  ffmpeg -hide_banner -loglevel error -y -fflags +bitexact -i src/sample.en.vtt -map 0 -c:s copy \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="English (WebVTT)" "$OUT_UNIT/sample.webvtt.$EXT"
done

cp src/sample.late2500.en.srt "$OUT_UI/night-roof.late.en.srt"
cp src/sample.en.srt src/sample.en.ass src/sample.fr.srt src/sample.late2500.en.srt src/sample.en.vtt "$OUT_UNIT/"
cp "$OUT_UI/night-roof.mkv" "$OUT_UNIT/night-roof.mkv"
rm -rf .work
ls -la "$OUT_UI" "$OUT_UNIT"
