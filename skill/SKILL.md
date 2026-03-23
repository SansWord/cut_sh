---
name: cut-sh
description: Use this skill whenever the user wants to cut, trim, clip, or extract a segment from an MP4 video file using start and end timestamps. Triggers include: "cut this video", "trim from X to Y", "extract a clip", "clip this section", "I want the part from X to Y", or any request to extract a portion of a video file. This skill uses cut.sh — a keyframe-accurate bash script that avoids frame corruption at cut boundaries. Do NOT use for format conversion, merging multiple files, adding subtitles, or adjusting audio/video quality — those are outside this skill's scope.
---

# cut.sh Skill

## Overview

`cut.sh` is a bash script that cuts a segment from an MP4 file between two timestamps with frame-accurate boundaries. It uses a 3-segment strategy (re-encode head + stream-copy middle + re-encode tail) to avoid the keyframe corruption that a naive `-c copy` ffmpeg cut produces.

## Prerequisites

Before invoking, verify these tools are available:

```bash
which ffmpeg   # required
which ffprobe  # required
which bc       # required
```

If any are missing, inform the user and stop.

## Script location

The script must be present and executable:

```bash
ls -la ./cut.sh
chmod +x ./cut.sh
```

If `cut.sh` is not present, use the `invoke_cut.sh` wrapper which handles setup automatically.

## Usage

```bash
./cut.sh <source> <start> <end> [output] [--sequential]
```

### Arguments

| Argument | Required | Description |
|---|---|---|
| `source` | yes | Input MP4 file path |
| `start` | yes | Start timestamp — `h:mm:ss` or `hh:mm:ss` |
| `end` | yes | End timestamp — `h:mm:ss` or `hh:mm:ss` |
| `output` | no | Output filename. Bare name → `./output/<name>`. Path with `/` → exact path. Omitted → `./output/<source_filename>` |
| `--sequential` | no | Disable parallel segment processing |

### Timestamp format

Accepted: `0:13:38`, `00:13:38`, `1:06:50`, `01:06:50`
Rejected: `13:38` (missing hours), `0:13:8` (single-digit seconds)

## Invocation examples

```bash
# Basic cut
./cut.sh input.mp4 0:13:38 1:06:50

# Named output (lands in ./output/clip.mp4)
./cut.sh input.mp4 0:13:38 1:06:50 clip.mp4

# Explicit output path
./cut.sh input.mp4 0:13:38 1:06:50 ./clips/clip.mp4

# Sequential mode (useful on low-resource machines)
./cut.sh input.mp4 0:13:38 1:06:50 clip.mp4 --sequential
```

## How it works

```
START ──[re-encode]──> kf_after_start
                            │
                  kf_after_start ──[copy]──> kf_before_end
                                                   │
                                      kf_before_end ──[re-encode]──> END
```

1. Scans keyframes around `$START` and `$END` windows (±60s) using `ffprobe`
2. Re-encodes `START → kf_after_start` (head) using source codec
3. Stream-copies `kf_after_start → kf_before_end` (middle — fast, lossless)
4. Re-encodes `kf_before_end → END` (tail) using source codec
5. Concats all three segments
6. Verifies output duration matches expected

## Expected output

The script prints progress and a final summary:

```
Source info:
  video codec : h264
  audio codec : aac
  timescale   : 90000
Scanning keyframes in input.mp4...
Processing segments in parallel mode...
All segments done.
Concatenating segments...

── Summary ───────────────────────────────────────────────
  source  : input.mp4
  start   : 0:13:38
  end     : 1:06:50
  output  : ./output/clip.mp4
  mode    : parallel
  ── timing ──────────────────────────────────────────────
  scan      : 1s
  segments  : 3s (head: 1s, mid: 2s, tail: 1s)
  concat    : 1s
  elapsed   : 00:00:05
  ────────────────────────────────────────────────────────
  expected  : 3192s
  actual    : 3192s
  diff      : 0s
  done      : ./output/clip.mp4
──────────────────────────────────────────────────────────
```

## Verification

After the script completes, check:
- `diff` is `0s` or within 1-2s (acceptable rounding)
- Output file exists at the reported path
- `expected` and `actual` durations match `end - start`

If `diff` is large (>5s), report it to the user — it may indicate a sparse keyframe interval in the source file.

## Error handling

| Error message | Likely cause | Action |
|---|---|---|
| `source file not found` | Wrong path or filename | Ask user to verify the source path |
| `invalid timestamp format` | Wrong format (e.g. `13:38`) | Ask user to provide `hh:mm:ss` format |
| `end must be after start` | Timestamps reversed | Ask user to swap start/end |
| `no keyframes found` | Corrupt file or wrong format | Inform user the file may not be a valid MP4 |
| `could not find keyframes around range` | Cut window too close to file boundaries | Try widening INTERVAL in the script |
| `could not extract codec info` | Non-standard or corrupt file | Inform user and suggest re-encoding source first |
| `head/mid/tail segment failed` | ffmpeg encoding error | Run with `-v verbose` instead of `-v error` for details |

## Performance notes

- Parallel mode (default) runs head, mid, and tail simultaneously
- Pre-input `-ss` is used for head and tail — fast seek, no full-file decode
- Post-input `-ss` is used for mid (stream copy needs keyframe accuracy)
- On a ~2hr source, a ~53min cut takes ~3-5 seconds total
- Use `--sequential` only for debugging or on machines with limited CPU/IO

## See also

- `EXAMPLES.md` — sample user prompts and how to map them to arguments
- `invoke_cut.sh` — wrapper script that handles dependency checks and setup
