# ACE-Step en RunPod Serverless — mirror del setup de la box (que usa uv).
# Autocontenido: el handler se genera inline (sin COPY), así no depende del
# build context de RunPod. Resuelve nano-vllm (paquete local del repo) + torch
# cu128 vía uv, igual que pyproject/uv.lock. Modelo horneado → multi-DC sin volume.
FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 \
    HF_HOME=/opt/hf \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    ACESTEP_CONFIG_PATH=acestep-v15-xl-turbo \
    ACESTEP_REPO=/app/ACE-Step-1.5

RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg git curl ca-certificates build-essential && \
    rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app
RUN git clone https://github.com/ace-step/ACE-Step-1.5.git && \
    cd ACE-Step-1.5 && git checkout dce621408bee8c31b4fcf4811682eb9359e1bc94

WORKDIR /app/ACE-Step-1.5
# uv sync resuelve TODO: nano-vllm local + torch==2.10.0+cu128 + deps.
RUN uv sync --no-dev
RUN uv pip install runpod hf_transfer

# NOTA: el modelo NO se hornea (excedía el límite de build de 30 min de RunPod
# al exportar ~25GB). Se baja en el cold start vía HF (en la red de RunPod tarda
# ~66s) a HF_HOME=/opt/hf. La imagen queda ~8GB → el build entra en los 30 min.
# Sin network volume → multi-DC. hf_transfer acelera la descarga.

# Handler inline (igual contrato que la box).
RUN cat > /app/ACE-Step-1.5/rp_handler.py <<'PYEOF'
import os, sys, glob, base64, tempfile, shutil, subprocess, gc
import urllib.request
from urllib.parse import urlparse, unquote
import runpod

REPO = os.environ.get("ACESTEP_REPO", "/app/ACE-Step-1.5")
sys.path.insert(0, REPO)
os.chdir(REPO)
os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

import profile_inference as P
from acestep.inference import generate_music, GenerationParams, GenerationConfig

FFMPEG = "ffmpeg"

print("[rp_handler] inicializando handlers...", flush=True)
_cfg = os.environ.get("ACESTEP_CONFIG_PATH", "acestep-v15-xl-turbo")
_parser = P.build_parser()
_args = _parser.parse_args(["--mode", "profile", "--config-path", _cfg])
_args.device = "cuda"
dit_handler, llm_handler = P.initialize_handlers(_args, "cuda")
print("[rp_handler] handlers listos", flush=True)


def _download_reference(url, dest_dir):
    try:
        path_part = unquote(urlparse(url).path)
        ext = os.path.splitext(path_part)[1] or ".m4a"
        raw = os.path.join(dest_dir, "ref_raw" + ext)
        req = urllib.request.Request(url, headers={"User-Agent": "talia-acestep/1.0"})
        with urllib.request.urlopen(req, timeout=30) as r, open(raw, "wb") as f:
            shutil.copyfileobj(r, f)
        if os.path.getsize(raw) < 256:
            return None
        wav = os.path.join(dest_dir, "ref.wav")
        try:
            subprocess.run([FFMPEG, "-y", "-i", raw, "-ac", "2", "-ar", "44100", "-t", "20", wav],
                           check=True, capture_output=True, timeout=60)
            if os.path.exists(wav) and os.path.getsize(wav) > 256:
                return wav
        except Exception as e:
            print(f"[rp_handler] ffmpeg conversion fallo: {e}", flush=True)
        return raw
    except Exception as e:
        print(f"[rp_handler] descarga de referencia fallo: {e}", flush=True)
        return None


def handler(job):
    inp = job.get("input", {}) or {}
    caption = (inp.get("caption") or "").strip()
    if len(caption) < 3:
        return {"error": "caption too short"}
    instrumental = bool(inp.get("instrumental"))
    lyrics = "[Instrumental]" if instrumental else (inp.get("lyrics") or "")
    duration = int(inp.get("duration") or 30)
    ref_url = inp.get("reference_audio_url")
    try:
        cover_strength = max(0.0, min(1.0, float(inp.get("cover_strength", 0.5))))
    except Exception:
        cover_strength = 0.5

    task_type = "text2music"
    src_audio = None
    audio_cover_strength = 1.0
    ref_dir = None
    if ref_url:
        ref_dir = tempfile.mkdtemp(prefix="talia_ref_")
        ref_path = _download_reference(ref_url, ref_dir)
        if ref_path:
            task_type = "cover"
            src_audio = ref_path
            audio_cover_strength = 0.6 + 0.4 * cover_strength

    params = GenerationParams(
        caption=caption, lyrics=lyrics, duration=duration,
        inference_steps=8, seed=42, task_type=task_type, thinking=False,
        src_audio=src_audio, audio_cover_strength=audio_cover_strength,
    )
    config = GenerationConfig(batch_size=1, seeds=[42], use_random_seed=False, audio_format="flac")
    save_dir = tempfile.mkdtemp(prefix="talia_gen_")
    try:
        res = generate_music(dit_handler, llm_handler, params, config, save_dir=save_dir)
        if not getattr(res, "success", False):
            return {"error": f"gen failed: {getattr(res, 'error', '?')}"}
        files = glob.glob(os.path.join(save_dir, "*.flac")) + glob.glob(os.path.join(save_dir, "*.mp3"))
        if not files:
            return {"error": "no audio produced"}
        with open(files[0], "rb") as f:
            audio_b64 = base64.b64encode(f.read()).decode()
        return {"audio_base64": audio_b64, "audio_format": "flac",
                "lyrics": (lyrics or None) if not instrumental else None, "lrc": None}
    finally:
        shutil.rmtree(save_dir, ignore_errors=True)
        if ref_dir:
            shutil.rmtree(ref_dir, ignore_errors=True)
        try:
            import torch
            gc.collect(); torch.cuda.empty_cache(); torch.cuda.ipc_collect()
        except Exception:
            pass


runpod.serverless.start({"handler": handler})
PYEOF

CMD ["/app/ACE-Step-1.5/.venv/bin/python", "/app/ACE-Step-1.5/rp_handler.py"]
