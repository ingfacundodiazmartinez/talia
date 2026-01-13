#!/usr/bin/env python3
"""
Script para generar splash screen en alta resolución para Talia.
Requiere: pip install Pillow numpy
"""

from PIL import Image, ImageDraw, ImageFont
import numpy as np
import os

# Configuración
OUTPUT_WIDTH = 1440
OUTPUT_HEIGHT = 3120
BACKGROUND_COLOR = (0, 0, 0)  # Negro

# Colores del gradiente (púrpura a rosa)
GRADIENT_START = (157, 127, 232)  # #9D7FE8 - Púrpura
GRADIENT_END = (232, 127, 197)    # #E87FC5 - Rosa

# Paths
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
ICON_PATH = os.path.join(PROJECT_DIR, "assets/images/icon.png")
OUTPUT_PATH = os.path.join(PROJECT_DIR, "assets/images/splash_fullscreen.png")


def create_gradient_text(text, font, gradient_start, gradient_end):
    """Crea texto con gradiente horizontal."""
    # Crear imagen temporal para medir el texto
    temp_img = Image.new('RGBA', (1, 1))
    temp_draw = ImageDraw.Draw(temp_img)
    bbox = temp_draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]

    # Crear imagen del texto
    text_img = Image.new('RGBA', (text_width + 20, text_height + 20), (0, 0, 0, 0))
    text_draw = ImageDraw.Draw(text_img)

    # Dibujar texto en blanco
    text_draw.text((10, 10), text, font=font, fill=(255, 255, 255, 255))

    # Crear gradiente
    gradient = np.zeros((text_height + 20, text_width + 20, 4), dtype=np.uint8)
    for x in range(text_width + 20):
        ratio = x / (text_width + 20)
        r = int(gradient_start[0] + (gradient_end[0] - gradient_start[0]) * ratio)
        g = int(gradient_start[1] + (gradient_end[1] - gradient_start[1]) * ratio)
        b = int(gradient_start[2] + (gradient_end[2] - gradient_start[2]) * ratio)
        gradient[:, x] = [r, g, b, 255]

    gradient_img = Image.fromarray(gradient, 'RGBA')

    # Aplicar el texto como máscara al gradiente
    text_array = np.array(text_img)
    gradient_array = np.array(gradient_img)

    # Usar el canal alpha del texto para el gradiente
    result_array = gradient_array.copy()
    result_array[:, :, 3] = text_array[:, :, 3]

    return Image.fromarray(result_array, 'RGBA')


def generate_splash():
    """Genera el splash screen en alta resolución."""
    print(f"Generando splash screen {OUTPUT_WIDTH}x{OUTPUT_HEIGHT}...")

    # Crear imagen base
    splash = Image.new('RGB', (OUTPUT_WIDTH, OUTPUT_HEIGHT), BACKGROUND_COLOR)

    # Cargar y redimensionar el icono
    print(f"Cargando icono desde {ICON_PATH}...")
    icon = Image.open(ICON_PATH).convert('RGBA')

    # Escalar icono (aproximadamente 35% del ancho)
    icon_size = int(OUTPUT_WIDTH * 0.35)
    icon = icon.resize((icon_size, icon_size), Image.Resampling.LANCZOS)

    # Posición del icono (centrado, 28% desde arriba)
    icon_x = (OUTPUT_WIDTH - icon_size) // 2
    icon_y = int(OUTPUT_HEIGHT * 0.28)

    # Pegar icono
    splash.paste(icon, (icon_x, icon_y), icon)

    # Intentar cargar fuente del sistema (o usar default)
    try:
        # macOS fonts
        font_paths = [
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/SFNSDisplay.ttf",
            "/Library/Fonts/Arial.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",  # Linux
        ]
        font_path = None
        for fp in font_paths:
            if os.path.exists(fp):
                font_path = fp
                break

        if font_path:
            title_font = ImageFont.truetype(font_path, 140)
            tagline_font = ImageFont.truetype(font_path, 48)
        else:
            raise Exception("No font found")
    except Exception as e:
        print(f"Usando fuente por defecto: {e}")
        title_font = ImageFont.load_default()
        tagline_font = ImageFont.load_default()

    # Crear texto "Talia" con gradiente
    title_text = "Talia"
    title_img = create_gradient_text(title_text, title_font, GRADIENT_START, GRADIENT_END)

    # Posición del título (centrado, debajo del icono)
    title_x = (OUTPUT_WIDTH - title_img.width) // 2
    title_y = icon_y + icon_size + 60

    # Pegar título
    splash.paste(title_img, (title_x, title_y), title_img)

    # Crear texto "Comunicación Inteligente"
    tagline_text = "Comunicación Inteligente"
    tagline_color = (150, 150, 150)  # Gris

    # Crear imagen del tagline
    temp_img = Image.new('RGBA', (1, 1))
    temp_draw = ImageDraw.Draw(temp_img)
    bbox = temp_draw.textbbox((0, 0), tagline_text, font=tagline_font)
    tagline_width = bbox[2] - bbox[0]
    tagline_height = bbox[3] - bbox[1]

    tagline_img = Image.new('RGBA', (tagline_width + 20, tagline_height + 20), (0, 0, 0, 0))
    tagline_draw = ImageDraw.Draw(tagline_img)
    tagline_draw.text((10, 10), tagline_text, font=tagline_font, fill=tagline_color + (255,))

    # Posición del tagline (centrado, cerca del bottom - 90%)
    tagline_x = (OUTPUT_WIDTH - tagline_img.width) // 2
    tagline_y = int(OUTPUT_HEIGHT * 0.90)

    # Pegar tagline
    splash.paste(tagline_img, (tagline_x, tagline_y), tagline_img)

    # Guardar
    print(f"Guardando en {OUTPUT_PATH}...")
    splash.save(OUTPUT_PATH, 'PNG', optimize=True)
    print(f"Splash screen generado exitosamente!")
    print(f"Tamaño: {OUTPUT_WIDTH}x{OUTPUT_HEIGHT} px")

    # Verificar tamaño del archivo
    file_size = os.path.getsize(OUTPUT_PATH) / 1024
    print(f"Tamaño del archivo: {file_size:.1f} KB")


if __name__ == "__main__":
    generate_splash()
