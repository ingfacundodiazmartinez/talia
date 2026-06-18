"""RunPod Serverless handler para ACE-Step (fallback de la box).

Mismo contrato que talia_server.py de la box:
  input: {caption, lyrics, instrumental, duration, reference_audio_url, cover_strength}
  output: {audio_base64 (flac), audio_format, lyrics, lrc}

El modelo (acestep-v15-xl-turbo) se baja de HuggingFace al cold start y se cachea
en el network volume (/runpod-volume) para los siguientes arranques.
"""
import os, sys, glob, base64, tempfile, shutil, subprocess, gc
import urllib.request
from urllib.parse import urlparse, unquote

import runpod

REPO = os.environ.get("ACESTEP_REPO", "/app/ACE-Step-1.5")
# Cachear pesos en el network volume si está montado (persiste entre cold starts).
_VOL = "/runpod-volume"
if os.path.isdir(_VOL):
    os.environ.setdefault("HF_HOME", os.path.join(_VOL, "hf"))
os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

sys.path.insert(0, REPO)
os.chdir(REPO)

import profile_inference as P
from acestep.inference import generate_music, GenerationParams, GenerationConfig

FFMPEG = "ffmpeg"  # instalado vía apt en la imagen

print("[rp_handler] inicializando handlers...", flush=True)
_cfg = os.environ.get("ACESTEP_CONFIG_PATH", "acestep-v15-xl-turbo")
_parser = P.build_parser()
_args = _parser.parse_args(["--mode", "profile", "--config-path", _cfg])
_args.device = "cuda"
dit_handler, llm_handler = P.initialize_handlers(_args, "cuda")
print("[rp_handler] handlers listos", flush=True)


def _download_reference(url, dest_dir):
    """Descarga la referencia y la convierte a WAV (≤20s) con ffmpeg."""
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
            subprocess.run(
                [FFMPEG, "-y", "-i", raw, "-ac", "2", "-ar", "44100", "-t", "20", wav],
                check=True, capture_output=True, timeout=60,
            )
            if os.path.exists(wav) and os.path.getsize(wav) > 256:
                return wav
        except Exception as e:
            print(f"[rp_handler] ffmpeg conversion falló: {e}", flush=True)
        return raw
    except Exception as e:
        print(f"[rp_handler] descarga de referencia falló: {e}", flush=True)
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
            # Mapear el slider (0..1) a un rango alto (piso 0.6) para que el
            # cover siga la referencia (default del GUI de ACE-Step = 1.0).
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
        return {
            "audio_base64": audio_b64, "audio_format": "flac",
            "lyrics": (lyrics or None) if not instrumental else None, "lrc": None,
        }
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
