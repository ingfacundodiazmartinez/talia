# FaceFusion RunPod Serverless Worker

RunPod Serverless worker for face swapping using FaceFusion with GHOST model (Apache 2.0 License).

## Features

- Face swapping using GHOST model (Apache 2.0 commercial license)
- Supports image URLs and base64 input
- Optional face enhancement
- GPU-accelerated (CUDA)

## API Input Format

```json
{
  "input": {
    "source_image": "https://example.com/source.jpg",
    "target_image": "https://example.com/target.jpg",
    "model": "ghost_3_256",
    "face_enhancer": false
  }
}
```

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| source_image | string | Yes | - | URL or base64 of the source face image |
| target_image | string | Yes | - | URL or base64 of the target image to swap face into |
| model | string | No | ghost_3_256 | Face swap model |
| face_enhancer | boolean | No | false | Apply face enhancement after swap |

### Available Models (Apache 2.0)

- `ghost_1_256` - GHOST v1
- `ghost_2_256` - GHOST v2
- `ghost_3_256` - GHOST v3 (recommended, best quality)
- `blendswap_256` - BlendSwap
- `simswap_256` - SimSwap
- `uniface_256` - UniFace

## API Output Format

### Success
```json
{
  "output": {
    "image": "base64_encoded_image_data",
    "status": "success",
    "model": "ghost_3_256"
  }
}
```

### Error
```json
{
  "output": {
    "error": "Error message"
  }
}
```

## Build & Deploy

### Prerequisites

- Docker with NVIDIA GPU support
- Docker Hub account

### Build

```bash
chmod +x build.sh push.sh
./build.sh
```

### Push to Docker Hub

```bash
# Set your Docker Hub username
export DOCKER_USERNAME=yourusername

./push.sh
```

### Configure in RunPod

1. Go to RunPod Serverless
2. Create new endpoint
3. Set container image: `yourusername/facefusion-runpod-worker:1.0.0`
4. GPU Type: RTX 3090 or better recommended
5. Max Workers: 3-5

## Local Testing

```bash
# Build
docker build -t facefusion-worker .

# Run with GPU
docker run --gpus all -p 8000:8000 facefusion-worker

# Test
curl -X POST http://localhost:8000/run \
  -H "Content-Type: application/json" \
  -d '{
    "input": {
      "source_image": "https://example.com/face.jpg",
      "target_image": "https://example.com/body.jpg"
    }
  }'
```

## License

- FaceFusion: Apache 2.0
- GHOST Model: Apache 2.0
- This worker: MIT
