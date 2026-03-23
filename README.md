# cut.sh

A bash script for keyframe-accurate MP4 cutting using `ffmpeg` and `ffprobe`. Cuts a clip from a source file between two timestamps with frame-accurate boundaries and no quality loss on the middle segment.

## Requirements

- `ffmpeg`
- `ffprobe`
- `bc`
- bash 3.2+

## Usage

```bash
./cut.sh <source> <start> <end> [output] [--sequential]
```

### Arguments

| Argument | Description |
|---|---|
| `source` | Input MP4 file |
| `start` | Start timestamp (`h:mm:ss` or `hh:mm:ss`) |
| `end` | End timestamp (`h:mm:ss` or `hh:mm:ss`) |
| `output` | Output filename (optional) |
| `--sequential` | Disable parallel processing (optional) |

### Output path

- Bare filename (e.g. `clip.mp4`) → saved to `./output/clip.mp4`
- Path with `/` (e.g. `./clips/clip.mp4`) → saved to that exact path
- Omitted → saved to `./output/<source_filename>`

## Examples

```bash
# Basic cut, output to ./output/
./cut.sh input.mp4 0:13:38 1:06:50

# Custom output filename
./cut.sh input.mp4 0:13:38 1:06:50 clip.mp4

# Custom output path
./cut.sh input.mp4 0:13:38 1:06:50 ./clips/clip.mp4

# Sequential mode (for benchmarking or low-resource environments)
./cut.sh input.mp4 0:13:38 1:06:50 clip.mp4 --sequential
```

## How it works

A naive `-c copy` cut in ffmpeg can only cut on keyframe boundaries, which causes corrupted frames at the start and end of the clip. This script solves that with a **3-segment strategy**:

```
START ──[re-encode]──> kf_after_start
                            │
                  kf_after_start ──[copy]──> kf_before_end
                                                   │
                                      kf_before_end ──[re-encode]──> END
```

1. **Head** — re-encodes from `$START` to the next keyframe (`kf_after_start`) using the source codec
2. **Middle** — stream-copies from `kf_after_start` to `kf_before_end` (fast, lossless)
3. **Tail** — re-encodes from the last keyframe before `$END` (`kf_before_end`) to `$END` using the source codec
4. **Concat** — joins all three segments into the final output

Only a few seconds at each boundary are re-encoded. The bulk of the clip is always a fast stream copy.

### Keyframe scanning

`ffprobe` is used to scan keyframes only around the `$START` and `$END` windows (±60 seconds by default) rather than the entire file, keeping the scan fast even on long videos.

### Parallel mode (default)

By default, all three segments are processed in parallel, reducing total time. Use `--sequential` to process them one at a time, which is useful for benchmarking or on low-resource machines.

## Output

The script prints a summary after completion:

```
── Summary ───────────────────────────────────────────────
  source    : ./input.mp4
  start     : 0:13:38
  end       : 1:06:50
  output    : ./output/clip.mp4
  mode      : parallel
  ── timing ──────────────────────────────────────────────
  scan      : 1s
  segments  : 2s (head: 1s, mid: 2s, tail: 2s)
  concat    : 2s
  elapsed   : 00:00:05
  ────────────────────────────────────────────────────────
  expected  : 3192s
  actual    : 3192s
  diff      : 0s
  done      : ./output/clip.mp4
──────────────────────────────────────────────────────────
```

### Duration verification

The script automatically verifies the output duration against the expected duration (`end - start`) and shows the difference. A `diff` of `0s` confirms the cut is correct.

## Notes

- The script automatically detects the source codec (`h264`, `hevc`, etc.) and audio codec (`aac`, `opus`, etc.) and uses them for re-encoding, so no manual codec configuration is needed.
- Temp files are written to `/tmp/` and cleaned up automatically on exit, even if the script fails.
- The `--sequential` flag can be placed anywhere in the argument list.
