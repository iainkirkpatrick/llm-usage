#!/usr/bin/env python3
"""Generate the LLM Usage macOS app icon and its .icns bundle."""

from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Assets" / "AppIcon.icns"
SIZE = 1024


def make_icon() -> Image.Image:
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Soft macOS-style shadow beneath an inset rounded square.
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (82, 94, 942, 954), radius=205, fill=(0, 0, 0, 125)
    )
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(34)))

    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((72, 66, 952, 946), radius=210, fill=255)

    # Deep indigo-to-cyan gradient, brightened toward the upper-left.
    gradient = Image.new("RGBA", image.size)
    pixels = gradient.load()
    for y in range(SIZE):
        for x in range(SIZE):
            t = (0.42 * x + 0.58 * y) / (SIZE - 1)
            glow = max(0.0, 1.0 - (((x - 255) ** 2 + (y - 190) ** 2) ** 0.5) / 850)
            pixels[x, y] = (
                int(24 + 16 * glow),
                int(30 + 60 * (1 - t) + 18 * glow),
                int(88 + 98 * (1 - t) + 24 * glow),
                255,
            )
    image.alpha_composite(Image.composite(gradient, Image.new("RGBA", image.size), mask))

    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle(
        (78, 72, 946, 940), radius=204, outline=(255, 255, 255, 42), width=7
    )

    font_path = Path("/System/Library/Fonts/SFNSRounded.ttf")
    if not font_path.exists():
        font_path = Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf")
    font = ImageFont.truetype(str(font_path), 325)
    text = "LLM"
    box = draw.textbbox((0, 0), text, font=font, stroke_width=1)
    text_width = box[2] - box[0]
    text_height = box[3] - box[1]
    position = ((SIZE - text_width) / 2, (SIZE - text_height) / 2 - box[1] - 8)

    draw.text((position[0] + 5, position[1] + 11), text, font=font, fill=(0, 0, 20, 85))
    draw.text(position, text, font=font, fill=(255, 255, 255, 255))
    image.alpha_composite(overlay)
    return image


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    icon = make_icon()
    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    with tempfile.TemporaryDirectory() as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for name, size in sizes.items():
            icon.resize((size, size), Image.Resampling.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUTPUT)], check=True)

    print(f"Generated {OUTPUT}")


if __name__ == "__main__":
    main()
