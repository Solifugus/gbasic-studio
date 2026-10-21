#!/usr/bin/env python3
"""Studio's own toolbar icons, for the dark theme.

WHY THESE EXIST. The Qt toolbar's icons were `SP_` standard pixmaps, which
Qt's own style draws from the palette -- and `qt.theme` sets a stylesheet,
which does not move the palette. On a dark strip they were dark glyphs on
dark: measured invisible while `qt.has_icon` went on answering true for every
one. Until gBASIC grows a palette verb, an icon that reads on dark has to be
a file Studio ships.

Authored here rather than taken from an icon set, so the provenance is this
script: run it and you get exactly the bytes in this directory. Apache-2.0
with the rest of Studio.

Drawn at 8x and downsampled with LANCZOS, which is the whole of the
anti-aliasing -- PIL's own line drawing is hard-edged and a 2px stroke at
24px looks like a staircase without it.
"""
import os
from PIL import Image, ImageDraw

S = 24          # the shipped size
F = 8           # supersample factor
N = S * F       # canvas
FG = (214, 214, 214, 255)          # studio_style.dark_fg()
ACCENT = (74, 158, 255, 255)       # the accent, for the "+" on the two New icons
W = 2 * F       # stroke width in supersampled pixels

HERE = os.path.dirname(os.path.abspath(__file__))


def canvas():
    im = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def finish(im, name):
    out = im.resize((S, S), Image.LANCZOS)
    path = os.path.join(HERE, name + ".png")
    out.save(path)
    return path


def rect(d, box, width=W, fill=None, outline=FG):
    d.rectangle(box, outline=outline, width=width, fill=fill)


def save_icon():
    """A floppy disk: the one shape still read as "save"."""
    im, d = canvas()
    m = 2 * F
    rect(d, (m, m, N - m - 1, N - m - 1))
    # the shutter, top centre
    sw = 7 * F
    d.rectangle((N // 2 - sw // 2, m + W, N // 2 + sw // 2, m + 7 * F),
                outline=FG, width=W)
    # the label, bottom
    d.rectangle((m + 3 * F, N - m - 7 * F, N - m - 3 * F, N - m - W),
                outline=FG, width=W)
    return finish(im, "save")


def reload_icon():
    """A circular arrow with a real head on it.

    The first attempt drew the head as a small polygon at the arc's end and it
    did not read as an arrow at all -- a circle with a notch in it, which looks
    like a spinner. The head is now built from the TANGENT at the endpoint and
    is deliberately large: at 24px an arrowhead smaller than the stroke is
    three grey pixels.
    """
    import math
    im, d = canvas()
    m = 3.5 * F
    cx = cy = N / 2.0
    r = (N - 2 * m) / 2.0
    # Clockwise from 20 deg round to 300 deg, leaving the gap at the top right.
    d.arc((m, m, N - m, N - m), start=20, end=300, fill=FG, width=W)

    # The head sits at the 20-degree end, pointing along the tangent (which for
    # a clockwise arc at angle a is a + 90 deg).
    a = math.radians(20)
    px, py = cx + r * math.cos(a), cy + r * math.sin(a)
    t = a + math.pi / 2.0
    h = 5.0 * F                      # length along the tangent
    b = 3.4 * F                       # half-width across it
    tipx, tipy = px + h * math.cos(t), py + h * math.sin(t)
    nx, ny = math.cos(a), math.sin(a)   # outward normal
    d.polygon([(tipx, tipy),
               (px + b * nx, py + b * ny),
               (px - b * nx, py - b * ny)], fill=FG)
    return finish(im, "reload")


def _folder(d, open_flap=False):
    """A folder. Open means the FRONT panel leans away, so the two panels are
    visibly separate shapes -- the first version drew a line across a closed
    folder, which read as a folder with a line across it."""
    m = 2 * F
    top = 7 * F
    tab_w = 8 * F
    # the tab along the top left
    d.line([(m, top), (m, top - 2.5 * F), (m + tab_w, top - 2.5 * F),
            (m + tab_w + 2 * F, top)], fill=FG, width=W, joint="curve")
    if open_flap:
        # back panel, upright and shorter
        d.polygon([(m, top), (N - m - 1, top), (N - m - 1, N - 9 * F),
                   (m, N - 9 * F)], outline=FG, width=W)
        # front panel, a parallelogram leaning out to the right
        d.polygon([(m, N - 9 * F), (N - m - 5 * F, N - 9 * F),
                   (N - m - 1, N - 3 * F), (m + 4 * F, N - 3 * F)],
                  outline=FG, width=W)
    else:
        d.polygon([(m, top), (N - m - 1, top), (N - m - 1, N - 3.5 * F),
                   (m, N - 3.5 * F)], outline=FG, width=W)
    return None


def open_folder_icon():
    im, d = canvas()
    _folder(d, open_flap=True)
    return finish(im, "open-folder")


def _page(d):
    m = 4 * F
    fold = 6 * F
    d.polygon([(m, 2 * F), (N - m - fold, 2 * F), (N - m, 2 * F + fold),
               (N - m, N - 2 * F), (m, N - 2 * F)], outline=FG, width=W)
    d.line([(N - m - fold, 2 * F), (N - m - fold, 2 * F + fold),
            (N - m, 2 * F + fold)], fill=FG, width=W)


def _plus(d, cx, cy, arm=4 * F, colour=ACCENT):
    d.line([(cx - arm, cy), (cx + arm, cy)], fill=colour, width=W)
    d.line([(cx, cy - arm), (cx, cy + arm)], fill=colour, width=W)


def new_file_icon():
    im, d = canvas()
    _page(d)
    _plus(d, N // 2, int(N * 0.62))
    return finish(im, "new-file")


def new_folder_icon():
    im, d = canvas()
    _folder(d, open_flap=False)
    _plus(d, int(N * 0.52), int(N * 0.60))
    return finish(im, "new-folder")


def contact_sheet():
    """The five on Studio's own dark toolbar colour, so they can be LOOKED at."""
    names = ["save", "reload", "open-folder", "new-file", "new-folder"]
    pad, scale = 10, 3
    w = pad + len(names) * (S * scale + pad)
    sheet = Image.new("RGBA", (w, S * scale + 2 * pad), (31, 32, 34, 255))
    x = pad
    for n in names:
        ic = Image.open(os.path.join(HERE, n + ".png")).resize(
            (S * scale, S * scale), Image.NEAREST)
        sheet.alpha_composite(ic, (x, pad))
        x += S * scale + pad
    p = os.path.join(HERE, "_contact_sheet.png")
    sheet.save(p)
    return p


if __name__ == "__main__":
    import sys
    for f in (save_icon, reload_icon, open_folder_icon,
              new_file_icon, new_folder_icon):
        print("wrote", os.path.basename(f()))
    # The sheet is a REVIEW artefact and is not shipped -- it is how these get
    # looked at instead of guessed at, which is the whole lesson of the dark
    # theme landing three times.
    if "--contact-sheet" in sys.argv:
        print("sheet:", contact_sheet())
