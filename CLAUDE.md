# CLAUDE.md — Project Context for Claude Code

This file gives Claude Code full context about this project so it can continue development without re-explanation.

---

## What this project is

`cut.sh` is a keyframe-accurate MP4 cutting script built in a single Claude.ai chat session. It cuts a video between two timestamps with frame-accurate boundaries — no corrupted frames, no full re-encoding.

The project also includes a public-facing story (landing page + DEVLOG) documenting the collaboration, and an AI agent skill package so Claude can invoke `cut.sh` autonomously.

---

## Repository structure

```
├── cut.sh                  ← main script
├── README.md               ← usage reference
├── DEVLOG.md               ← full collaboration log (9 phases)
├── CLAUDE.md               ← this file
├── index.html              ← GitHub Pages landing page
├── docs/
│   └── cut_sh_docs.html    ← interactive HTML docs viewer
└── skill/
    ├── SKILL.md            ← AI agent skill descriptor
    ├── EXAMPLES.md         ← natural language → argument mappings
    └── invoke_cut.sh       ← agent wrapper with dependency checks
```

---

## How cut.sh works

A naive `-c copy` ffmpeg cut corrupts frames at keyframe boundaries. The script solves this with a **3-segment strategy**:

```
START ──[re-encode]──> kf_after_start
                            │
                  kf_after_start ──[copy]──> kf_before_end
                                                   │
                                      kf_before_end ──[re-encode]──> END
```

**Segments are skipped when not needed:**
- `SKIP_HEAD=true` when `kf_after_start == 0` (start is at beginning of file)
- `SKIP_MID=true` when `kf_before_end <= KF_MID_START` (no content between keyframes)
- `SKIP_TAIL=true` when `end_sec == kf_before_end` (end lands exactly on a keyframe)

**Codec and timescale are auto-detected from source** — no hardcoded values.

**Decode → encode codec mapping:**
```
h264 → libx264 | hevc → libx265 | vp8 → libvpx | vp9 → libvpx-vp9 | av1 → libaom-av1
aac → aac | opus → libopus | mp3 → libmp3lame | vorbis → libvorbis | flac → flac
```

---

## Usage

```bash
./cut.sh <source> <start> <end> [output] [--sequential]

# Examples
./cut.sh input.mp4 0:13:38 1:06:50
./cut.sh input.mp4 0:13:38 1:06:50 clip.mp4
./cut.sh input.mp4 0:13:38 1:06:50 ./clips/clip.mp4
./cut.sh input.mp4 0:13:38 1:06:50 clip.mp4 --sequential
```

**Output path rules:**
- Bare name → `./output/<name>`
- Path with `/` → exact path (directory created automatically)
- Omitted → `./output/<source_filename>`

---

## Key implementation details

- `ffprobe` keyframe scan uses `-read_intervals` to scan only ±60s around `$START` and `$END` — not the full file
- `-ss` before `-i` for head and tail (fast seek) — this was the key to the 67s → 3s performance breakthrough
- `-ss` after `-i` for mid (keyframe-accurate seek for stream copy)
- Float comparisons use `awk` not bash integer arithmetic — avoids truncation bugs (e.g. `4010.072733` truncated to `4010`)
- Durations formatted with `awk '{printf "%.6f", $1}'` to avoid leading-zero issues (`.483000` → `0.483000`)
- Parallel mode is default — head, mid, tail run concurrently with `&` and `wait`
- `mapfile` is intentionally avoided — not compatible with macOS bash 3.2

---

## Known bugs fixed in history

| Bug | Fix |
|---|---|
| `-ss` before `-i` changed `-to` semantics | Moved to correct position per segment type |
| Timebase mismatch (`1/90000` vs `1/60000`) | Added `-video_track_timescale "$TIMESCALE"` |
| Float truncation in keyframe comparison | Switched to `awk` float comparison |
| `N/A` keyframe values from ffprobe | Added `[[ "$ts" == "N/A" ]] && continue` |
| Combined ffprobe awk parsing failed silently | Reverted to three separate ffprobe calls |
| Leading zero missing in durations | Piped bc output through `awk '{printf "%.6f"}'` |
| Empty segment when start=0:00:00 | Added `SKIP_HEAD`, `SKIP_MID`, `SKIP_TAIL` logic |

---

## What's next (planned)

- Test on more source files — different codecs, sparse keyframes, short clips
- Deploy skill — place `skill/` at `/mnt/skills/user/cut-sh/` alongside `cut.sh`
- Batch cutting — accept a CSV of timestamps, cut multiple clips in one run
- `SKIP_TAIL` is implemented but rarely triggers (requires end to land exactly on a keyframe integer boundary)

---

## Story context

This script was built in a single ~2.5 hour Claude.ai chat session. The full story — including where Claude got it wrong, key human decisions, and a personal comment from Claude — is documented in `DEVLOG.md` and presented at the GitHub Pages landing page (`index.html`).

The collaboration is also presented publicly as a story about AI pair programming for a senior engineer's first Claude session. LinkedIn: https://www.linkedin.com/in/sansword/

---

## Dependencies

```bash
which ffmpeg    # required
which ffprobe   # required
which bc        # required
bash --version  # 3.2+ (macOS default is fine)
```
