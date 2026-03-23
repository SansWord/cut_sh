# cut.sh — Examples

A reference for mapping natural language user requests to `cut.sh` arguments.

---

## Simple cuts

**User:** "Cut my video from 13 minutes 38 seconds to 1 hour 6 minutes 50 seconds"
```bash
./cut.sh input.mp4 0:13:38 1:06:50
```

**User:** "I want the part of the video between 00:05:00 and 00:10:30"
```bash
./cut.sh input.mp4 0:05:00 0:10:30
```

**User:** "Extract the first 2 minutes of this video"
```bash
./cut.sh input.mp4 0:00:00 0:02:00
```

**User:** "Clip from 45 seconds in to 1 minute 30 seconds"
```bash
./cut.sh input.mp4 0:00:45 0:01:30
```

---

## With named output

**User:** "Cut from 10:00 to 15:00 and save it as highlights.mp4"
```bash
./cut.sh input.mp4 0:10:00 0:15:00 highlights.mp4
```

**User:** "Extract the intro (0:00 to 0:30) and save to ./clips/intro.mp4"
```bash
./cut.sh input.mp4 0:00:00 0:00:30 ./clips/intro.mp4
```

---

## Argument extraction rules

When the user provides a request, extract arguments as follows:

### Source file
- Look for a filename or path mentioned in the request or provided as an upload
- If ambiguous, ask: "Which file would you like to cut?"

### Start and end timestamps
- Convert any natural language time to `h:mm:ss`:
  - "13 minutes 38 seconds" → `0:13:38`
  - "1 hour 6 minutes" → `1:06:00`
  - "45 seconds" → `0:00:45`
  - "the beginning" → `0:00:00`
- If only one timestamp is given, ask for the other
- If end is before start, flag it and ask the user to confirm

### Output filename
- If the user specifies a name, use it
- If the user specifies a folder, append the source filename: `./clips/input.mp4`
- If not specified, omit — the script defaults to `./output/<source_filename>`

### Mode
- Default to parallel (omit `--sequential`)
- Only add `--sequential` if the user explicitly asks for it or mentions slow performance

---

## Edge cases

**User gives only a duration instead of end time:**
> "Cut the first 5 minutes"

→ Compute end = start + duration:
```bash
./cut.sh input.mp4 0:00:00 0:05:00
```

**User gives timestamps without hours:**
> "From 5:30 to 12:45"

→ Interpret as `m:ss` and convert to `h:mm:ss`:
```bash
./cut.sh input.mp4 0:05:30 0:12:45
```

**User provides a source file that doesn't exist:**
→ Do not run the script. Ask the user to confirm the file path before proceeding.

**User asks for multiple cuts from the same file:**
> "Cut 0:05:00–0:10:00 and also 0:20:00–0:25:00"

→ Run the script twice with different output names:
```bash
./cut.sh input.mp4 0:05:00 0:10:00 clip1.mp4
./cut.sh input.mp4 0:20:00 0:25:00 clip2.mp4
```

---

## What this skill does NOT handle

- Merging multiple clips into one file — use ffmpeg concat directly
- Format conversion (MP4 → MKV, etc.) — use ffmpeg directly
- Adding subtitles, watermarks, or overlays — out of scope
- Audio-only extraction — use ffmpeg `-vn` directly
- Re-encoding to a different codec or quality — use ffmpeg directly
