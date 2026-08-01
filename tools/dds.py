"""Minimal DXT1 (BC1) DDS writer.

FS25 warns "raw format" and does CPU mip generation for PNG textures.
The other mods in this workspace ship 512x512 DXT1 icon.dds at ~128KB
with mipMapCount=1, so this produces exactly that. Pillow can write DDS
but only uncompressed (1MB) and segfaults when asked for DXT1, and
there is no texconv/nvcompress on this machine, hence the hand rolled
encoder.

DXT1 stores each 4x4 block as two RGB565 endpoints plus 2-bit indices,
so 8 bytes per 16 pixels = 0.5 bytes/pixel. DXT5 adds an 8-byte alpha
block in front of that, giving 1 byte/pixel and a full alpha ramp.
Endpoints come from the block's bounding box, which is more than good
enough for flat vector-style artwork.

Every texture the mod references ships as DDS, not just the icon: the
GIANTS TestRunner looks up parsed DDS data for each referenced texture
and crashes on a PNG with

    AttributeError: 'NoneType' object has no attribute 'header_dx10'

which is a hard blocker for a ModHub submission.
"""
import struct
from PIL import Image

DDSD_CAPS, DDSD_HEIGHT, DDSD_WIDTH = 0x1, 0x2, 0x4
DDSD_PIXELFORMAT, DDSD_LINEARSIZE = 0x1000, 0x80000
DDPF_FOURCC = 0x4
DDSCAPS_TEXTURE = 0x1000


def _565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def _expand(c):
    r = ((c >> 11) & 0x1F) << 3
    g = ((c >> 5) & 0x3F) << 2
    b = (c & 0x1F) << 3
    return r | (r >> 5), g | (g >> 6), b | (b >> 5)


def _block(px, bx, by, w, h):
    """Encode one 4x4 block to 8 bytes."""
    cols = []
    for y in range(4):
        for x in range(4):
            cols.append(px[min(bx + x, w - 1), min(by + y, h - 1)][:3])

    lo = [min(c[i] for c in cols) for i in range(3)]
    hi = [max(c[i] for c in cols) for i in range(3)]
    c0, c1 = _565(*hi), _565(*lo)

    # c0 > c1 selects the opaque 4-colour mode. If the block is flat the
    # endpoints collide; nudging keeps it out of the 3-colour+alpha mode.
    if c0 < c1:
        c0, c1 = c1, c0
    if c0 == c1:
        if c1 > 0:
            c1 -= 1
        else:
            c0 = 1

    e0, e1 = _expand(c0), _expand(c1)
    pal = [
        e0,
        e1,
        tuple((2 * e0[i] + e1[i]) // 3 for i in range(3)),
        tuple((e0[i] + 2 * e1[i]) // 3 for i in range(3)),
    ]

    bits = 0
    for i, c in enumerate(cols):
        best, bestd = 0, None
        for j, p in enumerate(pal):
            d = (c[0] - p[0]) ** 2 + (c[1] - p[1]) ** 2 + (c[2] - p[2]) ** 2
            if bestd is None or d < bestd:
                best, bestd = j, d
        bits |= best << (2 * i)
    return struct.pack("<HHI", c0, c1, bits)


def _alpha_block(px, bx, by, w, h):
    """Encode one 4x4 alpha block to 8 bytes (DXT5 / BC3 alpha)."""
    vals = []
    for y in range(4):
        for x in range(4):
            vals.append(px[min(bx + x, w - 1), min(by + y, h - 1)][3])

    a0, a1 = max(vals), min(vals)
    if a0 == a1:
        # flat alpha: index 0 everywhere, no interpolation needed
        return struct.pack("<BB", a0, a1) + b"\0" * 6

    # a0 > a1 selects the 8-value mode: a0, a1, then six interpolants
    pal = [a0, a1] + [((7 - i) * a0 + i * a1) // 7 for i in range(1, 7)]

    bits = 0
    for i, v in enumerate(vals):
        best, bestd = 0, None
        for j, pv in enumerate(pal):
            d = abs(v - pv)
            if bestd is None or d < bestd:
                best, bestd = j, d
        bits |= best << (3 * i)

    out = struct.pack("<BB", a0, a1)
    for i in range(6):
        out += bytes([(bits >> (8 * i)) & 0xFF])
    return out


def _header(w, h, size, fourcc):
    flags = DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_LINEARSIZE
    header = bytearray(b"DDS ")
    header += struct.pack("<7I", 124, flags, h, w, size, 0, 1)  # mipMapCount = 1
    header += b"\0" * 44                                       # reserved1[11]
    header += struct.pack("<2I", 32, DDPF_FOURCC) + fourcc
    header += struct.pack("<5I", 0, 0, 0, 0, 0)                 # bit masks unused
    header += struct.pack("<5I", DDSCAPS_TEXTURE, 0, 0, 0, 0)
    assert len(header) == 128, len(header)
    return bytes(header)


def save_dxt5(img, path):
    """BC3: full alpha ramp. Use for anything with transparency."""
    img = img.convert("RGBA")
    w, h = img.size
    assert w % 4 == 0 and h % 4 == 0, "DXT5 needs multiples of 4"
    px = img.load()

    data = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            data += _alpha_block(px, bx, by, w, h)
            data += _block(px, bx, by, w, h)

    with open(path, "wb") as f:
        f.write(_header(w, h, len(data), b"DXT5"))
        f.write(data)
    return 128 + len(data)


def save_auto(img, path):
    """DXT5 when the image actually uses alpha, DXT1 otherwise."""
    rgba = img.convert("RGBA")
    alpha = rgba.getchannel("A")
    lo, hi = alpha.getextrema()
    if lo < 255:
        return save_dxt5(rgba, path), "DXT5"
    return save_dxt1(rgba, path), "DXT1"


def save_dxt1(img, path):
    img = img.convert("RGB")
    w, h = img.size
    assert w % 4 == 0 and h % 4 == 0, "DXT1 needs multiples of 4"
    px = img.load()

    data = bytearray()
    for by in range(0, h, 4):
        for bx in range(0, w, 4):
            data += _block(px, bx, by, w, h)

    with open(path, "wb") as f:
        f.write(_header(w, h, len(data), b"DXT1"))
        f.write(data)
    return 128 + len(data)
