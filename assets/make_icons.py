"""Build the app icons from source art: python assets/make_icons.py <art.png>

- Makes pure-black background connected to the corners transparent (rounded-square art with black corners)
- Writes icon-256.png (window + README) and a multi-size icon.ico (embedded in the exe by build.rs)
Requires Pillow: pip install pillow
"""
import sys
from pathlib import Path

from PIL import Image, ImageFilter

OUT = Path(__file__).resolve().parent
ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


def transparent_corners(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    mask = Image.new("L", rgb.size, 255)
    alpha = mask.load()
    # Flood-fill only near-black pixels connected to the edge; dark content inside is untouched because it doesn't touch the edge
    stack = [(x, y) for x in range(0, width, 8) for y in (0, height - 1)]
    stack += [(x, y) for y in range(0, height, 8) for x in (0, width - 1)]
    seen = set()
    while stack:
        x, y = stack.pop()
        if (x, y) in seen or not (0 <= x < width and 0 <= y < height):
            continue
        seen.add((x, y))
        if sum(pixels[x, y]) >= 60:
            continue
        alpha[x, y] = 0
        stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    rgba = rgb.convert("RGBA")
    rgba.putalpha(mask.filter(ImageFilter.GaussianBlur(1.2)))
    rgba = rgba.crop(rgba.getbbox())
    side = max(rgba.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(rgba, ((side - rgba.width) // 2, (side - rgba.height) // 2))
    return square


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = Image.open(sys.argv[1])
    if source.mode == "RGBA" and source.getchannel("A").getextrema()[0] < 255:
        square = source  # already has transparency, use it as is
    else:
        square = transparent_corners(source)
    icon = square.resize((256, 256), Image.LANCZOS)
    icon.save(OUT / "icon-256.png", optimize=True)
    icon.save(OUT / "icon.ico", sizes=ICO_SIZES)
    print(f"wrote {OUT / 'icon-256.png'} and {OUT / 'icon.ico'}")


if __name__ == "__main__":
    main()
