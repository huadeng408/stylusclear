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

if [[ -n "$LIVE_CLIP" && -f "$LIVE_CLIP" ]]; then
  echo "[video] Normalizing 32s live screen recording (appended after 25s seg3_bridge -> 57s Scene 3)..."
  ffmpeg -y -i "$LIVE_CLIP" -t 32 -r 60 \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=#0B1020,setsar=1" \
    -c:v libx264 -profile:v high -level 4.2 -pix_fmt yuv420p -an "$TMP_DIR/live_32s.mp4" 2>"$TMP_DIR/ffmpeg.log" || { cat "$TMP_DIR/ffmpeg.log" >&2; exit 1; }
  LIVE_SEG="$TMP_DIR/live_32s.mp4"
elif [[ -f "$SEG3_LIVE_FALLBACK" ]]; then
  echo "[video] Using cloud-rendered 32s interactive fallback clip (no live clip supplied)..."
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

VF_ARGS=()
if [[ -f "$SUBS_ASS" ]]; then
  cp "$SUBS_ASS" "$TMP_DIR/subs.ass"
  VF_ARGS=(-vf "ass=$TMP_DIR/subs.ass")
fi

AUDIO_ARGS=(-c:a aac -b:a 256k -ar 48000 -ac 2)
if [[ "$AUDIO" == *.m4a ]]; then
  AUDIO_ARGS=(-c:a copy)
fi

echo "[video] Stitching 31+59+25+32+46 = 193.0s 1080p60 timeline + 48kHz -14.0 LUFS / -1.0 dBTP audio + burned-in ASS & mov_text..."
ffmpeg -y -f concat -safe 0 -i "$TMP_DIR/concat.txt" -i "$AUDIO" -i "$SUBS_SRT" \
  -map 0:v:0 -map 1:a:0 -map 2:s:0 \
  "${VF_ARGS[@]}" \
  -c:v libx264 -profile:v high -level 4.2 -crf 18 -preset medium -pix_fmt yuv420p -r 60 \
  "${AUDIO_ARGS[@]}" \
  -c:s mov_text -metadata:s:s:0 language=eng \
  -movflags +faststart "$OUT" 2>"$TMP_DIR/ffmpeg.log" || { cat "$TMP_DIR/ffmpeg.log" >&2; exit 1; }

echo "[video] Built $OUT successfully."
