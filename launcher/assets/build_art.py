"""Draw the launcher artwork: hero.jpg (background) and emblem.png (icon).

Everything is painted here from primitives - gradients, value noise and
polygons - so the launcher carries no third-party or game-derived imagery.
The seed is fixed, so a rerun reproduces the same composition.

usage: build_art.py            (writes next to this script)
"""
import math
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / 'analysis/dev-python'))
from PIL import Image, ImageChops, ImageDraw, ImageFilter  # noqa: E402

W, H = 1920, 1172          # the launcher window is 1180x720
HORIZON = 0.705
SUN = (0.70, 0.64)
rng = random.Random(1944)


# ------------------------------------------------------------------ helpers

def lerp(a, b, t):
    return a + (b - a) * t


def mix(c0, c1, t):
    return tuple(int(round(lerp(x, y, t))) for x, y in zip(c0, c1))


def vertical_gradient(stops, size=(W, H)):
    w, h = size
    column = Image.new('RGB', (1, h))
    px = column.load()
    for y in range(h):
        t = y / (h - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                px[0, y] = mix(c0, c1, (t - p0) / max(1e-6, p1 - p0))
                break
    return column.resize((w, h), Image.BILINEAR)


def radial_mask(size, center, radii, power=2.0, strength=1.0):
    """L mask: 255*strength at center, falling to 0 at the ellipse radii."""
    w, h = size
    small = Image.radial_gradient('L').point(
        lambda v: int(255 * strength * max(0.0, 1.0 - v / 180.0) ** power))
    mask = Image.new('L', size, 0)
    rx, ry = radii
    blob = small.resize((int(rx * 2), int(ry * 2)), Image.BICUBIC)
    mask.paste(blob, (int(center[0] - rx), int(center[1] - ry)))
    return mask


def value_noise(size, cell, seed):
    local = random.Random(seed)
    w, h = size
    gw, gh = max(2, w // cell + 3), max(2, h // cell + 3)
    small = Image.frombytes('L', (gw, gh), bytes(local.randrange(256) for _ in range(gw * gh)))
    return small.resize((gw * cell, gh * cell), Image.BICUBIC).crop((cell, cell, cell + w, cell + h))


def fractal_noise(size, base_cell, octaves, seed, falloff=0.55):
    acc = None
    total = 0.0
    amp = 1.0
    cell = base_cell
    for octave in range(octaves):
        layer = value_noise(size, max(2, int(cell)), seed * 31 + octave)
        if acc is None:
            acc = layer
        else:
            acc = Image.blend(acc, layer, amp / (total + amp))
        total += amp
        amp *= falloff
        cell /= 2
    return acc


def screen(base, color, mask):
    layer = Image.composite(Image.new('RGB', base.size, color), Image.new('RGB', base.size, 0), mask)
    return ImageChops.screen(base, layer)


def paint(base, color, mask):
    return Image.composite(Image.new('RGB', base.size, color), base, mask)


def scale_mask(mask, factor):
    return mask.point(lambda v: int(v * factor))


# -------------------------------------------------------------------- scene

def sky():
    img = vertical_gradient([
        (0.00, (11, 14, 17)),
        (0.30, (27, 31, 32)),
        (0.50, (58, 50, 40)),
        (0.62, (122, 80, 42)),
        (HORIZON, (176, 108, 48)),
        (0.78, (70, 44, 26)),
        (1.00, (14, 12, 10)),
    ])
    sx, sy = SUN[0] * W, SUN[1] * H
    img = screen(img, (255, 150, 60), radial_mask((W, H), (sx, sy), (1300, 700), 2.4, 0.75))
    img = screen(img, (255, 205, 130), radial_mask((W, H), (sx, sy), (360, 220), 2.2, 0.85))
    img = screen(img, (255, 236, 200), radial_mask((W, H), (sx, sy), (70, 70), 1.4, 0.9))
    return img


def god_rays(img):
    sx, sy = SUN[0] * W, SUN[1] * H
    mask = Image.new('L', (W, H), 0)
    draw = ImageDraw.Draw(mask)
    for _ in range(14):
        angle = rng.uniform(math.radians(185), math.radians(355))
        spread = rng.uniform(0.012, 0.035)
        length = rng.uniform(900, 1600)
        a0, a1 = angle - spread, angle + spread
        draw.polygon([(sx, sy),
                      (sx + math.cos(a0) * length, sy + math.sin(a0) * length),
                      (sx + math.cos(a1) * length, sy + math.sin(a1) * length)],
                     fill=rng.randrange(18, 42))
    mask = mask.filter(ImageFilter.GaussianBlur(22))
    return screen(img, (255, 170, 90), mask)


def smoke(img):
    noise = fractal_noise((W, H), 260, 6, 7)
    density = noise.point(lambda v: max(0, min(255, int((v - 112) * 3.4))))
    # Heavy near the horizon, thinning upwards, none below the ground line.
    band = vertical_gradient([(0.0, (100, 100, 100)), (0.45, (180, 180, 180)), (0.66, (235, 235, 235)),
                              (0.74, (120, 120, 120)), (0.80, (0, 0, 0)), (1.0, (0, 0, 0))]).convert('L')
    density = ImageChops.multiply(density, band).filter(ImageFilter.GaussianBlur(3))
    sx, sy = SUN[0] * W, SUN[1] * H
    lit = radial_mask((W, H), (sx, sy), (1100, 640), 1.4, 1.0)
    color = Image.composite(Image.new('RGB', (W, H), (214, 130, 62)), Image.new('RGB', (W, H), (44, 40, 37)), lit)
    return Image.composite(color, img, scale_mask(density, 0.8))


def smoke_column(img, x, base_y, height, lean, seed):
    """A rising plume: noise shaped by a widening, drifting column."""
    local = random.Random(seed)
    mask = Image.new('L', (W, H), 0)
    draw = ImageDraw.Draw(mask)
    steps = 60
    for i in range(steps):
        t = i / (steps - 1)
        cx = x + lean * t * t * height + math.sin(t * 5 + seed) * 14 * t
        cy = base_y - t * height
        r = 10 + 120 * t ** 1.3
        draw.ellipse([cx - r, cy - r * 0.8, cx + r, cy + r * 0.8], fill=int(210 * (1 - t) ** 0.7))
    mask = mask.filter(ImageFilter.GaussianBlur(18))
    texture = fractal_noise((W, H), 90, 4, seed).point(lambda v: max(0, min(255, (v - 70) * 2)))
    mask = ImageChops.multiply(mask, texture)
    shade = Image.composite(Image.new('RGB', (W, H), (92, 72, 58)), Image.new('RGB', (W, H), (26, 24, 23)),
                            radial_mask((W, H), (SUN[0] * W, SUN[1] * H), (700, 500), 1.5, 1.0))
    return Image.composite(shade, img, mask)


def town(img):
    """Distant ruined village with a church steeple, softened by haze."""
    ground = int(HORIZON * H) + 6
    mask = Image.new('L', (W, H), 0)
    draw = ImageDraw.Draw(mask)
    x = -20
    while x < W + 40:
        w = rng.randint(34, 120)
        h = rng.randint(22, 86)
        top = ground - h
        kind = rng.random()
        if kind < 0.35:
            peak = top - rng.randint(14, 34)
            draw.polygon([(x, ground), (x, top), (x + w / 2, peak), (x + w, top), (x + w, ground)], fill=255)
        elif kind < 0.7:
            points = [(x, ground), (x, top)]
            for k in range(1, 6):
                points.append((x + w * k / 6, top + rng.randint(-10, 26)))
            points += [(x + w, top + rng.randint(0, 20)), (x + w, ground)]
            draw.polygon(points, fill=255)
        else:
            draw.rectangle([x, top, x + w, ground], fill=255)
            if rng.random() < 0.5:
                cx = x + rng.randint(6, max(7, w - 10))
                draw.rectangle([cx, top - rng.randint(8, 18), cx + 6, top], fill=255)
        x += w - rng.randint(0, 14)
    # Church: nave, tower, spire (the spire tip is broken off).
    cx = int(0.33 * W)
    draw.rectangle([cx - 90, ground - 70, cx + 40, ground], fill=255)
    draw.polygon([(cx - 90, ground - 70), (cx - 25, ground - 104), (cx + 40, ground - 70)], fill=255)
    draw.rectangle([cx + 30, ground - 190, cx + 72, ground], fill=255)
    draw.polygon([(cx + 26, ground - 190), (cx + 51, ground - 300), (cx + 58, ground - 282),
                  (cx + 62, ground - 272), (cx + 76, ground - 190)], fill=255)
    # Windows punched back out of the tower.
    draw.rectangle([cx + 44, ground - 170, cx + 58, ground - 146], fill=0)
    # The far field the village stands on.
    draw.rectangle([0, ground - 2, W, H], fill=255)
    haze = Image.composite(Image.new('RGB', (W, H), (92, 64, 44)), Image.new('RGB', (W, H), (48, 38, 32)),
                           radial_mask((W, H), (SUN[0] * W, SUN[1] * H), (800, 300), 1.2, 1.0))
    img = Image.composite(haze, img, mask.filter(ImageFilter.GaussianBlur(1.3)))
    # A few lit windows / fires.
    glow = Image.new('L', (W, H), 0)
    gdraw = ImageDraw.Draw(glow)
    for _ in range(9):
        fx = rng.randint(80, W - 80)
        fy = ground - rng.randint(4, 30)
        gdraw.ellipse([fx - 3, fy - 3, fx + 3, fy + 3], fill=255)
    img = screen(img, (255, 120, 40), glow.filter(ImageFilter.GaussianBlur(6)))
    return screen(img, (255, 190, 120), glow.filter(ImageFilter.GaussianBlur(1.5)))


def hill_line(base, amplitude, seed):
    local = random.Random(seed)
    waves = [(local.uniform(0.6, 2.2), local.uniform(0, 6.28), local.uniform(0.3, 1.0)) for _ in range(4)]
    def y_at(x):
        t = x / W * math.tau
        return base + amplitude * sum(a * math.sin(t * f + p) for f, p, a in waves) / len(waves)
    return y_at


def tank(draw, x, y, s, color):
    """Knocked-out medium tank facing left, drawn at scale s from its ground point."""
    def P(px, py):
        return (x + px * s, y + py * s)
    draw.rounded_rectangle([P(-120, -34), P(120, 0)], radius=int(17 * s), fill=color)          # tracks
    draw.polygon([P(-128, -34), P(-100, -62), P(104, -62), P(126, -34)], fill=color)            # hull
    draw.polygon([P(-60, -62), P(-44, -96), P(40, -100), P(62, -62)], fill=color)               # turret
    draw.rounded_rectangle([P(-22, -118), P(18, -98)], radius=int(6 * s), fill=color)           # hatch
    draw.polygon([P(-44, -86), P(-190, -104), P(-190, -96), P(-44, -76)], fill=color)           # barrel, drooped
    draw.rectangle([P(-196, -106), P(-184, -94)], fill=color)                                   # muzzle


def czech_hedgehog(draw, x, y, s, color):
    beams = [((-60, -8), (58, -104)), ((62, -6), (-52, -110)), ((-6, 6), (8, -118))]
    for (x0, y0), (x1, y1) in beams:
        draw.line([(x + x0 * s, y + y0 * s), (x + x1 * s, y + y1 * s)], fill=color, width=max(3, int(15 * s)))


def barbed_wire(draw, posts, color):
    for (px, py, h, tilt) in posts:
        draw.line([(px, py), (px + tilt, py - h)], fill=color, width=7)
    for (x0, y0, h0, t0), (x1, y1, h1, t1) in zip(posts, posts[1:]):
        for frac in (0.35, 0.62, 0.9):
            ax, ay = x0 + t0 * frac, y0 - h0 * frac
            bx, by = x1 + t1 * frac, y1 - h1 * frac
            sag = 10 + 8 * frac
            points = []
            for i in range(41):
                t = i / 40
                points.append((lerp(ax, bx, t), lerp(ay, by, t) + sag * 4 * t * (1 - t)))
            draw.line(points, fill=color, width=2)
            for i in range(2, 40, 3):
                cx, cy = points[i]
                draw.line([(cx - 4, cy - 4), (cx + 4, cy + 4)], fill=color, width=2)
                draw.line([(cx - 4, cy + 4), (cx + 4, cy - 4)], fill=color, width=2)


def concertina(draw, x0, x1, y, color):
    x = x0
    while x < x1:
        r = rng.uniform(20, 28)
        draw.ellipse([x - r, y - 2 * r + rng.uniform(-3, 3), x + r, y], outline=color, width=2)
        x += r * 0.55


def foreground(img):
    # Middle ground: rolling field with shattered trees, poles and a tank.
    mid = Image.new('L', (W, H), 0)
    draw = ImageDraw.Draw(mid)
    y_mid = hill_line(0.775 * H, 70, 3)
    draw.polygon([(0, H)] + [(x, y_mid(x)) for x in range(0, W + 1, 8)] + [(W, H)], fill=255)
    for _ in range(7):
        tx = rng.choice([rng.uniform(40, 0.36 * W), rng.uniform(0.5 * W, 0.66 * W)])
        ty = y_mid(tx)
        height = rng.uniform(70, 170)
        draw.line([(tx, ty), (tx + rng.uniform(-10, 10), ty - height)], fill=255, width=rng.randint(5, 9))
        for _ in range(rng.randint(2, 4)):
            by = ty - height * rng.uniform(0.45, 0.95)
            direction = rng.choice([-1, 1])
            draw.line([(tx, by), (tx + direction * rng.uniform(22, 60), by - rng.uniform(14, 40))], fill=255, width=3)
    poles = [(0.05 * W + i * 250, rng.uniform(-10, 12)) for i in range(4)]
    tops = []
    for px, tilt in poles:
        py = y_mid(px) + 4
        draw.line([(px, py), (px + tilt, py - 150)], fill=255, width=6)
        draw.line([(px + tilt - 22, py - 138), (px + tilt + 22, py - 140)], fill=255, width=4)
        tops.append((px + tilt, py - 138))
    for (ax, ay), (bx, by) in zip(tops, tops[1:]):
        draw.line([(lerp(ax, bx, i / 30), lerp(ay, by, i / 30) + 26 * 4 * (i / 30) * (1 - i / 30))
                   for i in range(31)], fill=255, width=2)
    tank(draw, 0.80 * W, y_mid(0.80 * W) + 10, 1.15, 255)
    mid = mid.rotate(0, resample=Image.BICUBIC).filter(ImageFilter.GaussianBlur(0.8))
    img = paint(img, (25, 20, 16), mid)

    # Near ground: dark lip, hedgehogs, barbed wire.
    near = Image.new('L', (W, H), 0)
    draw = ImageDraw.Draw(near)
    y_near = hill_line(0.885 * H, 60, 11)
    draw.polygon([(0, H)] + [(x, y_near(x) + rng.uniform(-2, 2)) for x in range(0, W + 1, 6)] + [(W, H)], fill=255)
    for hx, s in ((0.07 * W, 1.25), (0.20 * W, 0.85), (0.93 * W, 1.4)):
        czech_hedgehog(draw, hx, y_near(hx) + 12, s, 255)
    posts = []
    for i in range(6):
        px = 0.46 * W + i * 150 + rng.uniform(-20, 20)
        posts.append((px, y_near(px) + 8, rng.uniform(92, 128), rng.uniform(-14, 10)))
    barbed_wire(draw, posts, 255)
    concertina(draw, 0.24 * W, 0.44 * W, y_near(0.34 * W) + 10, 255)
    img = paint(img, (9, 8, 7), near.filter(ImageFilter.GaussianBlur(0.6)))
    return img


def embers(img):
    glow = Image.new('L', (W, H), 0)
    core = Image.new('L', (W, H), 0)
    gdraw = ImageDraw.Draw(glow)
    cdraw = ImageDraw.Draw(core)
    for _ in range(64):
        x = rng.gauss(0.60 * W, 0.18 * W)
        y = H * (0.95 - 0.5 * rng.random() ** 1.8)
        r = rng.choice([1, 1, 1, 1, 2, 2])
        gdraw.ellipse([x - r * 3, y - r * 3, x + r * 3, y + r * 3], fill=rng.randrange(60, 160))
        cdraw.ellipse([x - r, y - r, x + r, y + r], fill=255)
    img = screen(img, (255, 110, 30), glow.filter(ImageFilter.GaussianBlur(4)))
    return screen(img, (255, 200, 120), core.filter(ImageFilter.GaussianBlur(0.7)))


def finish(img):
    # Keep the left side calm for the launcher's text.
    shade = Image.linear_gradient('L').rotate(90, expand=True).resize((W, H))
    shade = shade.transpose(Image.FLIP_LEFT_RIGHT).point(lambda v: int(255 - 150 * max(0.0, (v / 255 - 0.35) / 0.65) ** 1.4))
    img = ImageChops.multiply(img, Image.merge('RGB', (shade, shade, shade)))
    # Vignette.
    vignette = radial_mask((W, H), (W / 2, H / 2), (W * 0.95, H * 1.0), 0.8, 1.0)
    vignette = vignette.point(lambda v: 90 + int(v * 165 / 255))
    img = ImageChops.multiply(img, Image.merge('RGB', (vignette, vignette, vignette)))
    # Film grain (deterministic).
    grain = value_noise((W, H), 1, 99)
    img = ImageChops.add(img, Image.merge('RGB', (grain, grain, grain)).point(lambda v: 128 + (v - 128) // 9), 1.0, -128)
    return img


def hero():
    img = sky()
    img = god_rays(img)
    img = smoke(img)
    img = town(img)
    ground = int(HORIZON * H)
    img = smoke_column(img, 0.52 * W, ground - 20, 520, 0.35, 5)
    img = smoke_column(img, 0.18 * W, ground - 10, 380, 0.5, 8)
    img = foreground(img)
    img = embers(img)
    return finish(img)


# ------------------------------------------------------------------- emblem

def emblem(size=256, ss=4):
    S = size * ss
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    c = S / 2
    r = S * 0.47
    draw.ellipse([c - r, c - r, c + r, c + r], fill=(200, 150, 62, 255))
    r2 = r * 0.9
    disc = vertical_gradient([(0, (86, 94, 44)), (1, (36, 40, 18))], (S, S)).convert('RGBA')
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).ellipse([c - r2, c - r2, c + r2, c + r2], fill=255)
    img.paste(disc, (0, 0), mask)
    r3 = r * 0.83
    draw.ellipse([c - r3, c - r3, c + r3, c + r3], outline=(200, 150, 62, 255), width=int(S * 0.008))
    # Bevelled five-point star: each point split into a light and a dark half.
    outer, inner = r * 0.7, r * 0.7 * 0.382
    cy = c + r * 0.03
    for k in range(5):
        a = -math.pi / 2 + k * 2 * math.pi / 5
        tip = (c + outer * math.cos(a), cy + outer * math.sin(a))
        left = (c + inner * math.cos(a - math.pi / 5), cy + inner * math.sin(a - math.pi / 5))
        right = (c + inner * math.cos(a + math.pi / 5), cy + inner * math.sin(a + math.pi / 5))
        draw.polygon([(c, cy), left, tip], fill=(246, 206, 120, 255))
        draw.polygon([(c, cy), tip, right], fill=(176, 124, 48, 255))
    return img.resize((size, size), Image.LANCZOS)


def main():
    art = hero()
    art.save(HERE / 'hero.jpg', quality=88, optimize=True, progressive=True)
    emblem().save(HERE / 'emblem.png', optimize=True)
    for name in ('hero.jpg', 'emblem.png'):
        print(f'{name}: {(HERE / name).stat().st_size} bytes')


if __name__ == '__main__':
    main()
