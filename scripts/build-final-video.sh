#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/assets/video_kit"
OUT="${2:-$ROOT/docs/assets/demo-final.mp4}"
LIVE_CLIP="${1:-}"

command -v ffmpeg >/dev/null 2>&1 || { echo "[ERROR] ffmpeg required" >&2; exit 1; }

SEG1="$KIT/seg1_hook.mp4"          # 31.0s (00:00 - 00:31)
SEG2="$KIT/seg2_workbench.mp4"     # 59.0s (00:31 - 01:30)
SEG3="$KIT/seg3_bridge.mp4"        # 25.0s (01:30 - 01:55)
SEG3_LIVE_FALLBACK="$KIT/seg3_live_fallback.mp4" # 32.0s (01:55 - 02:27)
SEG4="$KIT/seg4_rigor.mp4"         # 46.0s (02:27 - 03:13)
AUDIO="$KIT/master_audio.wav"
[ -f "$AUDIO" ] || AUDIO="$KIT/master_audio.m4a"      # 193.0s (-14.0 LUFS, 48kHz stereo)
SUBS_SRT="$KIT/subtitles.srt"
SUBS_ASS="$KIT/subtitles.ass"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -n "$LIVE_CLIP" && -f "$LIVE_CLIP" ]]; then
  echo "[video] Normalizing 32s live screen recording (appended after 25s seg3_bridge -> 60s Scene 3)..."
  ffmpeg -y -i "$LIVE_CLIP" -t 32 -r 60     -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=#0B1020,setsar=1"     -c:v libx264 -profile:v high -level 4.2 -pix_fmt yuv420p -an "$TMP_DIR/live_35s.mp4" >/dev/null 2>&1
  LIVE_SEG="$TMP_DIR/live_35s.mp4"
elif [[ -f "$SEG3_LIVE_FALLBACK" ]]; then
  echo "[video] Using cloud-rendered 35s interactive fallback clip (no live clip supplied)..."
  LIVE_SEG="$SEG3_LIVE_FALLBACK"
else
  echo "[ERROR] Missing live clip and fallback $SEG3_LIVE_FALLBACK" >&2
  exit 1
fi

cat > "$TMP_DIR/concat.txt" << EOF
file '$SEG1'
file '$SEG2'
file '$SEG3'
file '$LIVE_SEG'
file '$SEG4'
EOF

echo "[video] Concatenating 31+59+25+32+46 = 193.0s 1080p60 timeline + 48kHz -14 LUFS audio + subtitles..."
ffmpeg -y -f concat -safe 0 -i "$TMP_DIR/concat.txt" -i "$AUDIO" -i "$SUBS_SRT"   -map 0:v:0 -map 1:a:0 -map 2:s:0   -c:v libx264 -profile:v high -level 4.2 -crf 18 -preset medium -pix_fmt yuv420p   -c:a aac -b:a 192k -ar 48000 -ac 2   -c:s mov_text -metadata:s:s:0 language=eng   -movflags +faststart -shortest "$OUT" >/dev/null 2>&1

echo "[video] Built $OUT successfully."
