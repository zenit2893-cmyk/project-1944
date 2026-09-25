"""Draw the launcher's language flags: flag-en/uk/be/es/de.png.

Painted here from plain geometry, like build_art.py, so the launcher carries
no third-party imagery. Russian has no flag on purpose - its button is the
text "RU". Belarusian is the white-red-white flag. Spanish is the civil flag
(no coat of arms). English is the Union Jack.

Every flag is drawn 3:2 at 8x and scaled down, which smooths the diagonals.

usage: build_flags.py            (writes next to this script)
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / 'analysis/dev-python'))
from PIL import Image, ImageChops, ImageDraw  # noqa: E402

W, H = 63, 42        # output, shown at 21x14 in the launcher
SS = 8               # supersampling
RADIUS = 5           # corner radius at output size


def stripes(colors, weights=None):
    weights = weights or [1] * len(colors)
    image = Image.new('RGB', (W * SS, H * SS))
    draw = ImageDraw.Draw(image)
    total = sum(weights)
    top = 0.0
    for color, weight in zip(colors, weights):
        bottom = top + H * SS * weight / total
        draw.rectangle([0, round(top), W * SS, round(bottom)], fill=color)
        top = bottom
    return image


def band(draw, a, b, width, fill, scale):
    """A straight band of the given width between two points (flag units)."""
    (x0, y0), (x1, y1) = a, b
    dx, dy = x1 - x0, y1 - y0
    length = (dx * dx + dy * dy) ** 0.5
    nx, ny = -dy / length * width / 2, dx / length * width / 2
    points = [(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)]
    draw.polygon([(x * scale[0], y * scale[1]) for x, y in points], fill=fill)


def union_jack():
    # The flag's own 60x30 geometry, stretched to 3:2 like most flag icons.
    blue, red, white = (1, 33, 105), (200, 16, 46), (255, 255, 255)
    scale = (W * SS / 60, H * SS / 30)
    image = Image.new('RGB', (W * SS, H * SS), blue)
    draw = ImageDraw.Draw(image)
    band(draw, (-6, -3), (66, 33), 6, white, scale)
    band(draw, (66, -3), (-6, 33), 6, white, scale)

    # The red saltire is counterchanged: in each quarter it keeps to one side
    # of the white diagonal, so it is drawn on its own layer and cut by the
    # four triangles the official construction uses.
    red_layer = Image.new('RGB', image.size, red)
    red_band = Image.new('L', image.size, 0)
    band_draw = ImageDraw.Draw(red_band)
    band(band_draw, (-6, -3), (66, 33), 4, 255, scale)
    band(band_draw, (66, -3), (-6, 33), 4, 255, scale)
    clip = Image.new('L', image.size, 0)
    clip_draw = ImageDraw.Draw(clip)
    for triangle in (((30, 15), (60, 15), (60, 30)), ((30, 15), (30, 30), (0, 30)),
                     ((30, 15), (0, 15), (0, 0)), ((30, 15), (30, 0), (60, 0))):
        clip_draw.polygon([(x * scale[0], y * scale[1]) for x, y in triangle], fill=255)
    image.paste(red_layer, (0, 0), ImageChops.multiply(red_band, clip))

    band(draw, (30, -1), (30, 31), 10, white, scale)
    band(draw, (-1, 15), (61, 15), 10, white, scale)
    band(draw, (30, -1), (30, 31), 6, red, scale)
    band(draw, (-1, 15), (61, 15), 6, red, scale)
    return image


FLAGS = {
    'en': union_jack,
    'uk': lambda: stripes([(0, 87, 183), (255, 215, 0)]),
    'be': lambda: stripes([(255, 255, 255), (200, 49, 62), (255, 255, 255)]),
    'es': lambda: stripes([(170, 21, 27), (241, 191, 0), (170, 21, 27)], [1, 2, 1]),
    'de': lambda: stripes([(0, 0, 0), (221, 0, 0), (255, 206, 0)]),
}


def finish(image):
    image = image.resize((W, H), Image.LANCZOS).convert('RGBA')
    # Rounded corners and a hairline edge, so the white stripes of the
    # Belarusian flag still read against a light hover background.
    mask = Image.new('L', (W * SS, H * SS), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W * SS - 1, H * SS - 1], RADIUS * SS, fill=255)
    image.putalpha(mask.resize((W, H), Image.LANCZOS))
    edge = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle([0, 0, W * SS - 1, H * SS - 1], RADIUS * SS,
                                           outline=(0, 0, 0, 90), width=SS * 2)
    return Image.alpha_composite(image, edge.resize((W, H), Image.LANCZOS))


def main():
    for code, paint in FLAGS.items():
        path = HERE / f'flag-{code}.png'
        finish(paint()).save(path, optimize=True)
        print(path.name)


if __name__ == '__main__':
    main()
