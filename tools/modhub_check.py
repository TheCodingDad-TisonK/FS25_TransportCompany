"""ModHub readiness audit for FS25_TransportCompany.

Run alongside GIANTS' own TestRunner, not instead of it. This is the
fast local pass over the built zip; the TestRunner is the authority.

It checks the things ModHub submissions are actually rejected for:

  * modDesc completeness and descVersion range (main.lua:29-30)
  * every file modDesc references exists inside the zip
  * icon presence, format and dimensions
  * localisation actually loadable by the engine's external loader
  * no dev leftovers, absolute paths, or debug defaults shipped
  * zip layout (flat, correctly named, no nested mod folder)

Exit code is non-zero if any ERROR is found. WARN is advisory.

    py tools/modhub_check.py
"""
import os
import re
import struct
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_NAME = os.path.basename(ROOT)
ZIP = os.path.join(ROOT, MOD_NAME + ".zip")

errors, warns, oks = [], [], []
def err(m):  errors.append(m)
def warn(m): warns.append(m)
def ok(m):   oks.append(m)


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", data[16:24])


def dds_info(data):
    if data[:4] != b"DDS ":
        return None
    h, w, _, _, mips = struct.unpack("<5I", data[12:32])
    return w, h, mips, data[84:88].decode("ascii", "replace")


def main():
    if not os.path.exists(ZIP):
        err("no built zip -- run: py build.py")
        report()
        return

    z = zipfile.ZipFile(ZIP)
    names = set(z.namelist())

    if z.testzip() is not None:
        err("zip is corrupt")
    else:
        ok("zip integrity")

    # --- layout ------------------------------------------------------
    if "modDesc.xml" not in names:
        err("modDesc.xml is not at the zip root (nested mod folder?)")
        report()
        return
    ok("modDesc.xml at zip root")

    if not re.fullmatch(r"FS25_[A-Za-z0-9_]+", MOD_NAME):
        err("mod folder name %r is not FS25_<Name>" % MOD_NAME)
    else:
        ok("mod name %s" % MOD_NAME)

    dev = sorted(n for n in names
                 if n.startswith(("tests/", "tools/", ".git"))
                 or n.endswith((".py", ".md", ".sh", ".ps1", ".zip")))
    if dev:
        err("development files shipped: %s" % ", ".join(dev[:6]))
    else:
        ok("no development files in the zip")

    # --- modDesc -----------------------------------------------------
    md = z.read("modDesc.xml").decode("utf-8-sig")
    root = ET.fromstring(md)

    dv = root.get("descVersion")
    if dv is None or not dv.isdigit():
        err("modDesc descVersion missing")
    elif int(dv) != 111:
        # The engine loads 90-111 (main.lua:29-30) but the TestRunner
        # pins ModHub submissions to the current version exactly:
        # "invalid desc version ... min: 111 max: 111".
        err("descVersion %s -- ModHub requires exactly 111" % dv)
    else:
        ok("descVersion %s" % dv)

    for tag in ("author", "version", "title", "description", "iconFilename"):
        node = root.find(tag)
        if node is None or not ("".join(node.itertext()).strip()):
            err("modDesc <%s> missing or empty" % tag)
    if root.find("author") is not None:
        ok("author / version / title / description / iconFilename present")

    ver = (root.findtext("version") or "").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", ver):
        err("version %r is not x.y.z.w" % ver)
    else:
        ok("version %s" % ver)

    mp = root.find("multiplayer")
    if mp is None:
        warn("no <multiplayer> element -- ModHub lists the mod as singleplayer only")
    else:
        ok("multiplayer supported=%s" % mp.get("supported"))

    # --- referenced files exist inside the zip -----------------------
    refs = []
    icon = (root.findtext("iconFilename") or "").strip()
    if icon:
        refs.append(("iconFilename", icon))
    for node in root.iter("sourceFile"):
        refs.append(("sourceFile", node.get("filename", "")))
    for node in root.iter("storeItem"):
        refs.append(("storeItem", node.get("xmlFilename", "")))
    for node in root.iter("specialization"):
        if node.get("filename"):
            refs.append(("specialization", node.get("filename")))
    for node in root.iter("brand"):
        if node.get("image"):
            refs.append(("brand image", node.get("image")))

    missing = [(k, v) for k, v in refs if v and not v.startswith("$") and v not in names]
    if missing:
        for k, v in missing:
            err("modDesc %s points at a file not in the zip: %s" % (k, v))
    else:
        ok("all %d modDesc file references resolve inside the zip" % len(refs))

    # --- icon --------------------------------------------------------
    if icon in names:
        data = z.read(icon)
        if icon.lower().endswith(".dds"):
            info = dds_info(data)
            if info is None:
                err("icon %s is not a valid DDS" % icon)
            else:
                w, h, mips, fmt = info
                if w != h:
                    err("icon is %dx%d -- must be square" % (w, h))
                elif w < 256:
                    err("icon is %dpx -- ModHub expects at least 256" % w)
                else:
                    ok("icon %s %dx%d %s mips=%d" % (icon, w, h, fmt, mips))
        else:
            sz = png_size(data)
            if sz is None:
                err("icon %s is neither DDS nor PNG" % icon)
            else:
                w, h = sz
                if w != h or w < 256:
                    err("icon is %dx%d -- must be square, at least 256" % (w, h))
                else:
                    ok("icon %s %dx%d PNG" % (icon, w, h))
                warn("icon is PNG; the engine logs 'raw format' and generates "
                     "mips on the CPU. DDS is preferred.")

    # --- TestRunner naming and format rules --------------------------
    if icon and not icon.endswith("icon_%s.dds" % MOD_NAME):
        err("mod icon %s must be named icon_%s.dds "
            "(TestRunner 'mod icon name')" % (icon, MOD_NAME))
    elif icon:
        ok("mod icon follows the icon_<modName>.dds convention")

    # a storeIcon must be 512x512 BC7_UNORM, not a DXT format
    store_icons = set()
    for n in names:
        if n.endswith(".xml"):
            body = z.read(n).decode("utf-8-sig", "replace")
            for m in re.finditer(r"<image>([^<]+)</image>", body):
                store_icons.add(m.group(1).strip())
    for si in sorted(store_icons):
        if si not in names:
            continue
        d = z.read(si)
        info = dds_info(d)
        if info is None:
            err("store icon %s is not DDS" % si)
            continue
        w, h, mips, fourcc = info
        if (w, h) != (512, 512):
            err("store icon %s is %dx%d -- must be 512x512" % (si, w, h))
        elif fourcc != "DX10" or struct.unpack("<I", d[128:132])[0] != 98:
            err("store icon %s is %s -- must be BC7_UNORM" % (si, fourcc))
        else:
            ok("store icon %s 512x512 BC7_UNORM" % si)

    for node in root.iter("brand"):
        bi = node.get("image")
        if bi and bi in names:
            info = dds_info(z.read(bi))
            if info and (info[0], info[1]) != (512, 256):
                err("brand icon %s is %dx%d -- must be 512x256"
                    % (bi, info[0], info[1]))
            elif info:
                ok("brand icon %s 512x256" % bi)

    ALLOWED = {"xml", "lua", "dds", "i3d", "shapes", "anim", "ogg", "wav",
               "gls", "ogv", "gdm", "grle", "cache"}
    bad_ext = sorted(n for n in names
                     if "." not in n.rsplit("/", 1)[-1]
                     or n.rsplit(".", 1)[-1].lower() not in ALLOWED)
    if bad_ext:
        err("files the TestRunner rejects as source/unsupported: %s"
            % ", ".join(bad_ext[:5]))
    else:
        ok("every shipped file uses an allowed extension")

    # --- localisation ------------------------------------------------
    l10n = root.find("l10n")
    if l10n is None:
        warn("no <l10n> element")
    else:
        prefix = l10n.get("filenamePrefix")
        if prefix:
            # the engine appends _<lang>.xml (mods.lua:789)
            langs = [n for n in names
                     if n.startswith(prefix + "_") and n.endswith(".xml")]
            if not langs:
                err("l10n filenamePrefix %r matches no %s_<lang>.xml in the zip"
                    % (prefix, prefix))
            else:
                ok("l10n: %d language file(s) -- %s"
                   % (len(langs), ", ".join(sorted(
                       n[len(prefix) + 1:-4] for n in langs))))
                for n in langs:
                    body = z.read(n).decode("utf-8-sig")
                    if "<e k=" not in body and "<text " not in body:
                        err("%s uses neither l10n.elements.e nor l10n.texts.text; "
                            "the external loader reads only those (I18N.lua:83)" % n)
                if len(langs) == 1:
                    warn("only one language ships -- consider adding de")
        else:
            inline = l10n.findall("text")
            ok("l10n embedded in modDesc (%d entries)" % len(inline))

    # --- every referenced texture must be DDS ------------------------
    # The GIANTS TestRunner looks up parsed DDS data for each texture a
    # mod references and dies on a PNG with
    #   AttributeError: 'NoneType' object has no attribute 'header_dx10'
    # (DXTCheck.py:124). That is a hard submission blocker, so it is an
    # error here rather than a style note.
    tex_ext = (".png", ".jpg", ".jpeg", ".tga", ".bmp")
    tex_refs = set()
    for n in names:
        if n.endswith((".xml", ".lua")):
            body = z.read(n).decode("utf-8-sig", "replace")
            for m in re.finditer(r'[\w/\.-]+\.(?:dds|png|jpg|jpeg|tga|bmp)', body):
                ref = m.group(0).replace("\\", "/")
                if not ref.startswith("$"):
                    tex_refs.add(ref)
    raster = sorted(r for r in tex_refs if r.lower().endswith(tex_ext))
    if raster:
        for r in raster:
            err("texture referenced as a raster image, not DDS: %s "
                "(TestRunner DXTCheck crashes on this)" % r)
    else:
        ok("all %d referenced textures are DDS" % len(tex_refs))

    shipped_raster = sorted(n for n in names if n.lower().endswith(tex_ext))
    if shipped_raster:
        warn("raster images shipped in the zip: %s" % ", ".join(shipped_raster[:5]))

    # --- content sanity ----------------------------------------------
    abs_path = re.compile(r"[A-Za-z]:[\\/]|/Users/|/home/")
    offenders = []
    for n in names:
        if n.endswith((".lua", ".xml")):
            body = z.read(n).decode("utf-8-sig", "replace")
            if abs_path.search(body):
                offenders.append(n)
    if offenders:
        err("absolute paths found in: %s" % ", ".join(offenders[:5]))
    else:
        ok("no absolute machine paths in shipped files")

    # every XML must parse
    bad = []
    for n in names:
        if n.endswith(".xml"):
            try:
                ET.fromstring(z.read(n).decode("utf-8-sig"))
            except Exception as exc:
                bad.append("%s (%s)" % (n, exc))
    if bad:
        for b in bad:
            err("malformed XML: %s" % b)
    else:
        ok("every shipped XML parses")

    # debug must ship off
    for n in names:
        if n.endswith("TransportCompanySettings.lua"):
            body = z.read(n).decode("utf-8-sig")
            m = re.search(r'id = "debugMode".*?default = (\w+)', body, re.S)
            if m and m.group(1) != "false":
                err("debugMode ships as %s -- must default to false" % m.group(1))
            elif m:
                ok("debugMode ships false")

    report()


def report():
    for m in oks:
        print("  OK    %s" % m)
    for m in warns:
        print("  WARN  %s" % m)
    for m in errors:
        print("  ERROR %s" % m)
    print("\n%d ok, %d warning(s), %d error(s)" % (len(oks), len(warns), len(errors)))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
