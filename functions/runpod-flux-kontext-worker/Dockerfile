# Flux Kontext RunPod Serverless Worker
# Using FLUX.1-Kontext-dev for image editing

FROM --platform=linux/amd64 nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1
ENV HF_HOME=/app/huggingface
ENV TRANSFORMERS_CACHE=/app/huggingface

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3.10-venv \
    python3-pip \
    git \
    wget \
    curl \
    libgl1-mesa-glx \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Set Python 3.10 as default
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1 && \
    update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1

# Upgrade pip
RUN pip install --upgrade pip setuptools wheel

# Install PyTorch with CUDA support (2.5+ required for enable_gqa)
RUN pip install \
    torch==2.5.1 \
    torchvision==0.20.1 \
    --index-url https://download.pytorch.org/whl/cu124

# Install diffusers from main branch (required for FluxKontextPipeline)
RUN pip install \
    runpod \
    requests \
    Pillow \
    "numpy<2.0" \
    transformers>=4.44.0 \
    accelerate>=0.33.0 \
    sentencepiece \
    protobuf \
    safetensors \
    huggingface_hub \
    git+https://github.com/huggingface/diffusers.git

# Create directories
WORKDIR /app
RUN mkdir -p /app/huggingface

# Pre-download the model (optional - makes cold start faster but image larger)
# Uncomment the following to include model in image:
# RUN python -c "from diffusers import FluxKontextPipeline; FluxKontextPipeline.from_pretrained('black-forest-labs/FLUX.1-Kontext-dev', torch_dtype='auto')"

# Copy handler
COPY handler.py /app/handler.py

# Entry point
CMD ["python", "/app/handler.py"]
