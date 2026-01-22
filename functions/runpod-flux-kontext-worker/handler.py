"""
RunPod Serverless Handler for Flux Kontext Image Editing
Using FLUX.1-Kontext-dev with FP8 quantization for efficiency
"""

import os
import sys
import base64
import tempfile
import requests
import runpod
import torch
from PIL import Image
from io import BytesIO

# Global model
pipe = None

def setup_model():
    """Initialize Flux Kontext model on cold start"""
    global pipe

    print("=== LOADING FLUX KONTEXT MODEL ===")

    # Login to HuggingFace for gated model access
    from huggingface_hub import login
    hf_token = os.environ.get("HF_TOKEN")
    if hf_token:
        print("Logging in to HuggingFace...")
        login(token=hf_token)
        print("✅ HuggingFace login successful")
    else:
        print("⚠️ HF_TOKEN not found, may fail on gated models")

    from diffusers import FluxKontextPipeline

    # Load model with bfloat16 for efficiency
    pipe = FluxKontextPipeline.from_pretrained(
        "black-forest-labs/FLUX.1-Kontext-dev",
        torch_dtype=torch.bfloat16,
    )

    # Use model CPU offload - works on any GPU, faster than sequential
    pipe.enable_model_cpu_offload()
    print("✅ Model CPU offload enabled (compatible with all GPUs)")

    print("✅ Flux Kontext model loaded successfully")
    print(f"   Device: {pipe.device}")
    return pipe


def download_image(url_or_base64):
    """Download image from URL or decode from base64"""
    try:
        if url_or_base64.startswith(('http://', 'https://')):
            print(f"Downloading image from URL: {url_or_base64[:80]}...")
            response = requests.get(url_or_base64, timeout=30, headers={
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            })
            response.raise_for_status()
            image = Image.open(BytesIO(response.content)).convert('RGB')
        else:
            # Assume base64
            print("Decoding base64 image...")
            if ',' in url_or_base64:
                url_or_base64 = url_or_base64.split(',')[1]
            image_data = base64.b64decode(url_or_base64)
            image = Image.open(BytesIO(image_data)).convert('RGB')

        print(f"Image loaded: {image.size}")
        return image
    except Exception as e:
        print(f"Error loading image: {e}")
        return None


def handler(job):
    """
    RunPod handler for Flux Kontext image editing

    Input:
    {
        "input": {
            "image": "URL or base64",      # Input image to edit
            "prompt": "edit instruction",   # What to do (e.g., "make the sky sunset orange")
            "guidance_scale": 3.5,          # Optional, default 3.5
            "num_inference_steps": 28,      # Optional, default 28
            "seed": 12345                   # Optional, for reproducibility
        }
    }
    """
    global pipe

    print("=== FLUX KONTEXT HANDLER ===")

    try:
        job_input = job.get("input", {})

        # Get inputs
        image_input = job_input.get("image")
        prompt = job_input.get("prompt")
        guidance_scale = job_input.get("guidance_scale", 3.5)
        num_inference_steps = job_input.get("num_inference_steps", 28)
        seed = job_input.get("seed", None)

        if not image_input:
            return {"error": "image is required"}
        if not prompt:
            return {"error": "prompt is required"}

        print(f"Prompt: {prompt}")
        print(f"Guidance scale: {guidance_scale}")
        print(f"Inference steps: {num_inference_steps}")

        # Load model if not loaded
        if pipe is None:
            setup_model()

        # Download/decode input image
        input_image = download_image(image_input)
        if input_image is None:
            return {"error": "Failed to load input image"}

        # Resize if too large (max 1024x1024 for efficiency)
        max_size = 1024
        if max(input_image.size) > max_size:
            ratio = max_size / max(input_image.size)
            new_size = (int(input_image.size[0] * ratio), int(input_image.size[1] * ratio))
            input_image = input_image.resize(new_size, Image.LANCZOS)
            print(f"Resized to: {input_image.size}")

        # Set up generator for reproducibility
        generator = None
        if seed is not None:
            generator = torch.Generator(device="cuda").manual_seed(seed)
            print(f"Using seed: {seed}")

        # Run Flux Kontext
        print("=== RUNNING FLUX KONTEXT ===")
        result = pipe(
            image=input_image,
            prompt=prompt,
            guidance_scale=guidance_scale,
            num_inference_steps=num_inference_steps,
            generator=generator,
        )

        output_image = result.images[0]
        print(f"Output image: {output_image.size}")

        # Convert to base64
        print("Encoding result to base64...")
        buffer = BytesIO()
        output_image.save(buffer, format="PNG", quality=95)
        buffer.seek(0)
        image_base64 = base64.b64encode(buffer.getvalue()).decode('utf-8')

        print(f"✅ Flux Kontext complete, output size: {len(image_base64)} chars")

        return {
            "image": image_base64,
            "width": output_image.size[0],
            "height": output_image.size[1]
        }

    except Exception as e:
        print(f"❌ Error: {str(e)}")
        import traceback
        traceback.print_exc()
        return {"error": str(e)}


# Initialize RunPod
print("Starting Flux Kontext RunPod Serverless Worker...")
runpod.serverless.start({"handler": handler})
