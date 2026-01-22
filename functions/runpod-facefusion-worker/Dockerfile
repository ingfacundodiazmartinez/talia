# Face Swap RunPod Serverless Worker
# Using insightface + inswapper + GFPGAN

FROM --platform=linux/amd64 nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3.10-venv \
    python3-pip \
    git \
    wget \
    curl \
    ffmpeg \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    && rm -rf /var/lib/apt/lists/*

# Set Python 3.10 as default
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1 && \
    update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1

# Upgrade pip
RUN pip install --upgrade pip setuptools wheel

# Install Python dependencies (based on reference repo + GPU support)
# Pin torch/torchvision versions compatible with gfpgan/basicsr
RUN pip install \
    torch==2.1.0 \
    torchvision==0.16.0 \
    --index-url https://download.pytorch.org/whl/cu121

RUN pip install \
    runpod \
    requests \
    Pillow \
    opencv-python-headless \
    "numpy<2.0" \
    onnxruntime-gpu \
    insightface==0.7.3 \
    gfpgan

# Create directories
WORKDIR /app
RUN mkdir -p /app/models
RUN mkdir -p /root/.insightface/models
RUN mkdir -p /app/gfpgan/weights

# Download inswapper model
RUN wget -q -O /app/models/inswapper_128.onnx \
    https://huggingface.co/ashleykleynhans/inswapper/resolve/main/inswapper_128.onnx

# Download GFPGAN model
RUN wget -q -O /app/models/GFPGANv1.4.pth \
    https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth

# Download GFPGAN facexlib dependencies (estos se descargaban en runtime!)
# detection_Resnet50_Final.pth - 104MB
RUN wget -q -O /app/gfpgan/weights/detection_Resnet50_Final.pth \
    https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth

# parsing_parsenet.pth - 81MB
RUN wget -q -O /app/gfpgan/weights/parsing_parsenet.pth \
    https://github.com/xinntao/facexlib/releases/download/v0.2.2/parsing_parsenet.pth

# buffalo_l models will be auto-downloaded by insightface on first run
# Pre-initialize to download during build (optional, speeds up cold start)
RUN python -c "from insightface.app import FaceAnalysis; fa = FaceAnalysis(name='buffalo_l'); fa.prepare(ctx_id=-1, det_size=(640, 640)); print('buffalo_l models downloaded')"

# Verify models
RUN echo "=== Models downloaded ===" && \
    ls -la /app/models/ && \
    ls -la /root/.insightface/models/ && \
    ls -la /app/gfpgan/weights/

# Copy handler
COPY handler.py /app/handler.py

# Entry point
CMD ["python", "/app/handler.py"]
