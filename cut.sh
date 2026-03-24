#!/usr/bin/env bash

# ── Usage ─────────────────────────────────────────────────────
usage() {
  echo "Usage: $(basename "$0") <source> <start> <end> [output] [--sequential]"
  echo
  echo "  source   Input MP4 file"
  echo "  start    Start timestamp (h:mm:ss or hh:mm:ss)"
  echo "  end      End timestamp (h:mm:ss or hh:mm:ss)"
  echo "  output   Output filename (default: ./output/<source_filename>)"
  echo "           Provide a bare name to land in ./output/"
  echo "           Provide a path (with /) to override location"
  echo
  echo "Example:"
  echo "  $(basename "$0") input.mp4 0:13:38 1:06:50"
  echo "  $(basename "$0") input.mp4 0:13:38 1:06:50 clip.mp4"
  echo "  $(basename "$0") input.mp4 0:13:38 1:06:50 ./clips/clip.mp4"
  echo "  $(basename "$0") input.mp4 0:13:38 1:06:50 clip.mp4 --sequential"
  exit 1
}

PARALLEL=true
ARGS=()
for arg in "$@"; do
  [[ "$arg" == "--sequential" ]] && PARALLEL=false || ARGS+=("$arg")
done

[[ ${#ARGS[@]} -lt 3 || ${#ARGS[@]} -gt 4 ]] && { echo "Error: expected 3 or 4 arguments, got ${#ARGS[@]}." >&2; usage; }

SOURCE="${ARGS[0]}"
START="${ARGS[1]}"
END="${ARGS[2]}"
OUTPUT_ARG="${ARGS[3]}"

# ── Convert hh:mm:ss to seconds ───────────────────────────────
hhmmss_to_seconds() {
  local hh mm ss
  IFS=':' read -r hh mm ss <<< "$1"
  echo $(( (10#$hh * 3600) + (10#$mm * 60) + 10#$ss ))
}

# ── Validate timestamp format ─────────────────────────────────
validate_timestamp() {
  [[ "$1" =~ ^[0-9]{1,2}:[0-9]{2}:[0-9]{2}$ ]] || \
    { echo "Error: invalid timestamp format '$1', expected hh:mm:ss" >&2; exit 1; }
}
validate_timestamp "$START"
validate_timestamp "$END"

# ── Input validation ──────────────────────────────────────────
[[ ! -f "$SOURCE" ]] && { echo "Error: source file not found: $SOURCE" >&2; exit 1; }

start_sec=$(hhmmss_to_seconds "$START")
end_sec=$(hhmmss_to_seconds "$END")

[[ "$end_sec" -le "$start_sec" ]] && { echo "Error: end must be after start." >&2; exit 1; }

# ── Default output path ───────────────────────────────────────
mkdir -p ./output
if [[ -n "$OUTPUT_ARG" ]]; then
  if [[ "$OUTPUT_ARG" == */* ]]; then
    OUTPUT="$OUTPUT_ARG"
    mkdir -p "$(dirname "$OUTPUT")"
  else
    OUTPUT="./output/$OUTPUT_ARG"
  fi
else
  OUTPUT="./output/$(basename "$SOURCE")"
fi

# ── Temp files ────────────────────────────────────────────────
TMP_HEAD="/tmp/cut_head.mp4"
TMP_MID="/tmp/cut_mid.mp4"
TMP_TAIL="/tmp/cut_tail.mp4"
TMP_LIST="/tmp/cut_list.txt"

cleanup() {
  rm -f "$TMP_HEAD" "$TMP_MID" "$TMP_TAIL" "$TMP_LIST" \
        /tmp/cut_time_head /tmp/cut_time_mid /tmp/cut_time_tail
}
trap cleanup EXIT

# ── Find last keyframe at or before a given time ──────────────
keyframe_before() {
  local target_sec="$1"
  local best=""
  for ts in "${KEYFRAMES[@]}"; do
    local result
    result=$(echo "$ts $target_sec" | awk '{print ($1 <= $2) ? "yes" : "no"}')
    [[ "$result" == "yes" ]] && best="$ts" || break
  done
  echo "$best"
}

# ── Find first keyframe at or after a given time ──────────────
keyframe_after() {
  local target_sec="$1"
  for ts in "${KEYFRAMES[@]}"; do
    local result
    result=$(echo "$ts $target_sec" | awk '{print ($1 >= $2) ? "yes" : "no"}')
    if [[ "$result" == "yes" ]]; then
      echo "$ts"
      return
    fi
  done
}

# ── Main ──────────────────────────────────────────────────────

# ── Extract encoding params from source ──────────────────────
VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name \
  -of default=noprint_wrappers=1:nokey=1 \
  "$SOURCE")

AUDIO_CODEC=$(ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name \
  -of default=noprint_wrappers=1:nokey=1 \
  "$SOURCE")

# ── Map decode codec names to encode codec names ─────────────
[[ "$VIDEO_CODEC" == "h264" ]]  && VIDEO_CODEC="libx264"
[[ "$VIDEO_CODEC" == "hevc" ]]  && VIDEO_CODEC="libx265"
[[ "$VIDEO_CODEC" == "vp8"  ]]  && VIDEO_CODEC="libvpx"
[[ "$VIDEO_CODEC" == "vp9"  ]]  && VIDEO_CODEC="libvpx-vp9"
[[ "$VIDEO_CODEC" == "av1"  ]]  && VIDEO_CODEC="libaom-av1"
[[ "$AUDIO_CODEC" == "aac"  ]]  && AUDIO_CODEC="aac"
[[ "$AUDIO_CODEC" == "opus" ]]  && AUDIO_CODEC="libopus"
[[ "$AUDIO_CODEC" == "mp3"  ]]  && AUDIO_CODEC="libmp3lame"
[[ "$AUDIO_CODEC" == "vorbis" ]] && AUDIO_CODEC="libvorbis"
[[ "$AUDIO_CODEC" == "flac" ]]  && AUDIO_CODEC="flac"

TIMESCALE=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=time_base \
  -of default=noprint_wrappers=1:nokey=1 \
  "$SOURCE" | awk -F'/' '{print $2}')

if [[ -z "$VIDEO_CODEC" || -z "$AUDIO_CODEC" || -z "$TIMESCALE" ]]; then
  echo "Error: could not extract codec info from $SOURCE." >&2
  exit 1
fi

echo "Source info:"
echo "  video codec : $VIDEO_CODEC"
echo "  audio codec : $AUDIO_CODEC"
echo "  timescale   : $TIMESCALE"

# ── Timer start ───────────────────────────────────────────────
TIME_START=$(date +%s)
TIME_SCAN_START=$TIME_START
echo "Scanning keyframes in $SOURCE..."

INTERVAL=60
start_window=$(( start_sec - INTERVAL ))
[[ "$start_window" -lt 0 ]] && start_window=0

KEYFRAMES=()
while IFS= read -r ts; do
  [[ "$ts" == "N/A" ]] && continue
  KEYFRAMES+=("$ts")
  frame_sec=$(echo "$ts" | awk '{printf "%d", $1}')
  [[ "$frame_sec" -gt "$(( end_sec + INTERVAL ))" ]] && break
done < <(ffprobe -v error \
  -read_intervals "${start_window}%$(( start_sec + INTERVAL )),$(( end_sec - INTERVAL ))%$(( end_sec + INTERVAL ))" \
  -of default=noprint_wrappers=1:nokey=1 \
  -select_streams v \
  -skip_frame nokey \
  -show_frames \
  -show_entries frame=pkt_dts_time \
  "$SOURCE")

if [[ ${#KEYFRAMES[@]} -eq 0 ]]; then
  echo "Error: no keyframes found in $SOURCE." >&2
  exit 1
fi

kf_after_start=$(keyframe_after "$start_sec" | tr -d '[:space:]')
kf_before_end=$(keyframe_before "$end_sec" | tr -d '[:space:]')

if [[ -z "$kf_after_start" || -z "$kf_before_end" ]]; then
  echo "Error: could not find keyframes around the given range." >&2
  exit 1
fi
TIME_SCAN_END=$(date +%s)

# ── Steps 1-3: Process all segments ───────────────────────────

SKIP_HEAD=$(echo "$kf_after_start" | awk '{print ($1 == 0) ? "true" : "false"}')
KF_MID_START=$([[ "$SKIP_HEAD" == true ]] && echo "0" || echo "$kf_after_start")

SKIP_MID=$(echo "$kf_before_end $KF_MID_START" | awk '{print ($1 <= $2) ? "true" : "false"}')

head_duration=$(echo "$kf_after_start - $start_sec" | bc | awk '{printf "%.6f", $1}')
mid_duration=$(echo "$kf_before_end - $KF_MID_START" | bc | awk '{printf "%.6f", $1}')
tail_duration=$(echo "$end_sec - $kf_before_end" | bc | awk '{printf "%.6f", $1}')

TIME_SEGMENTS_START=$(date +%s)
echo "Processing segments in $([ "$PARALLEL" == true ] && echo "parallel" || echo "sequential") mode..."

if [[ "$PARALLEL" == true ]]; then
  if [[ "$SKIP_HEAD" == false ]]; then
    TIME_HEAD_START=$(date +%s)
    ffmpeg -v error -ss "$START" -i "$SOURCE" -t "$head_duration" \
      -reset_timestamps 1 -video_track_timescale "$TIMESCALE" \
      -c:v "$VIDEO_CODEC" -c:a "$AUDIO_CODEC" -y "$TMP_HEAD" && \
      echo "$(( $(date +%s) - TIME_HEAD_START ))" > /tmp/cut_time_head &
    PID_HEAD=$!
  fi

  if [[ "$SKIP_MID" == false ]]; then
    TIME_MID_START=$(date +%s)
    ffmpeg -v error -i "$SOURCE" -ss "$KF_MID_START" -t "$mid_duration" \
      -reset_timestamps 1 -video_track_timescale "$TIMESCALE" \
      -c copy -y "$TMP_MID" && \
      echo "$(( $(date +%s) - TIME_MID_START ))" > /tmp/cut_time_mid &
    PID_MID=$!
  fi

  TIME_TAIL_START=$(date +%s)
  ffmpeg -v error -ss "$kf_before_end" -i "$SOURCE" -t "$tail_duration" \
    -reset_timestamps 1 -video_track_timescale "$TIMESCALE" \
    -c:v "$VIDEO_CODEC" -c:a "$AUDIO_CODEC" -y "$TMP_TAIL" && \
    echo "$(( $(date +%s) - TIME_TAIL_START ))" > /tmp/cut_time_tail &
  PID_TAIL=$!

  [[ "$SKIP_HEAD" == false ]] && { wait $PID_HEAD || { echo "Error: head segment failed." >&2; exit 1; }; }
  [[ "$SKIP_MID" == false ]] && { wait $PID_MID || { echo "Error: mid segment failed." >&2; exit 1; }; }
  wait $PID_TAIL || { echo "Error: tail segment failed." >&2; exit 1; }

  ELAPSED_HEAD=$([[ "$SKIP_HEAD" == true ]] && echo "skipped" || cat /tmp/cut_time_head 2>/dev/null || echo "N/A")
  ELAPSED_MID=$([[ "$SKIP_MID" == true ]] && echo "skipped" || cat /tmp/cut_time_mid 2>/dev/null || echo "N/A")
  ELAPSED_TAIL=$(cat /tmp/cut_time_tail 2>/dev/null || echo "N/A")
else
  if [[ "$SKIP_HEAD" == false ]]; then
    TIME_HEAD_START=$(date +%s)
    ffmpeg -v error -ss "$START" -i "$SOURCE" -t "$head_duration" \
      -reset_timestamps 1 -video_track_timescale "$TIMESCALE" \
      -c:v "$VIDEO_CODEC" -c:a "$AUDIO_CODEC" -y "$TMP_HEAD" \
      || { echo "Error: head segment failed." >&2; exit 1; }
    ELAPSED_HEAD=$(( $(date +%s) - TIME_HEAD_START ))
  else
    ELAPSED_HEAD="skipped"
  fi

  if [[ "$SKIP_MID" == false ]]; then
    TIME_MID_START=$(date +%s)
    ffmpeg -v error -i "$SOURCE" -ss "$KF_MID_START" -t "$mid_duration" \
      -reset_timestamps 1 -video_track_timescale "$TIMESCALE" \
      -c copy -y "$TMP_MID" \
      || { echo "Error: mid segment failed." >&2; exit 1; }
    ELAPSED_MID=$(( $(date +%s) - TIME_MID_START ))
  else
    ELAPSED_MID="skipped"
  fi

  TIME_TAIL_START=$(date +%s)
  ffmpeg -v error -ss "$kf_before_end" -i "$SOURCE" -t "$tail_duration" \
    -reset_timestamps 1 -video_track_timescale "$TIMESCALE" \
    -c:v "$VIDEO_CODEC" -c:a "$AUDIO_CODEC" -y "$TMP_TAIL" \
    || { echo "Error: tail segment failed." >&2; exit 1; }
  ELAPSED_TAIL=$(( $(date +%s) - TIME_TAIL_START ))
fi
echo "All segments done."
TIME_SEGMENTS_END=$(date +%s)

# ── Step 4: Concat all three ───────────────────────────────────
TIME_CONCAT_START=$(date +%s)
CONCAT_SEGMENTS=""
[[ "$SKIP_HEAD" == false ]] && CONCAT_SEGMENTS="head"
[[ "$SKIP_MID"  == false ]] && CONCAT_SEGMENTS="${CONCAT_SEGMENTS:+$CONCAT_SEGMENTS, }mid"
CONCAT_SEGMENTS="${CONCAT_SEGMENTS:+$CONCAT_SEGMENTS, }tail"
echo "Concatenating segments: $CONCAT_SEGMENTS..."

if [[ "$SKIP_HEAD" == true && "$SKIP_MID" == true ]]; then
  printf "file '%s'\n" "$TMP_TAIL" > "$TMP_LIST"
elif [[ "$SKIP_HEAD" == true ]]; then
  printf "file '%s'\nfile '%s'\n" "$TMP_MID" "$TMP_TAIL" > "$TMP_LIST"
elif [[ "$SKIP_MID" == true ]]; then
  printf "file '%s'\nfile '%s'\n" "$TMP_HEAD" "$TMP_TAIL" > "$TMP_LIST"
else
  printf "file '%s'\nfile '%s'\nfile '%s'\n" "$TMP_HEAD" "$TMP_MID" "$TMP_TAIL" > "$TMP_LIST"
fi

ffmpeg -v error -f concat -safe 0 -i "$TMP_LIST" \
  -c copy \
  -reset_timestamps 1 \
  -y "$OUTPUT"
TIME_CONCAT_END=$(date +%s)

# ── Verify output duration ────────────────────────────────────
EXPECTED_DURATION=$(( end_sec - start_sec ))
ACTUAL_DURATION=$(ffprobe -v error \
  -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 \
  "$OUTPUT" | awk '{printf "%d", $1}')
DURATION_DIFF=$(( ACTUAL_DURATION - EXPECTED_DURATION ))
[[ $DURATION_DIFF -lt 0 ]] && DURATION_DIFF=$(( -DURATION_DIFF ))

TIME_END=$(date +%s)
ELAPSED=$(( TIME_END - TIME_START ))
ELAPSED_FMT=$(printf "%02d:%02d:%02d" $(( ELAPSED / 3600 )) $(( (ELAPSED % 3600) / 60 )) $(( ELAPSED % 60 )))
ELAPSED_SCAN=$(( TIME_SCAN_END - TIME_SCAN_START ))
ELAPSED_SEGMENTS=$(( TIME_SEGMENTS_END - TIME_SEGMENTS_START ))
ELAPSED_CONCAT=$(( TIME_CONCAT_END - TIME_CONCAT_START ))

echo
echo "── Summary ───────────────────────────────────────────────"
echo "  source  : $SOURCE"
echo "  start   : $START"
echo "  end     : $END"
echo "  output  : $OUTPUT"
echo "  mode    : $([ "$PARALLEL" == true ] && echo "parallel" || echo "sequential")"
echo "  ── timing ──────────────────────────────────────────────"
echo "  scan      : ${ELAPSED_SCAN}s"
echo "  segments  : ${ELAPSED_SEGMENTS}s (head: ${ELAPSED_HEAD}s, mid: ${ELAPSED_MID}s, tail: ${ELAPSED_TAIL}s)"
echo "  concat    : ${ELAPSED_CONCAT}s"
echo "  elapsed   : $ELAPSED_FMT"
echo "  ────────────────────────────────────────────────────────"
echo "  expected  : ${EXPECTED_DURATION}s"
echo "  actual    : ${ACTUAL_DURATION}s"
echo "  diff      : ${DURATION_DIFF}s"
echo "  done      : $OUTPUT"
echo "──────────────────────────────────────────────────────────"
