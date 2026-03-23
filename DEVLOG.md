# Collaboration Summary: Building cut.sh

## Overview

This document summarizes a collaborative session between a user and Claude (Anthropic) to build `cut.sh` — a keyframe-accurate MP4 cutting script using `ffmpeg` and `ffprobe`.

The session started from a simple ffmpeg question and evolved iteratively into a fully-featured, production-ready bash script — then continued into documentation, storytelling, and a public-facing landing page.

**Estimated time breakdown:**

| Phase | Activity | Est. time |
|---|---|---|
| 1–3 | ffmpeg fundamentals, bash utilities, keyframe scanning | ~30 min |
| 4–5 | 3-segment strategy, debugging, timescale fix | ~45 min |
| 6 | Performance investigation and breakthrough | ~20 min |
| 7 | Polish, validation, parallel mode, summary output | ~25 min |
| 8 | Documentation, skill package | ~20 min |
| 9 | Story, landing page, reflection, this DEVLOG | ~30 min |
| **Total** | | **~2.5 hours** |

---

## Journey

### Phase 1: ffmpeg fundamentals

The session began with understanding a basic ffmpeg cut command:

```bash
ffmpeg -ss 0:13:38 -i ./input -to 0:13:39 -c copy ./output.mp4
```

Key lessons:
- `-ss` before `-i` is a fast seek but makes `-to` an absolute timestamp, causing the wrong duration
- `-ss` after `-i` is slower but accurate — fix was to move `-ss` after `-i`
- `-c copy` can only cut on keyframe boundaries, introducing corrupted frames

### Phase 2: bash foundations

Built reusable bash utilities:
- A 4-argument script template with usage display
- `hhmmss_to_seconds` — converts `hh:mm:ss` to total seconds using `IFS` splitting and `10#` base-10 forcing to handle leading zeros (`08`, `09`)
- Discussed `$1` vs `read` input, and how bash functions "return" values via `echo` + command substitution `$()`

### Phase 3: keyframe scanning

Used `ffprobe` to scan keyframes:

```bash
ffprobe -v error -of default=noprint_wrappers=1:nokey=1 \
  -select_streams v -skip_frame nokey \
  -show_frames -show_entries frame=pkt_dts_time $SOURCE
```

Built `keyframe_before` and `keyframe_after` functions. Fixed a float precision bug where `4010.072733` was being truncated to `4010` and incorrectly passing an integer `<=` check — fixed by using `awk` for float comparison instead of bash integer arithmetic.

Optimized `ffprobe` to scan only around `$START` and `$END` windows using `-read_intervals`, avoiding full-file scans on long videos.

### Phase 4: 3-segment cut strategy

Replaced the naive single `-c copy` cut with a 3-segment approach:

```
START ──[re-encode]──> kf_after_start
                            │
                  kf_after_start ──[copy]──> kf_before_end
                                                   │
                                      kf_before_end ──[re-encode]──> END
```

- **Head**: re-encode `START → kf_after_start`
- **Middle**: stream copy `kf_after_start → kf_before_end`
- **Tail**: re-encode `kf_before_end → END`
- **Concat**: join all three with `-f concat`

### Phase 5: debugging

Several bugs were caught and fixed through systematic debugging. The most instructive was the duration corruption.

**The timescale bug — guided debugging from a symptom**

The output file was 4780s instead of the expected 3192s, with no ffmpeg error. The only information available was a wrong number. Claude provided `ffprobe` commands to inspect each temp file individually:

```bash
ffprobe -v error -show_entries stream=codec_name,time_base,r_frame_rate \
  -of default=noprint_wrappers=1 /tmp/cut_head.mp4
ffprobe -v error -show_entries stream=codec_name,time_base,r_frame_rate \
  -of default=noprint_wrappers=1 /tmp/cut_mid.mp4
ffprobe -v error -show_entries stream=codec_name,time_base,r_frame_rate \
  -of default=noprint_wrappers=1 /tmp/cut_tail.mp4
```

This was only possible because the cleanup function had already been commented out during earlier testing — keeping the temp files on disk. Claude didn't ask for this. It was a debugging habit that turned out to be essential.

The raw output revealed the issue: head and tail had `time_base=1/60000`, but the middle segment had `time_base=1/90000`. A timebase mismatch between segments silently corrupts the concat output duration.

Fix: `-video_track_timescale "$TIMESCALE"` added to all three steps to force consistency, plus `-reset_timestamps 1` to ensure clean segment boundaries.

**The hardcoded codec issue**

Claude's original re-encoding used hardcoded `libx264` and `aac`. This wasn't flagged as a problem initially, but the question was raised: why hardcode a codec when the source file already has one? There's no good reason — and on a non-H.264 source it would silently produce wrong output.

This led to auto-detecting `VIDEO_CODEC`, `AUDIO_CODEC`, and `TIMESCALE` from the source file at runtime using `ffprobe`. The suggestion came from the human side, not Claude.

**Full bug table**

| Bug | Symptom | Fix |
|---|---|---|
| Missing `$kf_after_start` in Step 2 | Middle segment cut from wrong position | Added missing argument after `-ss` |
| Timebase mismatch | Final output 4780s instead of 3192s | Added `-video_track_timescale "$TIMESCALE"` to all steps |
| Timestamp discontinuity | Concat misaligned segments | Added `-reset_timestamps 1` to all steps and concat |
| Float truncation | `kf_before_end` returning wrong keyframe | Switched integer `<=` to `awk` float comparison |
| `N/A` keyframe values | `bc` division by zero error | Added `[[ "$ts" == "N/A" ]] && continue` filter |
| Combined `ffprobe` awk parsing | Empty `VIDEO_CODEC`, `AUDIO_CODEC`, `TIMESCALE` | Reverted to three separate `ffprobe` calls |

### Phase 6: performance optimization

This phase is worth telling accurately, because Claude got it wrong before getting it right.

When performance came up, Claude was asked which step would be the bottleneck. Claude incorrectly claimed the middle stream-copy segment would take the most time. That didn't sit right — stream copy has no encoding work and should be near-instant. The answer was rejected.

Claude then pointed to the concat step as the likely bottleneck. That was also wrong and was pushed back on.

Rather than accept either answer, per-segment timing was requested to find out empirically — adding `ELAPSED_HEAD`, `ELAPSED_MID`, `ELAPSED_TAIL` to the summary output. This was the key decision.

The breakdown revealed the actual data:

```
segments : 67s (head: 9s, mid: 1s, tail: 57s)
```

The middle copy was 1 second as expected. The tail was 57 seconds for just 5 seconds of content. The real culprit: post-input `-ss` was making ffmpeg decode the entire 66-minute file before reaching the cut point for every re-encoded segment.

**Fix:** move `-ss` before `-i` for head and tail (fast seek). Keep post-input `-ss` only for the middle copy where keyframe accuracy matters.

Results:
- Sequential: 67s → **4s** (~17× speedup)
- Parallel: 61s → **3s** (~20× speedup)

The 20× performance gain came entirely from a human instinct that the AI's diagnosis was wrong, combined with the discipline to instrument the code rather than guess.

### Phase 7: polish and features

Final additions:
- `validate_timestamp` — regex check for `h:mm:ss` or `hh:mm:ss` format
- Source file existence check
- End must be after start check
- `--sequential` flag — strips flag from args before positional parsing
- Source codec auto-detection — `VIDEO_CODEC`, `AUDIO_CODEC`, `TIMESCALE` extracted from source
- Per-segment timing — `ELAPSED_HEAD`, `ELAPSED_MID`, `ELAPSED_TAIL`
- Output duration verification — compares expected vs actual duration with diff
- Full summary output

### Phase 8: documentation and skill packaging

The session concluded with generating a full documentation and skill package:

**Documentation files:**
- `README.md` — user-facing reference covering usage, arguments, output path rules, the 3-segment strategy, and the summary format
- `DEVLOG.md` (this file) — full collaboration log covering all phases, bugs, optimizations, and key learnings
- `cut_sh_docs.html` — a self-contained HTML file combining README and DEVLOG into a tabbed interface with syntax highlighting, dark mode support, and a copy button for the script

**AI agent skill folder (`cut-sh-skill/`):**
- `SKILL.md` — the primary skill descriptor read by AI agents. Includes frontmatter trigger description, full argument reference, expected output format, error handling table, and performance notes
- `EXAMPLES.md` — maps natural language user requests to exact `cut.sh` arguments, including edge cases like relative durations and multiple cuts
- `invoke_cut.sh` — a wrapper script for AI agents that handles dependency checks (`ffmpeg`, `ffprobe`, `bc`), locates `cut.sh` automatically, validates arguments before passing them through, and provides clean exit codes

To deploy the skill, place the `cut-sh-skill/` folder at `/mnt/skills/user/cut-sh/` alongside `cut.sh`. The agent will automatically load `SKILL.md` when a user asks to cut or trim a video.

### Phase 9: post-development discussion and storytelling

After the script was complete, the session continued into something unexpected — turning the development process itself into a story worth sharing publicly.

This phase covered:

**Generating the story:**
- Reviewing the full session to identify the most meaningful moments
- Deciding how to frame the collaboration honestly — not as "AI wrote my code" but as a genuine two-way process
- Identifying specific human contributions that changed the outcome (timing request, codec suggestion, temp file habit, pushing back on wrong diagnoses)
- Being deliberate about what Claude got wrong — including the double-wrong performance diagnosis — to make the story credible rather than promotional

**Building the landing page:**
- A full `index.html` with hero, timeline, breakthrough card, collaboration split, "Where Claude got it wrong" section, and final reflection
- Designed for a senior engineering audience — accurate, specific, and honest about failures
- The "too vibe" concern addressed directly — the story is partly about overcoming skepticism of AI coding

**Reflecting on the session:**
- The biggest surprise wasn't the code — it was the debugging loop speed
- The concern going in was "vibe coding" — generated plausible-looking code that doesn't hold up. That didn't happen.
- The session produced not just a script but a deeper understanding of ffmpeg internals — keyframes, timescales, `-ss` semantics — all learned through debugging, not instruction

**Accuracy corrections made during this phase:**
- Toned down "0 prior ffmpeg knowledge" — the correct framing is "knew what ffmpeg could do, not how video works internally"
- Corrected the performance breakthrough narrative — Claude got the diagnosis wrong twice before the human demanded empirical data
- Added the timescale debugging story — including that the temp files being available was a human debugging habit, not something Claude asked for
- Added codec auto-detection as a human-side suggestion — Claude's original was hardcoded `libx264`/`aac` with no good reason

---

## Final Summary

### What was built

A production-ready bash script (`cut.sh`) and a complete AI agent skill package:

1. Validates all inputs — source file, timestamp format, end after start
2. Extracts codec info from the source file automatically
3. Scans keyframes only around the cut points (not the full file)
4. Cuts accurately using a 3-segment head/mid/tail strategy
5. Re-encodes only the small boundaries, stream-copies the bulk
6. Processes segments in parallel by default
7. Verifies the output duration matches expected
8. Prints a detailed summary with per-step timing
9. Packaged as a reusable AI agent skill with `SKILL.md`, `EXAMPLES.md`, and `invoke_cut.sh`

### Key metrics (on a ~2hr source file, ~53 min clip)

| Version | Time |
|---|---|
| Initial naive `-c copy` | ~1s (but wrong duration) |
| Post-input `-ss`, sequential | ~67s |
| Post-input `-ss`, parallel | ~61s |
| Pre-input `-ss` for head/tail, sequential | ~4s |
| Pre-input `-ss` for head/tail, parallel | ~3s |

### Where Claude got it wrong

This wasn't a flawless session. Claude made real mistakes — each caught through review and testing:

| Mistake | How it was caught | Fix |
|---|---|---|
| **Wrong performance diagnosis × 2** — claimed mid-copy then concat were the bottleneck | Human instinct: stream copy can't be slow; pushed back twice, then demanded per-segment timing data | Added timing breakdown; data revealed the real cause was post-input `-ss` decoding the full file |
| Reintroduced `-ss` before `-i` in parallel steps | Reviewing the final script before running | Moved `-ss` back to correct position |
| Suggested `mapfile` (bash 4+ only) | Script failed to run on macOS default bash 3.2 | Replaced with compatible `while read` loop |
| Combined `ffprobe` awk parsing failed silently | Empty `VIDEO_CODEC`, `AUDIO_CODEC`, `TIMESCALE` in output | Reverted to three separate `ffprobe` calls with a guard check |
| Missing `$kf_after_start` argument in Step 2 | Middle segment cut from wrong position | Added missing value after `-ss` |

The pattern: Claude introduced the bugs, human review caught them. Neither alone would have shipped clean code as fast.

---

## Final reflection

Going into this session, the concern was that AI coding would feel "too vibe" — generated code that looks plausible but doesn't really hold up under scrutiny. That's not what happened.

**What I expected:**
- Generated code I'd need to heavily rewrite
- Explanations that sounded right but weren't
- Having to verify everything independently
- A tool, not a collaborator

**What actually happened:**
- Iterative refinement, not generation — every change had a reason
- Real explanations that changed how I think about ffmpeg internals
- Claude made mistakes, but they were catchable with normal engineering review
- The fastest debugging loop I've experienced — paste error, get fix, understand why, move on

The output is solid enough that the next step is testing it properly and deploying it as an AI agent skill — not rewriting it.

**Fun fact:** every single request across ~2.5 hours was phrased as a question or suggestion — "can you", "is it possible to", "what do you think if". Even catching Claude's mistakes was framed as an observation: "I've noticed -ss is before the -i flag — would that cause any issue?" Not sure whether this made Claude work harder, but it certainly made for a pleasant collaboration.

**On honesty:** this story exists because the collaboration deserved to be presented accurately — not as "I built a tool with AI assistance" (which undersells Claude's role) and not as "AI built this for me" (which undersells mine). Claude brought the domain knowledge, the strategy, and the implementation. The human side brought the direction, the instincts, and the review. The bugs Claude introduced and the ones that were caught are both in this story because that's what actually happened. If you're reading this to understand what AI pair programming really feels like, the honest version is more useful than a polished one.

## What's next

- **Test on more source files** — the script has been validated on one source. Different codecs, sparse keyframes, and very short clips still need real-world testing
- **Deploy as an AI agent skill** — install `cut-sh-skill/` so a future Claude session can invoke `cut.sh` autonomously, closing the loop from "built with AI" to "run by AI"
- **Batch cutting support** — a natural extension: take a CSV of timestamps and cut multiple clips from the same source in one run

---

## Tools used

- `ffmpeg` — video cutting, encoding, concat
- `ffprobe` — keyframe scanning, codec detection, duration verification
- `bc` — float arithmetic for durations
- `awk` — float comparisons, field parsing
- `bash` — script orchestration, argument handling, timing
