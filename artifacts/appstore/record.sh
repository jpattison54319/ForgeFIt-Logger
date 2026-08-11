#!/bin/zsh
# Records one App Store preview: start simctl screen recording, run the paced
# UI tour, stop the recording the instant the app under test exits.
#
# Stopping is driven by the *app process*, not by the xcodebuild log: when
# xcodebuild's stdout is redirected to a file it is block-buffered, so the
# "Test Case … passed" line can surface tens of seconds late and the recording
# runs on over a springboard wallpaper shot. Simulator apps are ordinary host
# processes, so `pgrep` sees the real thing.
#
# The tour relaunches the app if onboarding wins the launch race, so a
# disappearance is only treated as the end once it has held for a few seconds.
set -e

TEST=$1          # e.g. testPreviewTourTrain
OUT=$2           # e.g. preview-1-train

export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
UDID=49F5EAFA-7FC0-4914-8735-161A7B9F3E20
BASE=/private/tmp/claude-501/-Users-jamespattison-Developer-ForgeFit/2e067cfb-590d-46ab-b579-4093130facd1/scratchpad
DD=$BASE/dd
VID=$BASE/video
APP_PATTERN="ForgeFit.app/ForgeFit"
mkdir -p $VID
cd /Users/jamespattison/Developer/ForgeFit/ForgeFit

rm -f $VID/$OUT-raw.mov $VID/$OUT.log
touch $VID/$OUT.log

# A leftover instance from an earlier manual launch would make phase 2 think
# the tour had already ended, so start from a known-dead app.
xcrun simctl terminate $UDID org.xpetsllc.ForgeFit 2>/dev/null || true
for i in {1..40}; do
  pgrep -f "$APP_PATTERN" >/dev/null || break
  sleep 0.5
done

xcrun simctl io $UDID recordVideo --codec h264 --force $VID/$OUT-raw.mov &
REC=$!
sleep 2

# xcodebuild's redirected stdout is block-buffered, so the "Test Case … passed"
# line can surface well after the app has already exited and the recording runs
# on over a springboard shot. That trailing wallpaper is removed by
# finalize.sh, which finds the real cut point by frame luma rather than trusting
# where the recording happens to stop.
xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath $DD \
  -only-testing:ForgeFitUITests/AppStoreCaptureUITests/$TEST \
  CODE_SIGNING_ALLOWED=NO > $VID/$OUT.log 2>&1 &
BUILD=$!

for i in {1..1400}; do
  if grep -qE "Test Case .* (passed|failed) \(" $VID/$OUT.log; then break; fi
  kill -0 $BUILD 2>/dev/null || break
  sleep 0.3
done

kill -INT $REC
wait $REC 2>/dev/null || true
wait $BUILD 2>/dev/null || true

grep -E "^Test Case .* (passed|failed) \(" $VID/$OUT.log | tail -1
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $VID/$OUT-raw.mov
