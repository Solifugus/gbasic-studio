' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' png_gray.bas — is a PNG made of grays only?
'
' The print theme's claim is that a figure's CHROME converts to grayscale
' unchanged, so what a reader sees on a black-ink page is what the figure
' showed. That is a fact about pixels, and the only way to check it is to read
' them: a palette-painted surface (a focus frame, a scrollbar) can bring a
' colour back that no Studio colour named.
'
' A PNG reader just big enough for what `qt.capture` writes: 8-bit RGB or RGBA,
' not interlaced, every row filter undone. Prints one line per file:
'   <name>  gray            or
'   <name>  N coloured pixel(s), first at x,y = #rrggbb
'
'   gbasic tests/drivers/png_gray.bas <file.png>...

function be32(s, at)
    b = to_bytes(byte_slice(s, at, 4))
    return ((b[0] * 256 + b[1]) * 256 + b[2]) * 256 + b[3]
end function

function paeth(a, b, c)
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc then
        return a
    end if
    if pb <= pc then
        return b
    end if
    return c
end function

function hex2(n)
    h = "0123456789abcdef"
    return mid(h, floor(n / 16), 1) + mid(h, mod(n, 16), 1)
end function

function check(path)
    s = read({file} path)
    if byte_slice(s, 0, 8) != from_bytes([137, 80, 78, 71, 13, 10, 26, 10]) then
        return "not a PNG"
    end if
    at = 8
    idat = []
    w = 0
    h = 0
    ch = 0
    while at < byte_count(s)
        n = be32(s, at)
        kind = byte_slice(s, at + 4, 4)
        if kind = "IHDR" then
            w = be32(s, at + 8)
            h = be32(s, at + 12)
            hd = to_bytes(byte_slice(s, at + 16, 5))
            if hd[0] != 8 then
                return "bit depth " + string(hd[0]) + " is not read here"
            end if
            if hd[4] != 0 then
                return "an interlaced PNG is not read here"
            end if
            if hd[1] = 2 then
                ch = 3
            else if hd[1] = 6 then
                ch = 4
            else
                return "colour type " + string(hd[1]) + " is not read here"
            end if
        else if kind = "IDAT" then
            idat = append(idat, byte_slice(s, at + 8, n))
        end if
        if kind = "IEND" then
            at = byte_count(s)
        else
            at = at + 12 + n
        end if
    end while
    raw = to_bytes(uncompress(join(idat, "")))
    stride = w * ch
    prev = []
    for i = 0 to stride - 1
        prev = append(prev, 0)
    end for
    bad = 0
    first = ""
    pos = 0
    for y = 0 to h - 1
        f = raw[pos]
        pos = pos + 1
        cur = []
        for i = 0 to stride - 1
            x = raw[pos + i]
            a = 0
            if i >= ch then
                a = cur[i - ch]
            end if
            b = prev[i]
            c = 0
            if i >= ch then
                c = prev[i - ch]
            end if
            if f = 1 then
                x = x + a
            else if f = 2 then
                x = x + b
            else if f = 3 then
                x = x + floor((a + b) / 2)
            else if f = 4 then
                x = x + paeth(a, b, c)
            end if
            cur = append(cur, mod(x, 256))
        end for
        pos = pos + stride
        for px = 0 to w - 1
            r = cur[px * ch]
            g = cur[px * ch + 1]
            bl = cur[px * ch + 2]
            if r != g or g != bl then
                bad = bad + 1
                if first = "" then
                    first = string(px) + "," + string(y) + " = #" + hex2(r) + hex2(g) + hex2(bl)
                end if
            end if
        end for
        prev = cur
    end for
    if bad = 0 then
        return "gray"
    end if
    return string(bad) + " coloured pixel(s), first at " + first
end function

program main(args)
    for each p in args
        parts = split(p, "/")
        print parts[count(parts) - 1] + "  " + check(p)
    end for
end program
