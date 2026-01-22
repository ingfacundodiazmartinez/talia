"""
RunPod Serverless Handler for Face Swap
Using insightface + GHOST model (Apache 2.0) + GFPGAN

Input format:
{
    "input": {
        "source_image": "base64 or URL",  # Face to use
        "target_image": "base64 or URL"   # Image to swap face into
    }
}

Output format:
{
    "output": {
        "image": "base64 encoded result",
        "status": "success"
    }
}
"""

import os
import sys
import base64
import tempfile
import requests
import runpod
import cv2
import numpy as np
from PIL import Image, ImageOps, ExifTags
import onnxruntime
from insightface.app import FaceAnalysis
import gfpgan


# Global models (loaded once)
face_analyser = None
face_swapper = None
face_enhancer = None


def setup_models():
    """Initialize models on cold start"""
    global face_analyser, face_swapper, face_enhancer

    print("=== INITIALIZING MODELS ===")

    # Face analyzer (insightface buffalo_l)
    print("Loading face analyzer (buffalo_l)...")
    face_analyser = FaceAnalysis(name='buffalo_l')
    face_analyser.prepare(ctx_id=0, det_size=(640, 640))
    print("Face analyzer ready")

    # Face swapper (inswapper model - using insightface's interface)
    print("Loading face swapper...")
    swapper_path = '/app/models/inswapper_128.onnx'
    if os.path.exists(swapper_path):
        import insightface
        face_swapper = insightface.model_zoo.get_model(
            swapper_path,
            providers=['CUDAExecutionProvider', 'CPUExecutionProvider']
        )
        print("Face swapper ready")
    else:
        print(f"WARNING: Swapper model not found at {swapper_path}")

    # Face enhancer (GFPGAN)
    print("Loading face enhancer (GFPGAN)...")
    enhancer_path = '/app/models/GFPGANv1.4.pth'
    if os.path.exists(enhancer_path):
        face_enhancer = gfpgan.GFPGANer(
            model_path=enhancer_path,
            upscale=1,
            arch='clean',
            channel_multiplier=2
        )
        print("Face enhancer ready")
    else:
        print(f"WARNING: Enhancer model not found at {enhancer_path}")

    print("=== MODELS INITIALIZED ===")


def fix_image_orientation(image_path: str) -> None:
    """Fix image orientation based on EXIF data and save back (like sharp.rotate() in Node.js)"""
    try:
        img = Image.open(image_path)
        original_size = img.size

        # Use ImageOps.exif_transpose() - handles all EXIF orientations automatically
        # This is equivalent to sharp's .rotate() which auto-rotates based on EXIF
        img_fixed = ImageOps.exif_transpose(img)

        if img_fixed is not img:
            # Image was rotated/transposed
            print(f"Fixed EXIF orientation: {original_size} -> {img_fixed.size}")
            # Save without EXIF to prevent double-rotation (like sharp's withMetadata)
            img_rgb = img_fixed.convert('RGB')
            img_rgb.save(image_path, 'JPEG', quality=95)
            print(f"Saved corrected image: {image_path}")
        else:
            # No rotation needed, but still strip EXIF to be safe
            print(f"No EXIF rotation needed for {image_path}")
            img_rgb = img.convert('RGB')
            img_rgb.save(image_path, 'JPEG', quality=95)

    except Exception as e:
        print(f"Error fixing orientation: {e}")


def download_image(url_or_base64: str, output_path: str) -> bool:
    """Download image from URL or decode from base64"""
    try:
        if url_or_base64.startswith("data:image"):
            base64_data = url_or_base64.split(",", 1)[1]
            image_data = base64.b64decode(base64_data)
            with open(output_path, "wb") as f:
                f.write(image_data)
            return True
        elif len(url_or_base64) > 500 and not url_or_base64.startswith("http"):
            image_data = base64.b64decode(url_or_base64)
            with open(output_path, "wb") as f:
                f.write(image_data)
            return True
        else:
            response = requests.get(url_or_base64, timeout=60)
            response.raise_for_status()
            with open(output_path, "wb") as f:
                f.write(response.content)
            return True
    except Exception as e:
        print(f"Error downloading image: {e}")
        return False


def get_face(img_data):
    """Get the largest face from image"""
    global face_analyser

    analysed = face_analyser.get(img_data)
    if not analysed:
        return None

    # Return largest face by bounding box area
    try:
        largest = max(analysed, key=lambda x: (x.bbox[2] - x.bbox[0]) * (x.bbox[3] - x.bbox[1]))
        return largest
    except:
        return None


def swap_face(source_img, target_img, source_face, target_face):
    """Perform face swap"""
    global face_swapper

    result = face_swapper.get(target_img, target_face, source_face, paste_back=True)
    return result


def enhance_face(img):
    """Enhance face quality with GFPGAN"""
    global face_enhancer

    if face_enhancer is None:
        return img

    _, _, result = face_enhancer.enhance(
        img,
        paste_back=True
    )
    return result


def handler(event):
    """RunPod Serverless Handler"""
    global face_analyser, face_swapper, face_enhancer

    try:
        # Initialize models if not done
        if face_analyser is None:
            setup_models()

        # Get input
        job_input = event.get("input", {})

        source_image = job_input.get("source_image")
        target_image = job_input.get("target_image")

        if not source_image:
            return {"error": "source_image is required"}
        if not target_image:
            return {"error": "target_image is required"}

        # Create temp directory
        with tempfile.TemporaryDirectory() as temp_dir:
            source_path = os.path.join(temp_dir, "source.jpg")
            target_path = os.path.join(temp_dir, "target.jpg")
            output_path = os.path.join(temp_dir, "output.jpg")

            # Download images
            print("Downloading source image...")
            if not download_image(source_image, source_path):
                return {"error": "Failed to download source image"}

            print("Downloading target image...")
            if not download_image(target_image, target_path):
                return {"error": "Failed to download target image"}

            # Fix EXIF orientation
            print("=== FIXING EXIF ORIENTATION ===")
            fix_image_orientation(source_path)
            fix_image_orientation(target_path)

            # Read images with OpenCV
            print("Reading images...")
            source_img = cv2.imread(source_path)
            target_img = cv2.imread(target_path)

            if source_img is None:
                return {"error": "Failed to read source image"}
            if target_img is None:
                return {"error": "Failed to read target image"}

            print(f"Source shape: {source_img.shape}")
            print(f"Target shape: {target_img.shape}")

            # Detect faces
            print("=== DETECTING FACES ===")
            source_face = get_face(source_img)
            target_face = get_face(target_img)

            if source_face is None:
                return {"error": "No face detected in source image"}
            if target_face is None:
                return {"error": "No face detected in target image"}

            print(f"Source face bbox: {source_face.bbox}")
            print(f"Target face bbox: {target_face.bbox}")

            # Perform face swap
            print("=== SWAPPING FACE ===")
            result = swap_face(source_img, target_img, source_face, target_face)
            print("Face swap complete")

            # Enhance result
            print("=== ENHANCING FACE ===")
            result = enhance_face(result)
            print("Enhancement complete")

            # Save result
            cv2.imwrite(output_path, result)

            # Encode to base64
            with open(output_path, "rb") as f:
                result_base64 = base64.b64encode(f.read()).decode("utf-8")

            return {
                "image": result_base64,
                "status": "success"
            }

    except Exception as e:
        print(f"Handler error: {e}")
        import traceback
        traceback.print_exc()
        return {"error": str(e)}


# Initialize models on import (for warm containers)
print("=== RUNPOD FACEFUSION WORKER STARTING ===")

# RunPod serverless entrypoint
runpod.serverless.start({"handler": handler})
