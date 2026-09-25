"""Make the launcher's .ico from a picture.

A tall picture (a game box) is fitted into the square with transparent sides
and a soft shadow, so it still reads as a box on the taskbar; a square one is
used as it is. Every size Windows asks for is drawn from the full-resolution
source, with a light sharpen for the small ones.

usage: build_icon.py <picture> <output.ico>
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / 'analysis/dev-python'))
from PIL import Image, ImageFilter  # noqa: E402

SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
CANVAS = 1024


def square(source):
    image = source.convert('RGBA')
    width, height = image.size
    if abs(width - height) <= max(width, height) * 0.05:
        return image.resize((CANVAS, CANVAS), Image.LANCZOS)
    # Fit the long side, leave room for the shadow.
    scale = (CANVAS * 0.94) / max(width, height)
    fitted = image.resize((round(width * scale), round(height * scale)), Image.LANCZOS)
    canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    x = (CANVAS - fitted.width) // 2
    y = (CANVAS - fitted.height) // 2
    shadow = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (x + 10, y + 16, x + fitted.width + 10, y + fitted.height + 16))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(fitted, (x, y))
    return canvas


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    master = square(Image.open(sys.argv[1]))
    frames = []
    for size in SIZES:
        frame = master.resize((size, size), Image.LANCZOS)
        if size <= 48:
            frame = frame.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=2))
        frames.append(frame)
    output = Path(sys.argv[2])
    output.parent.mkdir(parents=True, exist_ok=True)
    frames[-1].save(output, format='ICO', sizes=[(s, s) for s in SIZES], append_images=frames[:-1])
    print(f'{output.name}: {len(SIZES)} sizes from {sys.argv[1]}')


if __name__ == '__main__':
    main()
