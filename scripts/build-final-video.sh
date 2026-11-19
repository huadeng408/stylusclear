#!/usr/bin/env bash
set -euo pipefail

# StylusClear v0.7.0 Auto-Mux Video Builder
# Concatenates pre-rendered 1080p60 cloud segments (seg1, seg2, [live_35s or seg3], seg4)
# with the -14 LUFS ducked English voiceover + CC0 BGM master track and burns/embeds SRT subtitles.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_DIR="$ROOT_DIR/docs/assets/video_kit"
LIVE_CLIP="${1:-}"
OUT_MP4="${2:-$ROOT_DIR/docs/assets/demo-final.mp4}"

SEG1="$KIT_DIR/seg1_hook.mp4"
SEG2="$KIT_DIR/seg2_workbench.mp4"
SEG3="$KIT_DIR/seg3_bridge.mp4"
SEG4="$KIT_DIR/seg4_rigor.mp4"
AUDIO="$KIT_DIR/master_audio.wav"
SRT="$KIT_DIR/subtitles.srt"

for f in "$SEG1" "$SEG2" "$SEG3" "$SEG4" "$AUDIO" "$SRT"; do
  if [[ ! -f "$f" ]]; then
    echo "[video] Missing pre-rendered asset: $f" >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BRIDGE_SEG="$SEG3"
if [[ -n "$LIVE_CLIP" && -f "$LIVE_CLIP" ]]; then
  echo "[video] Normalizing live 35s RPC/Explorer capture: $LIVE_CLIP"
  ffmpeg -y -i "$LIVE_CLIP" -t 35 -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,fps=60,format=yuv420p" -an -c:v libx264 -preset fast -crf 20 "$TMP_DIR/live_norm.mp4"
  BRIDGE_SEG="$TMP_DIR/live_norm.mp4"
else
  echo "[video] No live capture passed; padding seg3_bridge.mp4 (25s -> 60s) to match 165s master narration..."
  ffmpeg -y -stream_loop 2 -i "$SEG3" -t 60 -an -c:v libx264 -preset ultrafast -crf 20 "$TMP_DIR/seg3_60s.mp4"
  BRIDGE_SEG="$TMP_DIR/seg3_60s.mp4"
fi

cat > "$TMP_DIR/concat.txt" <<EOF
file '$SEG1'
file '$SEG2'
file '$BRIDGE_SEG'
file '$SEG4'
EOF

ffmpeg -y -f concat -safe 0 -i "$TMP_DIR/concat.txt" -i "$AUDIO" -i "$SRT"   -map 0:v:0 -map 1:a:0 -map 2:s:0   -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p   -c:a aac -b:a 192k   -c:s mov_text -metadata:s:s:0 language=eng   -shortest "$OUT_MP4"

echo "[video] Built 1080p60 final demo video: $OUT_MP4"
