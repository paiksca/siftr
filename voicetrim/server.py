"""HTTP API: POST an audio file to /clean, get back cleaned audio and a transcript."""

import argparse
import re
import tempfile
import threading
import uuid
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse

from .audio import save
from .pipeline import clean

OUT = Path(tempfile.gettempdir()) / "voicetrim"
MAX_BYTES = 25 * 1024 * 1024
_lock = threading.Lock()  # one model, one request at a time

app = FastAPI(title="voicetrim")


def _clean_locked(*args, **kwargs):
    with _lock:
        return clean(*args, **kwargs)


@app.post("/clean")
async def clean_audio(
    audio: UploadFile = File(...),
    language: str | None = Form(None),
    denoise: bool = Form(True),
):
    data = await audio.read()
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "audio is larger than 25 MB")
    OUT.mkdir(exist_ok=True)
    key = uuid.uuid4().hex
    suffix = re.sub(r"[^.\w]", "", Path(audio.filename or "").suffix)[:8] or ".m4a"
    src = OUT / f"{key}-in{suffix}"
    src.write_bytes(data)
    try:
        result = await run_in_threadpool(_clean_locked, src, language=language, denoise=denoise)
    except Exception as e:
        raise HTTPException(422, f"could not process audio: {e}") from e
    finally:
        src.unlink(missing_ok=True)
    save(OUT / f"{key}.m4a", result.samples, result.rate)
    return {
        "audio_url": f"/audio/{key}.m4a",
        "transcript": result.transcript,
        "marked": result.marked,
        "removed": result.plan.removed,
        "pauses_shortened": result.plan.pauses_shortened,
        "before": round(result.before, 2),
        "after": round(result.after, 2),
    }


@app.get("/audio/{name}")
def get_audio(name: str):
    if not re.fullmatch(r"[0-9a-f]{32}\.m4a", name) or not (OUT / name).exists():
        raise HTTPException(404)
    return FileResponse(OUT / name, media_type="audio/mp4")


def main(argv=None):
    import uvicorn

    p = argparse.ArgumentParser(description="Serve the voicetrim API.")
    p.add_argument("--host", default="127.0.0.1", help="0.0.0.0 to accept phones on your network")
    p.add_argument("--port", type=int, default=8000)
    args = p.parse_args(argv)
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
