"""
MacVoxCPM Python sidecar.

A small FastAPI server that the SwiftUI front-end controls via localhost.
Exposes:

  GET  /health                -> liveness, no model required
  GET  /status                -> model load state, download progress, last error
  POST /load                  -> kick off (or restart) the background loader
  POST /generate              -> synthesize a wav file at the given output path
  POST /shutdown              -> graceful shutdown so the parent can quit cleanly

The model is loaded lazily on a background thread so the server can answer
/health and /status while ~5 GB of weights stream in from Hugging Face.
"""

from __future__ import annotations

import argparse
import logging
import os
import pathlib
import re
import signal
import sys
import threading
import time
import traceback
from contextlib import asynccontextmanager
from typing import Any, Optional

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Logging — also tee'd to stdout so the Swift parent can scrape progress lines
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s | %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("macvoxcpm")


# ---------------------------------------------------------------------------
# State container — single source of truth for the loader thread + endpoints
# ---------------------------------------------------------------------------

class LoaderState:
    # Approx total size of openbmb/VoxCPM2 on disk in bytes — used to compute
    # a believable percentage while snapshot_download streams.
    EXPECTED_MODEL_BYTES = 5_320_000_000  # ~4.96 GB headroom for index + tokenizer

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.stage: str = "idle"        # idle | downloading | loading | ready | error
        self.message: str = ""
        self.error: Optional[str] = None
        self.progress: float = 0.0      # 0.0 — 1.0
        self.bytes_downloaded: int = 0
        self.bytes_total: int = self.EXPECTED_MODEL_BYTES
        self.model_id: str = "openbmb/VoxCPM2"
        self.model_local_dir: Optional[str] = None
        self.device: str = "auto"
        self.model: Optional[Any] = None
        self.sample_rate: int = 48_000
        self.thread: Optional[threading.Thread] = None

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "stage": self.stage,
                "message": self.message,
                "error": self.error,
                "progress": round(self.progress, 4),
                "bytes_downloaded": self.bytes_downloaded,
                "bytes_total": self.bytes_total,
                "model_id": self.model_id,
                "device": self.device,
                "sample_rate": self.sample_rate,
                "ready": self.model is not None,
            }

    def set(self, **kw: Any) -> None:
        with self.lock:
            for k, v in kw.items():
                setattr(self, k, v)


STATE = LoaderState()


# ---------------------------------------------------------------------------
# Model loader — runs on a background thread
# ---------------------------------------------------------------------------

def _models_root() -> pathlib.Path:
    # Caller sets MACVOXCPM_MODELS_DIR; fall back to ~/.cache/macvoxcpm.
    root = os.environ.get("MACVOXCPM_MODELS_DIR") or os.path.expanduser(
        "~/.cache/macvoxcpm/models"
    )
    p = pathlib.Path(root)
    p.mkdir(parents=True, exist_ok=True)
    return p


def _model_dir_for(model_id: str) -> pathlib.Path:
    safe = model_id.replace("/", "__")
    return _models_root() / safe


def _measure_dir_bytes(p: pathlib.Path) -> int:
    total = 0
    try:
        for root, _dirs, files in os.walk(p):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
    except OSError:
        pass
    return total


def _progress_watcher(target_dir: pathlib.Path, stop: threading.Event) -> None:
    """Poll the snapshot dir size; surface a smooth percentage via STATE."""
    while not stop.is_set():
        size = _measure_dir_bytes(target_dir)
        with STATE.lock:
            STATE.bytes_downloaded = size
            if STATE.bytes_total > 0:
                STATE.progress = min(0.999, size / STATE.bytes_total)
        stop.wait(0.75)


def _do_load(model_id: str, device: str) -> None:
    try:
        STATE.set(stage="downloading", message=f"Downloading {model_id} from Hugging Face…",
                  progress=0.0, bytes_downloaded=0, error=None)

        from huggingface_hub import snapshot_download  # imported lazily

        target = _model_dir_for(model_id)
        stop = threading.Event()
        watcher = threading.Thread(
            target=_progress_watcher, args=(target, stop), daemon=True
        )
        watcher.start()

        local_dir = snapshot_download(
            repo_id=model_id,
            local_dir=str(target),
            # voxcpm needs the on-disk layout; symlinks are fine on macOS.
            local_dir_use_symlinks=False if hasattr(snapshot_download, "__wrapped__") else "auto",
            max_workers=4,
            tqdm_class=None,
        )
        stop.set()
        watcher.join(timeout=1.0)

        STATE.set(
            stage="loading",
            message="Loading model into memory… (Apple Silicon: MPS)" if device != "cpu"
                    else "Loading model into memory… (CPU)",
            progress=1.0,
            bytes_downloaded=_measure_dir_bytes(target),
            model_local_dir=local_dir,
        )

        from voxcpm import VoxCPM  # imported lazily

        # voxcpm picks device automatically. We let the user force CPU via env.
        if device == "cpu":
            os.environ.setdefault("VOXCPM_DEVICE", "cpu")

        model = VoxCPM.from_pretrained(local_dir, load_denoiser=False)

        sr = getattr(getattr(model, "tts_model", None), "sample_rate", 48_000)
        STATE.set(stage="ready", message="Model ready.", model=model, sample_rate=int(sr))
        log.info("Model %s loaded. sample_rate=%s", model_id, sr)

    except Exception as exc:  # noqa: BLE001 — surface everything to UI
        tb = traceback.format_exc()
        log.exception("Loader failed")
        STATE.set(stage="error", error=f"{exc.__class__.__name__}: {exc}\n\n{tb}",
                  message="Model load failed.")


def start_loader(model_id: Optional[str] = None, device: Optional[str] = None) -> None:
    with STATE.lock:
        if STATE.thread is not None and STATE.thread.is_alive():
            return
        if model_id:
            STATE.model_id = model_id
        if device:
            STATE.device = device
        t = threading.Thread(
            target=_do_load, args=(STATE.model_id, STATE.device), daemon=True
        )
        STATE.thread = t
    t.start()


# ---------------------------------------------------------------------------
# Request / response schemas
# ---------------------------------------------------------------------------

class GenerateRequest(BaseModel):
    text: str = Field(..., description="Text to synthesize. May start with "
                                      "'(description)' for Voice Design.")
    mode: str = Field("default", description="default | design | clone | ultimate")

    # Cloning inputs
    reference_audio: Optional[str] = None
    prompt_audio: Optional[str] = None
    prompt_text: Optional[str] = None

    # Generation knobs
    cfg_value: float = 2.0
    inference_timesteps: int = 10
    seed: Optional[int] = None

    # Output
    output_path: str
    output_format: str = "wav"   # wav | flac | mp3 (mp3 requires ffmpeg, not bundled in v1)
    normalize: bool = False


class GenerateResponse(BaseModel):
    output_path: str
    duration_seconds: float
    sample_rate: int
    elapsed_seconds: float


class LoadRequest(BaseModel):
    model_id: Optional[str] = None
    device: Optional[str] = None  # auto | cpu | mps


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Kick off the loader as soon as the server is up.
    start_loader()
    yield


app = FastAPI(title="MacVoxCPM Sidecar", lifespan=lifespan)


@app.get("/health")
def health() -> dict:
    return {"ok": True, "pid": os.getpid()}


@app.get("/status")
def status() -> dict:
    return STATE.snapshot()


@app.post("/load")
def load(req: LoadRequest) -> dict:
    start_loader(model_id=req.model_id, device=req.device)
    return STATE.snapshot()


_GEN_LOCK = threading.Lock()


def _set_seed(seed: Optional[int]) -> None:
    if seed is None:
        return
    try:
        import random as _random
        _random.seed(seed)
        np.random.seed(seed)
        import torch  # type: ignore
        torch.manual_seed(seed)
        if torch.backends.mps.is_available():
            torch.mps.manual_seed(seed)
    except Exception:  # noqa: BLE001
        log.warning("seed seeding partially failed", exc_info=True)


def _prepare_text(mode: str, text: str) -> str:
    # If the caller already wrapped a description in parens at the start,
    # we leave it alone. design mode is just a hint for the front-end.
    text = text.strip()
    if mode == "design" and not text.startswith("("):
        raise HTTPException(400, "design mode requires text starting with '(description)'")
    return text


@app.post("/generate", response_model=GenerateResponse)
def generate(req: GenerateRequest) -> GenerateResponse:
    snap = STATE.snapshot()
    if not snap["ready"]:
        raise HTTPException(409, f"Model not ready: stage={snap['stage']} "
                                 f"error={snap['error']}")

    text = _prepare_text(req.mode, req.text)
    output_path = pathlib.Path(req.output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # voxcpm is not thread-safe; serialise.
    with _GEN_LOCK:
        _set_seed(req.seed)

        kwargs: dict[str, Any] = {
            "text": text,
            "cfg_value": float(req.cfg_value),
            "inference_timesteps": int(req.inference_timesteps),
        }

        mode = req.mode
        if mode in ("clone", "ultimate"):
            if not req.reference_audio:
                raise HTTPException(400, f"{mode} mode requires reference_audio")
            kwargs["reference_wav_path"] = req.reference_audio
        if mode == "ultimate":
            if not (req.prompt_audio and req.prompt_text):
                raise HTTPException(400, "ultimate mode requires prompt_audio and prompt_text")
            kwargs["prompt_wav_path"] = req.prompt_audio
            kwargs["prompt_text"] = req.prompt_text

        t0 = time.time()
        model = STATE.model
        wav = model.generate(**kwargs)  # type: ignore[union-attr]
        elapsed = time.time() - t0

    if not isinstance(wav, np.ndarray):
        wav = np.asarray(wav)

    sr = STATE.sample_rate

    if req.normalize:
        peak = float(np.max(np.abs(wav))) if wav.size else 1.0
        if peak > 0:
            wav = (wav / peak) * 0.97

    fmt = req.output_format.lower()
    subtype = "PCM_16"
    if fmt == "flac":
        subtype = "PCM_16"
    elif fmt not in ("wav", "flac"):
        raise HTTPException(400, f"unsupported output_format {fmt}")

    sf.write(str(output_path), wav, sr, subtype=subtype, format=fmt.upper())

    duration = float(len(wav)) / float(sr) if sr else 0.0
    return GenerateResponse(
        output_path=str(output_path),
        duration_seconds=duration,
        sample_rate=sr,
        elapsed_seconds=elapsed,
    )


@app.post("/shutdown")
def shutdown() -> dict:
    log.info("Shutdown requested")
    # Defer so the response can flush.
    def _stop() -> None:
        time.sleep(0.1)
        os.kill(os.getpid(), signal.SIGTERM)
    threading.Thread(target=_stop, daemon=True).start()
    return {"ok": True}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=0,
                   help="0 = let the OS pick. The chosen port is printed as "
                        "'MACVOXCPM_PORT=<n>' on stdout for the parent to scrape.")
    p.add_argument("--model-id", default=os.environ.get("MACVOXCPM_MODEL_ID",
                                                        "openbmb/VoxCPM2"))
    p.add_argument("--device", default=os.environ.get("MACVOXCPM_DEVICE", "auto"))
    args = p.parse_args()

    STATE.set(model_id=args.model_id, device=args.device)

    config = uvicorn.Config(
        app, host=args.host, port=args.port, log_level="info", access_log=False,
    )
    server = uvicorn.Server(config)

    # Print the actually-bound port once the socket is open.
    orig_startup = server.startup

    async def _wrapped_startup(sockets: Any = None) -> None:  # type: ignore[override]
        await orig_startup(sockets=sockets)
        for s in server.servers:
            for sock in s.sockets:
                addr = sock.getsockname()
                if isinstance(addr, tuple) and len(addr) >= 2:
                    print(f"MACVOXCPM_PORT={addr[1]}", flush=True)

    server.startup = _wrapped_startup  # type: ignore[assignment]
    server.run()


if __name__ == "__main__":
    main()
