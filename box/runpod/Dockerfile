# ACE-Step en RunPod Serverless — mirror del setup de la box (que usa uv).
# Replica con uv para resolver nano-vllm (paquete local del repo) + torch cu128
# (índice pytorch-cu128), igual que pyproject/uv.lock. El modelo va horneado
# para correr multi-datacenter sin network volume.
FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 \
    HF_HOME=/opt/hf \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    ACESTEP_CONFIG_PATH=acestep-v15-xl-turbo \
    ACESTEP_REPO=/app/ACE-Step-1.5

RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg git curl ca-certificates build-essential && \
    rm -rf /var/lib/apt/lists/*

# uv (mismo gestor que la box)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app
RUN git clone https://github.com/ace-step/ACE-Step-1.5.git && \
    cd ACE-Step-1.5 && git checkout dce621408bee8c31b4fcf4811682eb9359e1bc94

WORKDIR /app/ACE-Step-1.5
# uv sync resuelve TODO: nano-vllm local + torch==2.10.0+cu128 (índice cu128) + deps.
RUN uv sync --no-dev

# SDK de RunPod + hf_transfer dentro del venv de uv.
RUN uv pip install runpod hf_transfer

# Hornear pesos del modelo en la imagen (sin network volume → multi-DC).
RUN uv run python -c "from huggingface_hub import snapshot_download; snapshot_download('ACE-Step/acestep-v15-xl-turbo'); snapshot_download('ACE-Step/Ace-Step1.5')"

COPY rp_handler.py /app/ACE-Step-1.5/rp_handler.py

CMD ["/app/ACE-Step-1.5/.venv/bin/python", "/app/ACE-Step-1.5/rp_handler.py"]
