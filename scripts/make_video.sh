#!/usr/bin/env bash
#
# make_video.sh: cut Thataway's promo film, its web copy, its poster and the README loop from
# the raw takes that scripts/make_media.sh records from the Debug promo stage.
#
#   scripts/make_video.sh                          # raw takes from build/media-raw
#   scripts/make_video.sh --raw-dir /path/to/raw   # wherever make_media.sh --raw-dir wrote them
#   scripts/make_video.sh --build-dir /tmp/tw      # where the renderer binary goes
#   scripts/make_video.sh --crf 20 --crf-web 28    # lighter encodes
#
# Inputs:
#   <raw>/{hero,uncertain,excluded,lesson,watchme}.mov + .json   3072x1728 masters and timelines
#   docs/media/icon.png                                          the icon, for the cards and poster
#
# Outputs (the launch.md 4.1 media contract):
#   docs/media/thataway-promo.mp4         1920x1080, about 46.5 s, 30 fps CFR, H.264 High, yuv420p,
#                                         BT.709, +faststart, silent, 25 MB max
#   docs/media/thataway-promo-web.mp4     the same cut at a higher CRF, 10 MB max (GitHub's
#                                         inline player upload limit)
#   docs/media/thataway-promo-poster.jpg  1920x1080, 2 MB max
#   docs/media/thataway-hero.gif          1280x868, 25 fps, about 13 s loop whose last frame is its first, 8 MB max
#
# The picture is composed by scripts/make_video.swift (Core Image + CoreText, piped to
# ffmpeg/libx264); its edit decision list (clips, camera keys, captions, cards) is in that file
# under "The edit". The film is silent: there is no licensed music, and captions carry the story.
#
# The GIF is the hero query and then the uncertain query, cropped to the action (the bar, the
# resting mouse the takes log, Share and Link access) and scaled to 1280 px wide by
# make_video.swift (lossless ffv1). Here it gets a temporal denoise, so the still
# wallpaper does not change every frame. Its last frame cross-fades into its first, so the loop
# has no seam. One palette covers the whole loop (stats_mode=full), and ordered dithering keeps
# identical frames identical. gifsicle (brew install gifsicle) squeezes it only if it is
# over budget.
#
# Requires ffmpeg and ffprobe (brew install ffmpeg) and the Xcode Swift toolchain.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW="$ROOT/build/media-raw"
BUILD="$ROOT/build"
MEDIA="$ROOT/docs/media"
FPS=30
CRF=18
CRF_WEB=27
GIF_FPS=25
FFMPEG="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"
FFPROBE="$(command -v ffprobe || echo /opt/homebrew/bin/ffprobe)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-dir) RAW="$2"; shift ;;
    --build-dir) BUILD="$2"; shift ;;
    --fps) FPS="$2"; shift ;;
    --crf) CRF="$2"; shift ;;
    --crf-web) CRF_WEB="$2"; shift ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -x "$FFMPEG" && -x "$FFPROBE" ]] || { echo "error: ffmpeg/ffprobe not found (brew install ffmpeg)" >&2; exit 1; }
for take in hero uncertain excluded lesson watchme; do
  [[ -f "$RAW/$take.mov" && -f "$RAW/$take.json" ]] || {
    echo "error: missing $RAW/$take.mov or .json; run scripts/make_media.sh --footage-only first" >&2; exit 1; }
done
[[ -f "$MEDIA/icon.png" ]] || { echo "error: missing $MEDIA/icon.png; run scripts/make_media.sh --stills-only" >&2; exit 1; }
mkdir -p "$BUILD" "$MEDIA"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building the renderer"
swiftc -O -suppress-warnings -o "$BUILD/make_video" "$ROOT/scripts/make_video.swift"

echo "==> Rendering the film, its web copy, the poster and the loop's frames"
"$BUILD/make_video" \
  --raw "$RAW" --icon "$MEDIA/icon.png" --ffmpeg "$FFMPEG" \
  --fps "$FPS" --crf "$CRF" --crf-web "$CRF_WEB" --gif-fps "$GIF_FPS" \
  --out "$MEDIA/thataway-promo.mp4" --out-web "$MEDIA/thataway-promo-web.mp4" \
  --poster "$MEDIA/thataway-promo-poster.jpg" --gif "$WORK/hero.mkv"

size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }

# The web copy must fit GitHub's 10 MB upload limit. If this cut ever outgrows it at the chosen
# CRF, re-encode it from the full-quality film two CRF steps at a time.
while (( $(size "$MEDIA/thataway-promo-web.mp4") > 10000000 )); do
  CRF_WEB=$((CRF_WEB + 2))
  (( CRF_WEB <= 35 )) || { echo "error: the web copy is still over 10 MB at CRF 35" >&2; exit 1; }
  echo "==> Web copy over 10 MB; re-encoding at CRF $CRF_WEB"
  "$FFMPEG" -v error -y -i "$MEDIA/thataway-promo.mp4" \
    -c:v libx264 -profile:v high -preset slower -crf "$CRF_WEB" -tune film -g $((FPS * 2)) -bf 3 \
    -pix_fmt yuv420p -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
    -movflags +faststart -tag:v avc1 -an "$MEDIA/thataway-promo-web.mp4"
done

echo "==> Quantizing the README loop"
FRAMES=$("$FFPROBE" -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$WORK/hero.mkv")
LENGTH=$(python3 -c "print($FRAMES / $GIF_FPS)")
XFADE=0.5
OFFSET=$(python3 -c "print(round($LENGTH - $XFADE, 3))")
# [head] is the loop's first frame, denoised exactly as [main]'s first frame is (a fresh hqdn3d on
# the same frame), then held; the end of [main] cross-fades into it, so the last frame is the first.
"$FFMPEG" -v error -y -i "$WORK/hero.mkv" -filter_complex "
  [0:v]format=gbrp,split[m][f];
  [m]hqdn3d=0:0:4:4,setpts=PTS-STARTPTS[main];
  [f]trim=end_frame=1,hqdn3d=0:0:4:4,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=0.6[head];
  [main][head]xfade=transition=fade:duration=$XFADE:offset=$OFFSET,format=rgb24,split[a][b];
  [a]palettegen=max_colors=256:stats_mode=full[p];
  [b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 "$MEDIA/thataway-hero.gif"
if (( $(size "$MEDIA/thataway-hero.gif") > 8000000 )); then
  if command -v gifsicle >/dev/null 2>&1; then
    echo "==> GIF over 8 MB; gifsicle -O3 --lossy=30"
    gifsicle -O3 --lossy=30 "$MEDIA/thataway-hero.gif" -o "$WORK/lossy.gif"
    mv "$WORK/lossy.gif" "$MEDIA/thataway-hero.gif"
  else
    echo "warning: the GIF is over 8 MB and gifsicle is not installed (brew install gifsicle)" >&2
  fi
fi

echo "==> Checking budgets"
FAIL=0
check() { # file max_bytes
  local s; s=$(size "$1")
  printf '  %-28s %6.2f MB' "$(basename "$1")" "$(python3 -c "print($s / 1e6)")"
  if (( s > $2 )); then echo "  OVER BUDGET ($(python3 -c "print($2 / 1e6)") MB)"; FAIL=1; else echo; fi
}
check "$MEDIA/thataway-promo.mp4" 25000000
check "$MEDIA/thataway-promo-web.mp4" 10000000
check "$MEDIA/thataway-promo-poster.jpg" 2000000
check "$MEDIA/thataway-hero.gif" 8000000
for f in thataway-promo.mp4 thataway-promo-web.mp4 thataway-promo-poster.jpg thataway-hero.gif; do
  printf '  %-28s ' "$f"
  "$FFPROBE" -v error -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,pix_fmt,color_space,avg_frame_rate:format=duration \
    -of compact=p=0:nk=0 "$MEDIA/$f" | tr '\n' ' '
  echo
done
(( FAIL == 0 )) || { echo "error: a file is over its budget" >&2; exit 1; }
echo "==> Done"
