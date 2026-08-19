#!/bin/zsh
# Turns a raw simulator recording into an App Store preview.
#
# The recording always ends with a few seconds of springboard (XCTest kills the
# app before xcodebuild finishes), so the cut point is found by content rather
# than assumed: ForgeFit's UI is near-black, the springboard wallpaper is not,
# so the last frame whose average luma is dark is the last frame of the app.
#
# Output: H.264 High, 30 fps, yuv420p, native 1320x2868 (App Store 6.9" preview
# size), with a silent AAC track — App Store Connect rejects some previews that
# carry no audio stream at all.
set -e

IN=$1
OUT=$2
LEN=${3:-28}

if [[ -z "$IN" || -z "$OUT" ]]; then
  echo "usage: $0 <raw.mov> <output.mp4> [seconds]" >&2
  exit 64
fi

BASE=${FORGEFIT_CAPTURE_BASE:-/tmp/forgefit-appstore-capture}/video
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $BASE/$IN)

# Average luma once per second over the final 70 s.
WINDOW=70
START=$(python3 -c "print(max(0, $DUR - $WINDOW))")
ffmpeg -v error -ss $START -i $BASE/$IN \
  -vf "fps=1,scale=160:-1,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=$BASE/$OUT.yavg" \
  -f null - 2>/dev/null

APP_END=$(python3 - "$BASE/$OUT.yavg" "$START" <<'PY'
import sys, re
path, start = sys.argv[1], float(sys.argv[2])
times, vals = [], []
t = None
for line in open(path):
    m = re.match(r"frame:\d+\s+pts:\d+\s+pts_time:([\d.]+)", line)
    if m:
        t = float(m.group(1))
    m = re.search(r"lavfi\.signalstats\.YAVG=([\d.]+)", line)
    if m and t is not None:
        times.append(t); vals.append(float(m.group(1)))
# ForgeFit's dark UI sits well under 60; the springboard wallpaper is far above.
dark = [tm for tm, v in zip(times, vals) if v < 60]
print(round(start + (dark[-1] if dark else times[-1]) + 0.5, 2))
PY
)

CUT_START=$(python3 -c "print(round(max(0, $APP_END - $LEN), 2))")
echo "app ends at ${APP_END}s of ${DUR}s -> cutting ${CUT_START}s +${LEN}s"

# Option placement here is load-bearing:
#  * `-ss` must sit BEFORE the video `-i`. Between the two inputs it would be
#    read as an input option for the silent-audio input instead, and the video
#    would be encoded from frame zero — i.e. the build phase, not the tour.
#  * `-t` must be an OUTPUT option. A simulator recording emits a frame only
#    when the screen changes, so a still screen leaves a long gap with no
#    packets; limiting the input duration truncates the clip at the last real
#    frame instead of letting `fps=30` pad the hold out to full length.
ffmpeg -v error -y -ss $CUT_START -i $BASE/$IN \
  -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -map 0:v:0 -map 1:a:0 \
  -vf "fps=30,format=yuv420p" -t $LEN \
  -c:v libx264 -profile:v high -level 4.2 -preset slow -crf 20 \
  -c:a aac -b:a 128k -shortest -movflags +faststart \
  $BASE/$OUT

ffprobe -v error -show_entries format=duration -show_entries stream=codec_name,width,height,avg_frame_rate -of default=nw=1 $BASE/$OUT
