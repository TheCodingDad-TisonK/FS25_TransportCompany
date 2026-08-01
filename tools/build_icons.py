"""Build the Transport Company textures from one source of truth.

  icon_source.png              clean artwork, no background (fed to the
                               house applyIconBg.js at 512)
  store_transportCompanyHq.png the HQ depot building, 256, on FS25 bg
  tab_transportCompany.png     flat light silhouette for the PDA tab

Everything is drawn at 4x and downsampled so edges stay clean.
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

S = 4
W = H = 1024
def R(v): return int(round(v * S))
SZ = (R(W), R(H))
FB = "C:/Windows/Fonts/seguibl.ttf"
BG = os.path.expanduser("~/.claude/fs25_icon_bg.png")  # house standard backdrop

AMBER       = (245, 179,  53, 255)
AMBER_LIGHT = (255, 212, 124, 255)
AMBER_DARK  = (201, 137,  28, 255)
AMBER_DEEP  = (146,  95,  14, 255)
INK         = ( 22,  25,  32, 255)
CHASSIS     = ( 47,  53,  66, 255)
WALL        = ( 58,  66,  82, 255)
WALL_LIGHT  = ( 78,  88, 108, 255)
WALL_DARK   = ( 38,  44,  56, 255)
TYRE        = ( 30,  34,  43, 255)
TYRE_EDGE   = ( 14,  16,  21, 255)
GLASS       = (132, 184, 216, 255)
GLASS_DARK  = ( 84, 128, 158, 255)
WHITE       = (240, 244, 250, 255)


def rr(dr, box, rad, fill, outline=None, width=0):
    dr.rounded_rectangle([R(box[0]), R(box[1]), R(box[2]), R(box[3])],
                         radius=R(rad), fill=fill, outline=outline,
                         width=R(width) if width else 0)


def track(dr, text, font, cx, y, fill, extra):
    ws = [dr.textlength(c, font=font) for c in text]
    x = cx - (sum(ws) + extra * (len(text) - 1)) / 2
    for c, w in zip(text, ws):
        dr.text((x, y), c, font=font, fill=fill)
        x += w + extra


def crop(img, pad=18):
    bb = img.getbbox()
    return img.crop((max(0, bb[0] - pad), max(0, bb[1] - pad),
                     min(img.width, bb[2] + pad), min(img.height, bb[3] + pad)))


# -- the truck --------------------------------------------------------
def render_truck(wordmark=True):
    GROUND, WHEEL_R, AXLE_Y = 660, 64, 596
    TRL = (74, 232, 540, 566)
    CAB = (566, 286, 884, 566)
    WHEELS = [156, 274, 650, 830]

    img = Image.new("RGBA", SZ, (0, 0, 0, 0))
    body = Image.new("RGBA", SZ, (0, 0, 0, 0))
    b = ImageDraw.Draw(body)

    rr(b, (96, 558, 876, 586), 8, CHASSIS)
    rr(b, (548, 532, 640, 570), 6, CHASSIS)
    rr(b, TRL, 14, AMBER, outline=INK, width=5)
    rr(b, (TRL[0] + 11, TRL[1] + 10, TRL[2] - 11, TRL[1] + 52), 8, AMBER_LIGHT)
    rr(b, (TRL[0] + 9, TRL[3] - 58, TRL[2] - 9, TRL[3] - 11), 8, AMBER_DARK)
    for px in (206, 330, 452):
        b.rectangle([R(px), R(TRL[1] + 18), R(px + 6), R(TRL[3] - 18)], fill=AMBER_DEEP)
    b.rectangle([R(TRL[0] + 20), R(TRL[1] + 18), R(TRL[0] + 26), R(TRL[3] - 18)],
                fill=AMBER_DEEP)

    rr(b, CAB, 16, AMBER, outline=INK, width=5)
    rr(b, (CAB[0] + 11, CAB[1] + 10, CAB[2] - 11, CAB[1] + 44), 8, AMBER_LIGHT)
    rr(b, (CAB[0] + 9, CAB[3] - 52, CAB[2] - 9, CAB[3] - 11), 8, AMBER_DARK)
    rr(b, (CAB[0] + 34, CAB[1] + 62, 700, CAB[1] + 168), 8, GLASS_DARK)
    b.polygon([(R(716), R(CAB[1] + 62)), (R(CAB[2] - 26), R(CAB[1] + 62)),
               (R(CAB[2] - 26), R(CAB[1] + 168)), (R(716), R(CAB[1] + 168))], fill=GLASS)
    b.rectangle([R(702), R(CAB[1] + 62), R(714), R(CAB[1] + 168)], fill=INK)
    rr(b, (CAB[0] + 8, CAB[3] - 34, CAB[2] - 8, CAB[3] - 6), 7, CHASSIS)
    rr(b, (CAB[2] - 60, CAB[3] - 86, CAB[2] - 24, CAB[3] - 62), 6, WHITE)
    rr(b, (CAB[2] - 60, CAB[3] - 58, CAB[2] - 40, CAB[3] - 44), 4, AMBER_LIGHT)
    rr(b, (CAB[0] + 26, CAB[1] + 190, CAB[2] - 96, CAB[1] + 206), 6, AMBER_DEEP)

    # wheel arches, masked to the body so they cut in instead of haloing
    arch = Image.new("L", SZ, 0)
    ad = ImageDraw.Draw(arch)
    for wx in WHEELS:
        ad.ellipse([R(wx - WHEEL_R - 12), R(AXLE_Y - WHEEL_R - 12),
                    R(wx + WHEEL_R + 12), R(AXLE_Y + WHEEL_R + 12)], fill=255)
    body.paste(Image.new("RGBA", SZ, INK), (0, 0),
               ImageChops.multiply(body.getchannel("A"), arch))

    # tight per-wheel contact shadows: one broad ellipse just hazed the
    # near-black FS25 plate texture behind the truck
    shadow = Image.new("RGBA", SZ, (0, 0, 0, 0))
    sh = ImageDraw.Draw(shadow)
    for wx in WHEELS:
        sh.ellipse([R(wx - 62), R(GROUND - 9), R(wx + 62), R(GROUND + 15)],
                   fill=(0, 0, 0, 205))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(R(7))))
    img.alpha_composite(body)

    d = ImageDraw.Draw(img)
    for wx in WHEELS:
        d.ellipse([R(wx - WHEEL_R), R(AXLE_Y - WHEEL_R),
                   R(wx + WHEEL_R), R(AXLE_Y + WHEEL_R)],
                  fill=TYRE, outline=TYRE_EDGE, width=R(4))
        d.ellipse([R(wx - 29), R(AXLE_Y - 29), R(wx + 29), R(AXLE_Y + 29)],
                  fill=AMBER, outline=AMBER_DEEP, width=R(3))
        d.ellipse([R(wx - 10), R(AXLE_Y - 10), R(wx + 10), R(AXLE_Y + 10)], fill=AMBER_DEEP)

    if wordmark:
        track(d, "TRANSPORT", ImageFont.truetype(FB, R(98)), R(W / 2), R(688), WHITE, R(3))
        track(d, "COMPANY", ImageFont.truetype(FB, R(52)), R(W / 2), R(800), AMBER_LIGHT, R(17))
    return crop(img.resize((W, H), Image.LANCZOS))


# -- the HQ depot building --------------------------------------------
def render_depot():
    """The store item is a building, so its icon shows a depot rather
    than reusing the truck art the mod icon already uses."""
    img = Image.new("RGBA", SZ, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    GROUND = 792

    shadow = Image.new("RGBA", SZ, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        [R(96), R(GROUND - 16), R(928), R(GROUND + 26)], fill=(0, 0, 0, 200))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(R(9))))

    rr(d, (128, 300, 896, GROUND), 12, WALL, outline=INK, width=6)
    rr(d, (104, 236, 920, 316), 10, WALL_DARK, outline=INK, width=6)
    rr(d, (120, 252, 904, 274), 6, WALL_LIGHT)
    rr(d, (140, 332, 884, 352), 0, AMBER)

    # roller door with slats
    rr(d, (352, 400, 672, GROUND - 14), 8, AMBER_DARK, outline=INK, width=5)
    for i in range(7):
        y = 424 + i * 46
        if y + 22 < GROUND - 20:
            d.rectangle([R(368), R(y), R(656), R(y + 22)], fill=AMBER)

    # windows either side
    for x0 in (176, 716):
        rr(d, (x0, 410, x0 + 148, 524), 8, GLASS_DARK, outline=INK, width=5)
        d.rectangle([R(x0 + 70), R(410), R(x0 + 78), R(524)], fill=INK)
        rr(d, (x0 + 12, 422, x0 + 62, 456), 5, GLASS)

    # bollards flanking the door
    for bx in (306, 718):
        rr(d, (bx - 14, GROUND - 96, bx + 14, GROUND - 14), 12, AMBER_LIGHT,
           outline=INK, width=4)
    return crop(img.resize((W, H), Image.LANCZOS))


# -- PDA tab silhouette -----------------------------------------------
def render_tab():
    """Flat, near-white, heavy shapes only: this sits in the menu tab
    strip at roughly 32-48px, where outlines and shading turn to mush."""
    img = Image.new("RGBA", SZ, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    C = (236, 240, 246, 255)
    GAP = (0, 0, 0, 0)

    # one solid silhouette: trailer, cab, and the coupling between them
    rr(d, (108, 300, 556, 600), 26, C)
    rr(d, (596, 380, 900, 600), 30, C)
    d.rectangle([R(540), R(548), R(612), R(600)], fill=C)

    # wheels overlap the body so the shape stays connected, with a
    # punched hub for definition at tab size
    for wx in (238, 446, 706, 852):
        d.ellipse([R(wx - 78), R(650 - 78), R(wx + 78), R(650 + 78)], fill=C)
    for wx in (238, 446, 706, 852):
        d.ellipse([R(wx - 30), R(650 - 30), R(wx + 30), R(650 + 30)], fill=GAP)
    return crop(img.resize((W, H), Image.LANCZOS))


def squarePad(img):
    """Centre artwork on a square canvas.

    The tab texture is sampled with UVs 0..1 over a square element, so a
    wide crop resized straight to NxN comes out horizontally squashed.
    """
    s = max(img.width, img.height)
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.alpha_composite(img, ((s - img.width) // 2, (s - img.height) // 2))
    return out


def on_bg(art, size, pad):
    bg = Image.open(BG).convert("RGBA").resize((size, size), Image.LANCZOS)
    a = art.copy()
    a.thumbnail((size - pad * 2, size - pad * 2), Image.LANCZOS)
    bg.alpha_composite(a, ((size - a.width) // 2, (size - a.height) // 2))
    return bg


MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
on_bg(render_depot(), 256, 18).save(MOD + "/textures/store_transportCompanyHq.png")
squarePad(render_tab()).resize((128, 128), Image.LANCZOS).save(
    MOD + "/textures/tab_transportCompany.png")
print("wrote icon_source.png, store_transportCompanyHq.png, tab_transportCompany.png")

# --- mod icon: artwork -> FS25 backdrop -> DXT1 dds -------------------
# modDesc ships textures/icon.dds. FS25 warns "raw format" and does CPU
# mip generation for PNG textures, and the other mods here ship
# 512x512 DXT1, so the PNG is only an intermediate.
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dds import save_dxt1

art = render_truck(True)
art.save(MOD + "/icon_source.png")
icon = on_bg(art, 512, 40)
save_dxt1(icon, MOD + "/textures/icon.dds")
print("wrote textures/icon.dds (512x512 DXT1)")
