"""Draw the launcher/game mouse cursors and write .cur files.

Everything is painted from primitives here (no third-party or game imagery).
Each style has an arrow (the normal pointer) and a link pointer (over buttons).

usage: build_cursors.py [--out DIR] [--preview PNG] [--context SCREENSHOT]
"""
import argparse
import math
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path.insert(0, str(ROOT / 'analysis/dev-python'))
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont  # noqa: E402

UNITS = 64          # design grid
SS = 16             # supersampling: master canvas is 1024 px
MASTER = UNITS * SS
SIZES = (32, 48, 64)

INK = (22, 17, 10, 255)


# ------------------------------------------------------------------ helpers

def P(x, y):
    return (x * SS, y * SS)



def canvas():
    return Image.new('RGBA', (MASTER, MASTER), (0, 0, 0, 0))


def poly_mask(points):
    mask = Image.new('L', (MASTER, MASTER), 0)
    ImageDraw.Draw(mask).polygon([P(x, y) for x, y in points], fill=255)
    return mask


def gradient(c0, c1, start, end):
    """Linear gradient image from c0 at 'start' to c1 at 'end' (design units)."""
    sx, sy = start
    ex, ey = end
    dx, dy = ex - sx, ey - sy
    length2 = dx * dx + dy * dy or 1.0
    small = Image.new('RGBA', (UNITS * 2, UNITS * 2))
    px = small.load()
    for j in range(UNITS * 2):
        for i in range(UNITS * 2):
            x, y = i / 2.0, j / 2.0
            t = max(0.0, min(1.0, ((x - sx) * dx + (y - sy) * dy) / length2))
            px[i, j] = tuple(int(round(a + (b - a) * t)) for a, b in zip(c0, c1))
    return small.resize((MASTER, MASTER), Image.BILINEAR)


def fill(img, points, paint):
    """Fill a polygon with a colour or an image."""
    mask = poly_mask(points)
    layer = paint if isinstance(paint, Image.Image) else Image.new('RGBA', img.size, paint)
    img.alpha_composite(Image.composite(layer, Image.new('RGBA', img.size, (0, 0, 0, 0)), mask))


def outline(img, points, width, color=INK):
    d = ImageDraw.Draw(img)
    pts = [P(x, y) for x, y in points]
    d.line(pts + [pts[0]], fill=color, width=int(width * SS), joint='curve')
    r = width * SS / 2
    for x, y in pts:
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def half_plane(points_a, points_b, keep_left=True):
    """Mask of the side of line a->b (design units)."""
    (ax, ay), (bx, by) = points_a, points_b
    dx, dy = bx - ax, by - ay
    nx, ny = (-dy, dx) if keep_left else (dy, -dx)
    far = 400
    quad = [(ax - dx * far, ay - dy * far), (bx + dx * far, by + dy * far),
            (bx + dx * far + nx * far, by + dy * far + ny * far), (ax - dx * far + nx * far, ay - dy * far + ny * far)]
    return poly_mask(quad)


def tint_within(img, mask, color, alpha):
    """Overlay 'color' at 'alpha' inside mask AND the image's own alpha."""
    region = ImageChops.multiply(mask, img.getchannel('A'))
    region = region.point(lambda v: int(v * alpha))
    img.alpha_composite(Image.composite(Image.new('RGBA', img.size, color),
                                        Image.new('RGBA', img.size, (0, 0, 0, 0)), region))


def line(img, a, b, width, color):
    ImageDraw.Draw(img).line([P(*a), P(*b)], fill=color, width=max(1, int(width * SS)))


def disc(img, center, radius, color, outline_color=None, outline_width=0.0):
    x, y = P(*center)
    r = radius * SS
    d = ImageDraw.Draw(img)
    if outline_color is not None and outline_width > 0:
        ro = r + outline_width * SS
        d.ellipse([x - ro, y - ro, x + ro, y + ro], fill=outline_color)
    d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def ring(img, center, radius, width, color):
    x, y = P(*center)
    r = radius * SS
    ImageDraw.Draw(img).ellipse([x - r, y - r, x + r, y + r], outline=color, width=max(1, int(width * SS)))



def bevelled_star(img, center, outer, light, dark):
    cx, cy = center
    inner = outer * 0.4
    for k in range(5):
        a = math.radians(-90 + k * 72)
        tip = (cx + outer * math.cos(a), cy + outer * math.sin(a))
        left = (cx + inner * math.cos(a - math.pi / 5), cy + inner * math.sin(a - math.pi / 5))
        right = (cx + inner * math.cos(a + math.pi / 5), cy + inner * math.sin(a + math.pi / 5))
        fill(img, [center, left, tip], light)
        fill(img, [center, tip, right], dark)


def badge(img, center, radius=9.0):
    """The 'clickable' mark shared by the link pointers: an olive disc with a
    brass rim and a bevelled star, like the launcher emblem."""
    disc(img, center, radius, (74, 82, 36, 255), outline_color=INK, outline_width=1.4)
    ring(img, center, radius - 0.2, 1.3, (224, 163, 64, 255))
    bevelled_star(img, center, radius * 0.72, (247, 208, 124, 255), (178, 124, 48, 255))


def shadow(img, offset=(1.4, 2.0), blur=1.6, opacity=0.55):
    alpha = img.getchannel('A').filter(ImageFilter.GaussianBlur(blur * SS))
    alpha = alpha.point(lambda v: int(v * opacity))
    shifted = Image.new('L', img.size, 0)
    shifted.paste(alpha, (int(offset[0] * SS), int(offset[1] * SS)))
    base = Image.new('RGBA', img.size, (0, 0, 0, 0))
    base.putalpha(shifted)
    base.alpha_composite(img)
    return base


# ------------------------------------------------------------------- styles

ARROW = [(4, 3), (4, 47), (14.5, 37.5), (22.5, 56), (30.5, 52.5), (22.5, 34.5), (36.5, 34.5)]


def brass(link):
    img = canvas()
    outline(img, ARROW, 3.2)
    fill(img, ARROW, gradient((255, 226, 150, 255), (150, 96, 30, 255), (6, 4), (30, 52)))
    # Bevel: the left facet catches the light, the right one falls off.
    axis_a, axis_b = (4, 3), (26.5, 54)
    tint_within(img, half_plane(axis_a, axis_b, keep_left=False), (255, 255, 240, 255), 0.22)
    tint_within(img, half_plane(axis_a, axis_b, keep_left=True), (60, 30, 0, 255), 0.28)
    line(img, axis_a, (22, 44), 0.9, (110, 70, 20, 200))          # engraved ridge
    line(img, (5.6, 7.5), (5.6, 42), 0.9, (255, 244, 205, 230))    # edge glint
    if link:
        badge(img, (47, 47))
    return shadow(img), (4, 3)


def reticle(link):
    img = canvas()
    c = (32, 32)
    rim = (224, 163, 64, 255) if link else (200, 205, 200, 255)
    # Light halo first so the reticle reads on dark and light backgrounds.
    halo = canvas()
    ring(halo, c, 23, 5.0, (245, 238, 220, 200))
    for a, b in (((32, 5), (32, 22)), ((32, 42), (32, 59)), ((5, 32), (22, 32)), ((42, 32), (59, 32))):
        line(halo, a, b, 4.2, (245, 238, 220, 200))
    img.alpha_composite(halo.filter(ImageFilter.GaussianBlur(0.6 * SS)))
    ring(img, c, 23, 3.0, INK)
    ring(img, c, 23, 1.2, rim)
    # Posts: thick outside, thin inside, a gap at the centre.
    for a, b in (((32, 7), (32, 18)), ((32, 46), (32, 57)), ((7, 32), (18, 32)), ((46, 32), (57, 32))):
        line(img, a, b, 3.2, INK)
    for a, b in (((32, 18), (32, 28)), ((32, 36), (32, 46)), ((18, 32), (28, 32)), ((36, 32), (46, 32))):
        line(img, a, b, 1.1, INK)
    for k in (-10, -5, 5, 10):
        disc(img, (32 + k, 32), 0.9, INK)
        disc(img, (32, 32 + k), 0.9, INK)
    dot = (240, 70, 50, 255) if link else (224, 163, 64, 255)
    disc(img, c, 1.8, dot, outline_color=INK, outline_width=0.8)
    if link:
        # Corner brackets: target acquired.
        for sx, sy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
            x0, y0 = 32 + sx * 16, 32 + sy * 16
            line(img, (x0, y0), (x0 - sx * 5, y0), 1.6, (224, 163, 64, 255))
            line(img, (x0, y0), (x0, y0 - sy * 5), 1.6, (224, 163, 64, 255))
    return shadow(img, offset=(0.8, 1.2), blur=1.0, opacity=0.4), (32, 32)


# The launcher offers these two; 'brass' is the default.
STYLES = [
    ('brass', 'Латунь', 'Полированная латунь с фаской, как эмблема лаунчера', brass),
    ('reticle', 'Прицел', 'Сетка оптического прицела; на кнопках — захват цели', reticle),
]


# --------------------------------------------------------------- .cur files

def dib_entry(image):
    """32-bit BGRA DIB with an all-zero AND mask, as a .cur/.ico image."""
    w, h = image.size
    header = struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    rows = []
    px = image.load()
    for y in range(h - 1, -1, -1):
        row = bytearray()
        for x in range(w):
            r, g, b, a = px[x, y]
            row += bytes((b, g, r, a))
        rows.append(bytes(row))
    mask_row = ((w + 31) // 32) * 4
    return header + b''.join(rows) + bytes(mask_row * h)


def write_cur(path, images, hotspot_units):
    entries, blobs = [], []
    offset = 6 + 16 * len(images)
    for image in images:
        w, h = image.size
        blob = dib_entry(image)
        hx = int(round(hotspot_units[0] * w / UNITS))
        hy = int(round(hotspot_units[1] * h / UNITS))
        entries.append(struct.pack('<BBBBHHII', w % 256, h % 256, 0, 0, hx, hy, len(blob), offset))
        blobs.append(blob)
        offset += len(blob)
    path.write_bytes(struct.pack('<HHH', 0, 2, len(images)) + b''.join(entries) + b''.join(blobs))


# ----------------------------------------------------------------- preview

def font(size, bold=False):
    path = r'C:\Windows\Fonts\bahnschrift.ttf'
    f = ImageFont.truetype(path, size)
    try:
        f.set_variation_by_name('Bold' if bold else 'Regular')
    except Exception:
        pass
    return f


def preview(rendered, out, context_path):
    W, H = 40 + 380 * len(STYLES) + 40, 1040
    sheet = Image.new('RGB', (W, H), (14, 15, 14))
    d = ImageDraw.Draw(sheet)
    d.text((40, 26), 'КУРСОРЫ', font=font(34, True), fill=(238, 231, 217))
    d.text((40, 70), 'Слева основной курсор, справа — над кнопкой. Ниже реальные размеры 32/48 px на тёмном и светлом '
           'фоне и вид в лаунчере.', font=font(17), fill=(168, 161, 149))
    context = Image.open(context_path).convert('RGB') if context_path else None
    col_w = 380
    for i, (key, title, note, _) in enumerate(STYLES):
        x0 = 40 + i * col_w
        arrow, link = rendered[key]
        d.rounded_rectangle([x0, 110, x0 + col_w - 20, H - 30], radius=14, fill=(24, 26, 27), outline=(58, 54, 44))
        d.text((x0 + 20, 126), f'{i + 1}. {title.upper()}', font=font(26, True), fill=(246, 193, 101))
        words, lines, current = note.split(), [], ''
        for word in words:
            trial = (current + ' ' + word).strip()
            if d.textlength(trial, font=font(14)) > col_w - 60 and current:
                lines.append(current)
                current = word
            else:
                current = trial
        lines.append(current)
        for n, text in enumerate(lines[:2]):
            d.text((x0 + 20, 158 + n * 17), text, font=font(14), fill=(168, 161, 149))
        # Big renders on a mid-dark plate.
        plate = Image.new('RGB', (col_w - 60, 170), (46, 44, 40))
        big_a = arrow['master'].resize((150, 150), Image.LANCZOS)
        big_l = link['master'].resize((150, 150), Image.LANCZOS)
        plate.paste(big_a, (10, 10), big_a)
        plate.paste(big_l, (col_w - 60 - 160, 10), big_l)
        sheet.paste(plate, (x0 + 20, 200))
        # Actual sizes on dark and light.
        for row, bg in enumerate(((20, 21, 20), (226, 222, 212))):
            strip = Image.new('RGB', (col_w - 60, 76), bg)
            px = 12
            for size in (32, 48):
                for img in (arrow['sizes'][size], link['sizes'][size]):
                    strip.paste(img, (px, (76 - size) // 2), img)
                    px += size + 14
            sheet.paste(strip, (x0 + 20, 384 + row * 86))
        # The launcher at 1:1 (100 % display scale, so the 32 px cursor): the
        # arrow over the scene, the link pointer on the play button.
        if context:
            cw, chh = col_w - 60, 420
            crop = context.crop((826, 716 - chh, 826 + cw, 716))
            a32, l32 = arrow['sizes'][32], link['sizes'][32]
            crop.paste(a32, (100, 170), a32)
            crop.paste(l32, (150, chh - 64), l32)
            sheet.paste(crop, (x0 + 20, 570))
    sheet.save(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=HERE)
    parser.add_argument('--styles', default='all')
    parser.add_argument('--preview', type=Path)
    parser.add_argument('--context', type=Path)
    args = parser.parse_args()
    wanted = None if args.styles == 'all' else set(args.styles.split(','))
    rendered = {}
    for key, title, _, draw in STYLES:
        if wanted and key not in wanted:
            continue
        pair = []
        for link in (False, True):
            master, hotspot = draw(link)
            sizes = {s: master.resize((s, s), Image.LANCZOS) for s in SIZES}
            name = 'link' if link else 'arrow'
            folder = args.out / key
            folder.mkdir(parents=True, exist_ok=True)
            write_cur(folder / f'{name}.cur', [sizes[s] for s in SIZES], hotspot)
            sizes[64].save(folder / f'{name}.png')
            pair.append({'master': master, 'sizes': sizes})
        rendered[key] = pair
        print(f'{title}: {args.out / key}')
    if args.preview:
        preview(rendered, args.preview, args.context)
        print(f'preview: {args.preview}')


if __name__ == '__main__':
    main()
