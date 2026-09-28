#!/usr/bin/env python3
"""Long-running Holo1.5 grounding server, spoken to over stdio in JSON lines.

The app is Swift and the model is MLX/Python, so something has to bridge them.
A sidecar beats a per-query subprocess for one measured reason: loading the
4-bit weights costs ~0.5 s and holding them costs ~5.6 GB, and paying that on
every query would dominate a budget where the whole vision path is ~2.4 s.

The coordinate maths lives *here*, deliberately, next to the resize that
creates the problem. The server is handed a full frame and an optional crop; it
crops, applies Qwen2.5-VL's `smart_resize`, asks the model, then undoes both
transforms so the caller gets a point in the ORIGINAL frame's pixel space. Every
place that inverse has been re-derived elsewhere in this project, it has been a
bug.

Protocol — one JSON object per line each way:

    <- {"id":1,"image_png_b64":"iVBOR...","query":"the Play button","crop":[x,y,w,h]}
    <- {"id":1,"image":"/tmp/f.png","query":"the Play button"}   older callers
    -> {"id":1,"x":1131.0,"y":287.0,"ttft_ms":1610,"total_ms":1901,"tokens":980}

    -> {"ready":true,"inline_image":true,"model":"...","load_s":0.5}   once, at startup
    -> {"id":1,"error":"..."}                                            on failure

`inline_image` in the ready line tells the app it may send the frame as base64
PNG in `image_png_b64`, so the frame never exists as a file. A request with
only `image` (a path) is still read, for callers that predate that.

Nothing the sidecar sees is written to disk. The caller's frame is decoded once
and the crop/resize is handed to mlx_vlm as an in-memory PIL image. If an older
mlx_vlm only accepts paths, the image goes to a per-request temp file in the
private $TMPDIR, which is unlinked as soon as generation ends, including on
error and on SIGTERM. SIGKILL skips that `finally`, so each start also removes
holo-*.png files an earlier, killed run left behind.
"""

import base64
import contextlib
import io
import json
import math
import os
import signal
import sys
import tempfile
import time
from pathlib import Path

# The script may run from inside a signed .app bundle. Writing __pycache__
# next to it would modify the bundle and break its code signature.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).parent))

# A missing Pillow (or a broken holo_bench) is reported over the protocol as
# {"ready": false, "error": ...} from main(), not as a traceback on stderr
# that the app would have to scrape.
try:
    from PIL import Image
    from holo_bench import localization_prompt, parse_click, smart_resize
    IMPORT_ERROR = None
except Exception as e:  # noqa: BLE001
    Image = None
    IMPORT_ERROR = f"{type(e).__name__}: {e}"

# Earlier builds kept the last frame here for the sidecar's whole lifetime.
# It is removed at startup so an upgrade also cleans up what they left behind.
LEGACY_SCRATCH_NAME = ".holo_server_input.png"

# A temp frame lives for one generation, a few seconds. One older than this was
# left by a run that was SIGKILLed mid-query; a younger one may belong to a
# second sidecar (the bench beside the app) and is left alone.
STALE_FRAME_SECONDS = 300


def sweep_stale_frames(directory=None, now=None):
    """Delete holo-*.png temp frames a killed run left in `directory`."""
    directory = Path(directory or tempfile.gettempdir())
    now = time.time() if now is None else now
    for path in directory.glob("holo-*.png"):
        with contextlib.suppress(OSError):
            st = path.lstat()
            if st.st_uid == os.getuid() and now - st.st_mtime > STALE_FRAME_SECONDS:
                path.unlink()


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def accepts_pil_images():
    """True when the installed mlx_vlm takes a PIL image (0.6.15 does)."""
    try:
        from mlx_vlm.utils import load_image
        load_image(Image.new("RGB", (8, 8)))
        return True
    except Exception:  # noqa: BLE001
        return False


@contextlib.contextmanager
def model_image(image, in_memory):
    """Yield what stream_generate's `image=` takes, leaving nothing on disk.

    In memory when possible. Otherwise a private temp file (mode 0600, in
    $TMPDIR, not the home folder) that is unlinked in `finally`, so it exists
    only for the length of one generation.
    """
    if in_memory:
        yield image
        return
    fd, path = tempfile.mkstemp(prefix="holo-", suffix=".png")
    try:
        with os.fdopen(fd, "wb") as f:
            image.save(f, format="PNG")
        yield path
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(path)


def _exit_on_sigterm(signum, frame):  # noqa: ARG001
    # SystemExit unwinds through every `finally`, so a temp frame in flight is
    # still deleted when the app terminates the sidecar.
    raise SystemExit(0)


def main():
    model_path = sys.argv[1] if len(sys.argv) > 1 else str(
        Path.home() / "models/holo1.5-7b-4bit")
    max_tokens = 48

    if IMPORT_ERROR is not None:
        emit({"ready": False, "error": IMPORT_ERROR})
        return 1

    t0 = time.perf_counter()
    try:
        from mlx_vlm import load, stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template
        from mlx_vlm.utils import load_config
        model, processor = load(model_path)
        config = load_config(model_path)
    except Exception as e:  # noqa: BLE001
        emit({"ready": False, "error": f"{type(e).__name__}: {e}"})
        return 1
    signal.signal(signal.SIGTERM, _exit_on_sigterm)
    with contextlib.suppress(OSError):
        (Path(model_path).parent / LEGACY_SCRATCH_NAME).unlink(missing_ok=True)
    sweep_stale_frames()
    in_memory = accepts_pil_images()

    emit({"ready": True, "inline_image": True, "model": model_path,
          "load_s": round(time.perf_counter() - t0, 2)})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        if req.get("op") == "quit":
            break

        rid = req.get("id")
        try:
            if "image_png_b64" in req:
                source = io.BytesIO(base64.b64decode(req["image_png_b64"], validate=True))
            else:
                source = req["image"]
            with Image.open(source) as src:
                image = src.convert("RGB")

            # Crop first, resize second. Doing it the other way round throws
            # away the resolution that makes small targets findable — Phase 0
            # measured native-res cropping at 3x the accuracy of downscaling
            # for the same token budget.
            ox, oy = 0.0, 0.0
            crop = req.get("crop")
            if crop:
                cx, cy, cw, ch = crop
                x0 = max(0, int(cx))
                y0 = max(0, int(cy))
                x1 = min(image.width, int(cx + cw))
                y1 = min(image.height, int(cy + ch))
                if x1 - x0 >= 8 and y1 - y0 >= 8:
                    image = image.crop((x0, y0, x1, y1))
                    ox, oy = float(x0), float(y0)

            w, h = image.size
            budget = req.get("max_pixels") or 3686400
            rh, rw = smart_resize(h, w, max_pixels=budget)
            resized = image.resize((rw, rh), Image.Resampling.LANCZOS)

            prompt = apply_chat_template(
                processor, config, localization_prompt(req["query"]), num_images=1
            )
            start = time.perf_counter()
            ttft, text = None, ""
            with model_image(resized, in_memory) as model_input:
                for chunk in stream_generate(model, processor, prompt,
                                             image=model_input,
                                             max_tokens=req.get("max_tokens", max_tokens),
                                             temperature=0.0):
                    if ttft is None:
                        ttft = time.perf_counter() - start
                    text += chunk.text
            total = time.perf_counter() - start

            click = parse_click(text)
            if click is None:
                emit({"id": rid, "error": "model returned no coordinates",
                      "raw": text[:160]})
                continue

            # Undo resize, then undo crop — back into the original frame.
            x = click[0] * (w / rw) + ox
            y = click[1] * (h / rh) + oy
            emit({"id": rid, "x": x, "y": y,
                  "ttft_ms": round((ttft or 0) * 1000, 1),
                  "total_ms": round(total * 1000, 1),
                  "tokens": (rw * rh) // 784,
                  "encoder_px": [rw, rh]})
        except Exception as e:  # noqa: BLE001
            emit({"id": rid, "error": f"{type(e).__name__}: {e}"})

    return 0


if __name__ == "__main__":
    sys.exit(main())
