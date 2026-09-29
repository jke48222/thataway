#!/usr/bin/env bash
#
# make_media.sh: regenerate Thataway's stills, icon, social preview and raw footage from the
# app's own promo stage, end to end.
#
#   scripts/make_media.sh                       # stills + raw footage
#   scripts/make_media.sh --stills-only
#   scripts/make_media.sh --footage-only [--scenes "hero lesson"]
#   scripts/make_media.sh --raw-dir /path/to/raw --build-dir /path/to/scratch
#   scripts/make_media.sh --footage-only --scenes uncertain --fps 30   # when the display will not give 60
#
# The promo stage lives in Sources/ThatawayApp/Promo and is compiled into Debug builds only. It
# is opened by an explicit launch flag and returns before any of the app's services start: no
# hotkey, no accessibility reads, no status item, no permission prompt, no config files. It shows
# the real PointerLayer and a replica of the command bar over a fictional "Studio" window, and
# the shortlist, rings, lesson steps and Watch me file come from the shipping resolver, fusion,
# lesson and inference code run on that window's made-up tree.
#
# Stills (drawn off screen with cacheDisplay; no capture, no permission) go into docs/media:
#   docs/media/screens/{point-exact,point-uncertain,privacy-excluded,lesson-step,watch-me}.png
#                                        3072x1728, the 1536x864 pt stage at 2x
#   docs/media/icon.png                  512x512, the approved app icon
#   docs/media/favicon-{32,16}.png        the hinted small sizes, for the site
#   docs/media/social-preview.png        1280x640, opaque
# oxipng squeezes the PNGs losslessly, and pngquant quantizes any still left over 700 KB
# (brew install oxipng pngquant).
#
# Raw footage goes to --raw-dir (default build/media-raw, gitignored), one take per scene:
#   <scene>.mov         master, 3072x1728 at 60 fps (or --fps) CFR, H.264, BT.709
#   <scene>.json        the scene's timeline in movie time ("cut" marks are where to cut)
#   <scene>-1080p.mp4   1920x1080 proxy at the same rate (yuv420p, BT.709, +faststart), needs ffmpeg
#   manifest.json       every clip, its duration, key timestamps and the brand caption
#
# Footage is recorded with ScreenCaptureKit from a stage window that sits behind the desktop,
# so the screen is never taken over and nothing is visible while it records. The shell running
# this needs Screen Recording permission; the recorder only checks it and stops if it is off.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
RAW="$ROOT/build/media-raw"
MEDIA="$ROOT/docs/media"
ALL_SCENES="hero uncertain excluded lesson watchme"
SCENES="$ALL_SCENES"
DO_STILLS=1
DO_FOOTAGE=1
FPS=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stills-only) DO_FOOTAGE=0 ;;
    --footage-only) DO_STILLS=0 ;;
    --raw-dir) RAW="$2"; shift ;;
    --build-dir) BUILD_DIR="$2"; shift ;;
    --scenes) SCENES="$2"; shift ;;
    --fps) FPS="$2"; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

echo "==> Building ThatawayApp (Debug; the promo stage is Debug-only)"
swift build --package-path "$ROOT" --scratch-path "$BUILD_DIR" --product ThatawayApp
BINARY="$BUILD_DIR/debug/ThatawayApp"

if [[ "$DO_STILLS" == "1" ]]; then
  echo "==> Rendering stills"
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT
  "$BINARY" --promo-stills "$STAGING" >/dev/null
  # Lossless first: the wallpaper's gradients band under a 256-colour palette. pngquant runs only
  # on a file still over the 700 KB budget afterwards.
  for png in "$STAGING"/screens/*.png "$STAGING/social-preview.png" "$STAGING/icon.png" "$STAGING/favicon-32.png" "$STAGING/favicon-16.png"; do
    if command -v oxipng >/dev/null 2>&1; then oxipng --quiet -o 4 --strip safe "$png"; fi
    if [[ "$(stat -f %z "$png")" -gt 700000 ]] && command -v pngquant >/dev/null 2>&1; then
      pngquant --force --skip-if-larger --quality 90-100 --speed 1 --output "$png" -- "$png" || true
      if command -v oxipng >/dev/null 2>&1; then oxipng --quiet -o 4 --strip safe "$png"; fi
    fi
  done
  mkdir -p "$MEDIA/screens"
  cp "$STAGING"/screens/*.png "$MEDIA/screens/"
  cp "$STAGING/social-preview.png" "$STAGING/icon.png" "$STAGING/favicon-32.png" "$STAGING/favicon-16.png" "$MEDIA/"
  for f in "$MEDIA"/screens/*.png "$MEDIA/social-preview.png" "$MEDIA/icon.png" "$MEDIA/favicon-32.png" "$MEDIA/favicon-16.png"; do
    printf '    %-48s %s bytes\n' "${f#"$ROOT"/}" "$(stat -f %z "$f")"
  done
fi

if [[ "$DO_FOOTAGE" == "1" ]]; then
  echo "==> Building the recorder"
  RECORDER="$BUILD_DIR/record_promo"
  swiftc -O -suppress-warnings -o "$RECORDER" "$ROOT/scripts/media/record_promo.swift"
  mkdir -p "$RAW"
  for scene in $SCENES; do
    echo "==> Recording $scene"
    "$RECORDER" --app "$BINARY" --scene "$scene" --out "$RAW/$scene.mov" --tail 0.2 --fps "$FPS"
    if command -v ffmpeg >/dev/null 2>&1; then
      ffmpeg -v error -y -i "$RAW/$scene.mov" \
        -vf "scale=1920:1080:flags=lanczos,format=yuv420p" -r "$FPS" \
        -c:v libx264 -profile:v high -preset slow -crf 14 \
        -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
        -movflags +faststart -an "$RAW/$scene-1080p.mp4"
    fi
  done

  # Every take in the raw folder, including ones kept from an earlier run.
  echo "==> Writing $RAW/manifest.json"
  python3 - "$RAW" $ALL_SCENES <<'PY'
import json, os, sys
raw, scenes = sys.argv[1], sys.argv[2:]
# The brand caption for each scene (the same lines as the stills).
captions = {
    # The bar closes before the pointer leaves, so no frame has both the shortlist and the ring.
    "hero": "Type “the Share button” and the pointer arcs from the mouse to it with a solid ring.",
    "uncertain": "When the answer is a guess, the ring is dashed amber and the caption ends in a question mark.",
    "excluded": "A window titled “Online Banking” gets no pointer, and the bar says why: it is excluded, and it was never read.",
    "lesson": "A lesson dims everything but step 2 and moves on only when the settings sheet actually opens.",
    "watchme": "Watch me turns three clicks into a lesson of control names, ready to replay from the Teach Me menu.",
}
clips = []
for scene in scenes:
    path = os.path.join(raw, scene + ".json")
    if not os.path.exists(path):
        continue
    with open(path) as handle:
        clip = json.load(handle)
    clip["master"] = scene + ".mov"
    clip.pop("file", None)
    proxy = scene + "-1080p.mp4"
    if os.path.exists(os.path.join(raw, proxy)):
        clip["proxy1080p"] = proxy
    clip["caption"] = captions.get(scene)
    clips.append(clip)
manifest = {
    "description": "Raw takes of Thataway's promo stage (Debug build, --promo). The pointer, ring, caption pill, lesson scrim and step badge are the app's real PointerLayer; the command bar is a replica of CommandBar's content; the Studio and Browser windows are fictional. Times are seconds in each clip. 'sceneStart' is when the scene begins. Earlier frames are a still pre-roll handle. 'marks' are key moments. Every 'cut' mark is where a person clicks off camera: cut there and never show the jump.",
    "stage": {"points": [1536, 864], "masterPixels": [3072, 1728], "proxyPixels": [1920, 1080], "fps": "per clip (see each clip's fps)"},
    "rules": [
        "The person's mouse never moves on camera and nothing is clicked on camera.",
        "Captions use the brand lines above; no music.",
    ],
    "clips": clips,
}
with open(os.path.join(raw, "manifest.json"), "w") as handle:
    json.dump(manifest, handle, indent=2, ensure_ascii=False)
PY
  echo "==> Footage written to $RAW"
fi
