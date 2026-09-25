"""Draw the keyboard/mouse button atlas that replaces the game's controller glyphs.

The game draws every button prompt - hints, menus and the battle-action QTEs -
from one 256x128 DXT5 atlas. glyphs.json holds only the rectangle of each
glyph (measured once from the original, which is never shipped). This script
draws our own icon inside each rectangle, so the game's own texture
coordinates show it unchanged, then writes:

  atlas.png                 the replacement base level, RGBA (our artwork)
  c6a7991246a29b65.c3tex    the full mip chain, BC3, as the GPU plugin loads it
  preview.png               a 4x preview on a dark background

The mapping follows the default PC binds (docs/controls.md). Rerun after
changing either.

Development-time only: needs Pillow (analysis/dev-python) and a Windows font.
"""
import json
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / 'analysis/dev-python'))
from PIL import Image, ImageDraw, ImageFilter, ImageFont  # noqa: E402

SS = 6  # supersampling factor

# Palette: gunmetal keys, cream legends, CoD amber highlight.
KEY_TOP = (96, 100, 98)
KEY_BOTTOM = (40, 42, 41)
KEY_EDGE = (14, 15, 14)
KEY_BEVEL = (150, 152, 146)
LEGEND = (244, 232, 204)
LEGEND_SHADOW = (0, 0, 0)
AMBER = (232, 160, 40)
ACCENT = {'A': (86, 168, 66), 'B': (196, 64, 52), 'X': (66, 120, 196), 'Y': (222, 176, 40)}

# glyph -> what to draw. Keys follow the default binds.
ICONS = {
    'RT': ('mouse', 'left'),        # fire
    'LT': ('mouse', 'right'),       # aim
    'A': ('key', 'SPACE'),          # jump
    'B': ('key', 'C'),              # crouch / back
    'X': ('key', 'F'),              # use / reload
    'Y': ('mouse', 'wheel'),        # switch weapon
    'LB': ('key', '4'),             # smoke grenade
    'RB': ('key', 'G'),             # frag grenade
    # Binoculars. B is bound to D-pad up everywhere, menus included, so the
    # prompt stays true wherever the game shows this single glyph.
    'DPAD_UP': ('key', 'B'),
    'DPAD_RIGHT': ('key', '→'),
    'DPAD_LEFT': ('key', '←'),
    'DPAD_DOWN': ('key', '↓'),
    'START': ('key', 'ESC'),
    'BACK': ('key', 'TAB'),
    'DPAD_LEFTRIGHT': ('pair_h', ('←', '→')),
    'DPAD_UPDOWN': ('pair_v', ('↑', '↓')),
    'DPAD_ALL': ('arrows', None),
    'LS_PRESS': ('key', 'SHIFT'),   # sprint / hold breath
    'RS_PRESS': ('key', 'V'),       # melee
    'LS_MOVE': ('wasd', None),      # move
    'RS_MOVE': ('mouse', 'move'),   # look / stick battle actions
}


def load_font(size):
    for name in ('bahnschrift.ttf', 'arialbd.ttf', 'segoeuib.ttf'):
        path = Path('C:/Windows/Fonts') / name
        if path.is_file():
            font = ImageFont.truetype(str(path), size)
            if name == 'bahnschrift.ttf':
                try:
                    font.set_variation_by_name('Bold SemiCondensed')
                except Exception:  # noqa: BLE001 - static builds lack variations
                    pass
            return font
    return ImageFont.load_default()


def symbol_font(size):
    for name in ('seguisym.ttf', 'segoeuib.ttf', 'arialbd.ttf'):
        path = Path('C:/Windows/Fonts') / name
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return load_font(size)


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new('RGBA', size)
    px = grad.load()
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(w):
            px[x, y] = c
    return grad


def arrow(d, box, direction, colour):
    """A chunky arrow: font arrows are too thin to survive 28 px."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    cx, cy = x0 + w / 2, y0 + h / 2
    length = min(w, h) * 0.86
    head = length * 0.52
    shaft = length * 0.26
    half = length / 2
    # Pointing up, then rotated.
    pts = [(0, -half), (head / 1.1, -half + head), (shaft / 2, -half + head), (shaft / 2, half),
           (-shaft / 2, half), (-shaft / 2, -half + head), (-head / 1.1, -half + head)]
    rot = {'↑': lambda x, y: (x, y), '↓': lambda x, y: (-x, -y),
           '→': lambda x, y: (-y, x), '←': lambda x, y: (y, -x)}[direction]
    d.polygon([(cx + rot(x, y)[0], cy + rot(x, y)[1]) for x, y in pts], fill=colour)


def keycap(canvas, rect, legend, accent=None):
    """A bevelled gunmetal key with a cream legend.

    Keys narrower than ~16 px (the WASD and arrow clusters) get a compact
    style: thin edge, no bevel, and the legend filling most of the key -
    otherwise the margins eat the letter entirely.
    """
    x0, y0, x1, y1 = rect
    w, h = x1 - x0, y1 - y0
    compact = min(w, h) < 16 * SS
    r = int(min(w, h) * (0.18 if compact else 0.22))
    mask = Image.new('L', canvas.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(rect, r, fill=255)
    body = vertical_gradient(canvas.size, KEY_TOP, KEY_BOTTOM)
    canvas.paste(body, (0, 0), mask)
    d = ImageDraw.Draw(canvas)
    edge = max(2, int(SS * (0.6 if compact else 1.0)))
    d.rounded_rectangle(rect, r, outline=KEY_EDGE + (255,), width=edge)
    inset = edge + (SS // 3 if compact else SS // 2)
    if not compact:
        d.rounded_rectangle((x0 + inset, y0 + inset, x1 - inset, y0 + inset + max(2, SS)),
                            max(1, r // 2), fill=KEY_BEVEL + (150,))
    bar_h = 0
    if accent and not compact:
        bar_h = max(SS * 2, h // 7)
        d.rounded_rectangle((x0 + inset + SS, y1 - inset - bar_h, x1 - inset - SS, y1 - inset),
                            max(1, bar_h // 2), fill=accent + (255,))
    margin = SS // 2 if compact else SS * 2
    area = (x0 + inset + margin, y0 + inset + margin * 0.6,
            x1 - inset - margin, y1 - inset - margin * 0.6 - bar_h)
    if legend in ('↑', '↓', '←', '→'):
        shadow_area = tuple(v + SS * 0.6 for v in area)
        arrow(d, shadow_area, legend, LEGEND_SHADOW + (200,))
        arrow(d, area, legend, LEGEND + (255,))
        return
    avail_w, avail_h = area[2] - area[0], area[3] - area[1]
    size = int(avail_h * (1.15 if compact else 0.95))
    while size > 4:
        font = load_font(size)
        bbox = d.textbbox((0, 0), legend, font=font)
        if bbox[2] - bbox[0] <= avail_w and bbox[3] - bbox[1] <= avail_h:
            break
        size -= 1
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    cx = area[0] + (avail_w - tw) / 2 - bbox[0]
    cy = area[1] + (avail_h - th) / 2 - bbox[1]
    d.text((cx + SS * 0.5, cy + SS * 0.6), legend, font=font, fill=LEGEND_SHADOW + (200,))
    d.text((cx, cy), legend, font=font, fill=LEGEND + (255,))


def mouse(canvas, rect, mode):
    """A mouse silhouette with the relevant part lit in amber."""
    x0, y0, x1, y1 = rect
    w, h = x1 - x0, y1 - y0
    mw = int(min(w * 0.72, h * 0.62))
    mh = int(h * 0.94)
    mx0 = x0 + (w - mw) // 2
    my0 = y0 + (h - mh) // 2
    body = (mx0, my0, mx0 + mw, my0 + mh)
    d = ImageDraw.Draw(canvas)
    edge = max(2, SS)
    radius = mw // 2
    mask = Image.new('L', canvas.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(body, radius, fill=255)
    canvas.paste(vertical_gradient(canvas.size, KEY_TOP, KEY_BOTTOM), (0, 0), mask)
    split_y = my0 + int(mh * 0.42)
    cx = mx0 + mw // 2
    # Lit button halves.
    if mode in ('left', 'right'):
        half = Image.new('L', canvas.size, 0)
        hd = ImageDraw.Draw(half)
        hd.rounded_rectangle(body, radius, fill=255)
        hd.rectangle((0, split_y, canvas.size[0], canvas.size[1]), fill=0)
        if mode == 'left':
            hd.rectangle((cx, 0, canvas.size[0], canvas.size[1]), fill=0)
        else:
            hd.rectangle((0, 0, cx, canvas.size[1]), fill=0)
        canvas.paste(Image.new('RGBA', canvas.size, AMBER + (255,)), (0, 0), half)
    d.rounded_rectangle(body, radius, outline=KEY_EDGE + (255,), width=edge)
    d.line((mx0 + edge, split_y, mx0 + mw - edge, split_y), fill=KEY_EDGE + (255,), width=edge)
    d.line((cx, my0 + edge, cx, split_y), fill=KEY_EDGE + (255,), width=edge)
    # Wheel.
    ww = max(SS * 2, mw // 6)
    wheel = (cx - ww // 2, my0 + int(mh * 0.12), cx + ww // 2, my0 + int(mh * 0.34))
    d.rounded_rectangle(wheel, ww // 2,
                        fill=(AMBER if mode == 'wheel' else KEY_BEVEL) + (255,),
                        outline=KEY_EDGE + (255,), width=max(1, SS // 2))
    if mode == 'wheel':
        # Scroll triangles in the space beside the mouse, both sides.
        side = (w - mw) / 2
        tri = side * 0.78
        for ax in (x0 + side / 2, x1 - side / 2):
            up_y = my0 + mh * 0.20
            down_y = my0 + mh * 0.44
            d.polygon([(ax - tri / 2, up_y + tri / 2), (ax + tri / 2, up_y + tri / 2), (ax, up_y - tri / 2)],
                      fill=LEGEND + (255,))
            d.polygon([(ax - tri / 2, down_y - tri / 2), (ax + tri / 2, down_y - tri / 2), (ax, down_y + tri / 2)],
                      fill=LEGEND + (255,))
    if mode == 'move':
        # Four chevrons around the mouse: look / move the pointer.
        c = (mx0 + mw // 2, my0 + mh // 2)
        reach_x = mw // 2 + SS * 3
        s = SS * 2
        for dx, dy in ((1, 0), (-1, 0)):
            tx = c[0] + dx * reach_x
            d.polygon([(tx, c[1] - s), (tx, c[1] + s), (tx + dx * s, c[1])], fill=LEGEND + (255,))


def wasd(canvas, rect):
    """Four mini keys: W over A S D."""
    x0, y0, x1, y1 = rect
    w, h = x1 - x0, y1 - y0
    gap = SS // 2
    kw = (w - 2 * gap) // 3
    kh = (h - gap) // 2
    top = (x0 + kw + gap, y0, x0 + 2 * kw + gap, y0 + kh)
    keycap(canvas, top, 'W')
    for i, letter in enumerate('ASD'):
        kx = x0 + i * (kw + gap)
        keycap(canvas, (kx, y0 + kh + gap, kx + kw, y1), letter)


def arrows_cluster(canvas, rect):
    x0, y0, x1, y1 = rect
    w, h = x1 - x0, y1 - y0
    gap = SS // 2
    kw = (w - 2 * gap) // 3
    kh = (h - gap) // 2
    keycap(canvas, (x0 + kw + gap, y0, x0 + 2 * kw + gap, y0 + kh), '↑')
    for i, s in enumerate('←↓→'):
        kx = x0 + i * (kw + gap)
        keycap(canvas, (kx, y0 + kh + gap, kx + kw, y1), s)


def pair(canvas, rect, legends, horizontal):
    x0, y0, x1, y1 = rect
    gap = SS // 2
    if horizontal:
        half = (x1 - x0 - gap) // 2
        keycap(canvas, (x0, y0, x0 + half, y1), legends[0])
        keycap(canvas, (x1 - half, y0, x1, y1), legends[1])
    else:
        half = (y1 - y0 - gap) // 2
        keycap(canvas, (x0, y0, x1, y0 + half), legends[0])
        keycap(canvas, (x0, y1 - half, x1, y1), legends[1])


def draw_glyph(name, box):
    w, h = box[2] - box[0], box[3] - box[1]
    canvas = Image.new('RGBA', (w * SS, h * SS), (0, 0, 0, 0))
    # Clusters use the whole rectangle; single icons keep a pixel of air.
    kind = ICONS[name][0]
    pad = SS // 3 if kind in ('wasd', 'arrows', 'pair_h', 'pair_v') else SS
    rect = (pad, pad, w * SS - pad, h * SS - pad)
    kind, arg = ICONS[name]
    if kind == 'key':
        keycap(canvas, rect, arg, ACCENT.get(name))
    elif kind == 'mouse':
        mouse(canvas, rect, arg)
    elif kind == 'wasd':
        wasd(canvas, rect)
    elif kind == 'arrows':
        arrows_cluster(canvas, rect)
    elif kind == 'pair_h':
        pair(canvas, rect, arg, True)
    elif kind == 'pair_v':
        pair(canvas, rect, arg, False)
    # Soft drop shadow like the originals, then downsample.
    alpha = canvas.getchannel('A').filter(ImageFilter.GaussianBlur(SS * 0.8))
    shadow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    shadow.putalpha(alpha.point(lambda a: int(a * 0.55)))
    base = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    base.alpha_composite(shadow, (SS // 2, SS))
    base.alpha_composite(canvas)
    return base.resize((w, h), Image.LANCZOS)


# --- BC3 --------------------------------------------------------------------
def to565(c):
    return ((c[0] * 31 + 127) // 255 << 11) | ((c[1] * 63 + 127) // 255 << 5) | ((c[2] * 31 + 127) // 255)


def from565(v):
    r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
    return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)


def encode_bc3_block(texels):
    # Alpha: 8-value interpolation between min and max.
    alphas = [t[3] for t in texels]
    a0, a1 = max(alphas), min(alphas)
    if a0 == a1:
        alpha_bits = 0
    else:
        table = [a0, a1] + [((6 - i) * a0 + (i + 1) * a1) // 7 for i in range(6)]
        alpha_bits = 0
        for i, a in enumerate(alphas):
            best = min(range(8), key=lambda k: abs(table[k] - a))
            alpha_bits |= best << (3 * i)
    alpha_block = bytes([a0, a1]) + alpha_bits.to_bytes(6, 'little')
    # Colour: bounding box of the visible texels, inset slightly.
    visible = [t for t in texels if t[3] > 8] or texels
    lo = [min(t[i] for t in visible) for i in range(3)]
    hi = [max(t[i] for t in visible) for i in range(3)]
    inset = [(hi[i] - lo[i]) / 16 for i in range(3)]
    lo = [int(lo[i] + inset[i]) for i in range(3)]
    hi = [int(hi[i] - inset[i]) for i in range(3)]
    c0, c1 = to565(hi), to565(lo)
    if c0 < c1:
        c0, c1 = c1, c0
    if c0 == c1:
        indices = 0
    else:
        p0, p1 = from565(c0), from565(c1)
        palette = [p0, p1,
                   tuple((2 * a + b) // 3 for a, b in zip(p0, p1)),
                   tuple((a + 2 * b) // 3 for a, b in zip(p0, p1))]
        indices = 0
        for i, t in enumerate(texels):
            best = min(range(4), key=lambda k: sum((palette[k][j] - t[j]) ** 2 for j in range(3)))
            indices |= best << (2 * i)
    return alpha_block + struct.pack('<HHI', c0, c1, indices)


def encode_bc3(image):
    w, h = image.size
    px = image.load()
    bw, bh = (w + 3) // 4, (h + 3) // 4
    out = bytearray()
    for by in range(bh):
        for bx in range(bw):
            texels = []
            for y in range(4):
                for x in range(4):
                    sx = min(bx * 4 + x, w - 1)
                    sy = min(by * 4 + y, h - 1)
                    texels.append(px[sx, sy])
            out += encode_bc3_block(texels)
    return bytes(out), bw, bh


def main():
    spec = json.loads((HERE / 'glyphs.json').read_text(encoding='utf-8'))
    atlas = Image.new('RGBA', (spec['width'], spec['height']), (0, 0, 0, 0))
    for glyph in spec['glyphs']:
        box = glyph['box']
        atlas.alpha_composite(draw_glyph(glyph['name'], box), (box[0], box[1]))
    atlas.save(HERE / 'atlas.png')

    preview = Image.new('RGBA', atlas.size, (38, 40, 36, 255))
    preview.alpha_composite(atlas)
    preview.resize((atlas.width * 4, atlas.height * 4), Image.NEAREST).save(HERE / 'preview.png')

    # Mip chain down to 1x1, box-filtered with premultiplied alpha so edges
    # do not darken.
    levels = []
    level = atlas
    while True:
        levels.append(level)
        if level.width == 1 and level.height == 1:
            break
        nw, nh = max(1, level.width // 2), max(1, level.height // 2)
        premul = level.convert('RGBa').resize((nw, nh), Image.BOX)
        level = premul.convert('RGBA')
    blob = bytearray(b'C3TX')
    blob += struct.pack('<IIIII', 1, 3, atlas.width, atlas.height, len(levels))
    for img in levels:
        data, bw, bh = encode_bc3(img)
        blob += struct.pack('<IIIII', img.width, img.height, bw, bh, len(data))
        blob += data
    target = HERE / f"{spec['atlas_hash']}.c3tex"
    target.write_bytes(bytes(blob))
    print(f'atlas.png, preview.png and {target.name}: {len(levels)} BC3 levels, {len(blob)} bytes')


if __name__ == '__main__':
    main()
