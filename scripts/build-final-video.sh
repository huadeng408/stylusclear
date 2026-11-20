#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="${STYLUSCLEAR_VIDEO_KIT_DIR:-$ROOT/docs/assets/video_kit}"
if [[ ! -f "$KIT/seg1_hook.mp4" && -d "$ROOT/../project5-stylus-clearing-engine/docs/assets/video_kit" ]]; then
  KIT="$ROOT/../project5-stylus-clearing-engine/docs/assets/video_kit"
fi
OUT="${2:-$ROOT/docs/assets/demo-final.mp4}"
LIVE_CLIP="${1:-}"

command -v ffmpeg >/dev/null 2>&1 || { echo "[ERROR] ffmpeg required" >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "[ERROR] ffprobe required" >&2; exit 1; }

SEG1="$KIT/seg1_hook.mp4"                        # 31.0s (00:00 - 00:31)
SEG2="$KIT/seg2_workbench.mp4"                   # 59.0s (00:31 - 01:30)
SEG3="$KIT/seg3_bridge.mp4"                      # 25.0s (01:30 - 01:55)
SEG3_LIVE_FALLBACK="$KIT/seg3_live_fallback.mp4" # 32.0s (01:55 - 02:27)
SEG4="$KIT/seg4_rigor.mp4"                       # 46.0s (02:27 - 03:13)
AUDIO="$KIT/master_audio.m4a"
[[ -f "$AUDIO" ]] || AUDIO="$KIT/master_audio.wav"
SUBS_SRT="$KIT/subtitles.srt"
SUBS_ASS="$KIT/subtitles.ass"

for req in "$SEG1" "$SEG2" "$SEG3" "$SEG4" "$AUDIO" "$SUBS_SRT"; do
  if [[ ! -f "$req" ]]; then
    echo "[ERROR] Missing required video kit asset: $req (copy docs/assets/video_kit from Drive or set STYLUSCLEAR_VIDEO_KIT_DIR)" >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Copy/link segments into pure ASCII filenames inside $TMP_DIR to prevent single-quote/colon filtergraph errors
ln -sf "$(cd "$(dirname "$SEG1")" && pwd)/$(basename "$SEG1")" "$TMP_DIR/seg1.mp4"
ln -sf "$(cd "$(dirname "$SEG2")" && pwd)/$(basename "$SEG2")" "$TMP_DIR/seg2.mp4"
ln -sf "$(cd "$(dirname "$SEG3")" && pwd)/$(basename "$SEG3")" "$TMP_DIR/seg3.mp4"
ln -sf "$(cd "$(dirname "$SEG4")" && pwd)/$(basename "$SEG4")" "$TMP_DIR/seg4.mp4"
ln -sf "$(cd "$(dirname "$AUDIO")" && pwd)/$(basename "$AUDIO")" "$TMP_DIR/audio_in.${AUDIO##*.}"
cp "$SUBS_SRT" "$TMP_DIR/subs.srt"

if [[ -n "$LIVE_CLIP" && -f "$LIVE_CLIP" ]]; then
  echo "[video] Probing live recording clip ($LIVE_CLIP)..."
  python3 - "$LIVE_CLIP" <<'PYEOF'
import json, subprocess, sys
probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "stream=width,height:format=duration", "-of", "json", sys.argv[1]
], text=True))
streams = probe.get("streams") or []
if not streams:
    raise SystemExit("[ERROR] Live clip contains no video stream")
w, h = int(streams[0].get("width", 0)), int(streams[0].get("height", 0))
dur = float(probe.get("format", {}).get("duration", 0.0))
if w < 1280 or h < 720:
    raise SystemExit(f"[ERROR] Live clip resolution {w}x{h} below minimum 1280x720")
if dur < 30.0:
    raise SystemExit(f"[ERROR] Live clip duration {dur:.2f}s < 30.0s minimum (would desync 193s audio/subtitles)")
print(f"[video] Live clip pre-check OK: {w}x{h}, {dur:.2f}s")
PYEOF
  echo "[video] Normalizing live clip to exact 32.0s 1080p60 (tpad clone for 30-32s clips)..."
  ffmpeg -y -i "$LIVE_CLIP" -t 32 -r 60 \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=#0B1020,setsar=1,tpad=stop_mode=clone:stop_duration=2.5" \
    -c:v libx264 -profile:v high -level 4.2 -pix_fmt yuv420p -an "$TMP_DIR/live_32s.mp4" 2>"$TMP_DIR/ffmpeg.log" || { cat "$TMP_DIR/ffmpeg.log" >&2; exit 1; }
elif [[ -f "$SEG3_LIVE_FALLBACK" ]]; then
  echo "[video] Using cloud-rendered 32s interactive fallback clip (no live clip supplied)..."
  ln -sf "$(cd "$(dirname "$SEG3_LIVE_FALLBACK")" && pwd)/$(basename "$SEG3_LIVE_FALLBACK")" "$TMP_DIR/live_32s.mp4"
else
  echo "[ERROR] Missing live clip and fallback $SEG3_LIVE_FALLBACK" >&2
  exit 1
fi

cat > "$TMP_DIR/concat.txt" << 'EOF'
file 'seg1.mp4'
file 'seg2.mp4'
file 'seg3.mp4'
file 'live_32s.mp4'
file 'seg4.mp4'
EOF

VF_ARGS=()
if [[ -f "$SUBS_ASS" ]]; then
  cp "$SUBS_ASS" "$TMP_DIR/subs.ass"
  VF_ARGS=(-vf "ass=subs.ass")
fi

AUDIO_ARGS=(-c:a aac -b:a 256k -ar 48000 -ac 2)
if [[ "$AUDIO" == *.m4a ]]; then
  AUDIO_ARGS=(-c:a copy)
fi

OUT_ABS="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")"
mkdir -p "$(dirname "$OUT_ABS")"

echo "[video] Stitching 31+59+25+32+46 = 193.0s 1080p60 timeline + 48kHz audio + burned-in ASS & mov_text..."
(
  cd "$TMP_DIR"
  ffmpeg -y -f concat -safe 0 -i concat.txt -i "audio_in.${AUDIO##*.}" -i subs.srt \
    -map 0:v:0 -map 1:a:0 -map 2:s:0 \
    ${VF_ARGS[@]+"${VF_ARGS[@]}"} \
    -c:v libx264 -profile:v high -level 4.2 -crf 18 -preset medium -pix_fmt yuv420p -r 60 \
    ${AUDIO_ARGS[@]+"${AUDIO_ARGS[@]}"} \
    -c:s mov_text -metadata:s:s:0 language=eng \
    -movflags +faststart "$OUT_ABS" 2>ffmpeg.log || { cat ffmpeg.log >&2; exit 1; }
)

# Post-build ffprobe integrity gate
python3 - "$OUT_ABS" <<'PYEOF'
import json, subprocess, sys
probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", sys.argv[1]
], text=True))
streams = probe.get("streams") or []
v = next((s for s in streams if s.get("codec_type") == "video"), None)
a = next((s for s in streams if s.get("codec_type") == "audio"), None)
sub = next((s for s in streams if s.get("codec_type") == "subtitle"), None)
dur = float(probe.get("format", {}).get("duration", 0.0))
assert v and int(v["width"]) == 1920 and int(v["height"]) == 1080, f"Video not 1920x1080: {v}"
assert v.get("pix_fmt") == "yuv420p", f"Unexpected pix_fmt: {v.get('pix_fmt')}"
assert a is not None, "Missing audio stream"
assert sub is not None, "Missing mov_text subtitle stream"
assert 192.5 <= dur <= 193.5, f"Final video duration {dur:.2f}s outside [192.5, 193.5]s"
print(f"[video] Post-build ffprobe gate OK: 1920x1080 yuv420p, audio+subs present, duration={dur:.2f}s")
PYEOF

echo "[video] Built $OUT_ABS successfully."
