' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' mcp_lines.bas — what `./studio mcp` wrote to STDOUT, read back line by line.
'
' STDOUT IS THE PROTOCOL, so every line of it must be one JSON-RPC reply: a
' stray `print` anywhere on the serving path is a line the client cannot
' read. This says so per line, and summarises each reply -- a text block's
' first line, an image's type and size -- writing each image out as
' <dir>/<id>.png and the session's shot script as <dir>/session.shot, so the
' runner can replay the script and compare pictures.
'
'   gbasic tests/drivers/mcp_lines.bas <stdout file> <dir>

function first_line(t)
    l = split(t, chr(10))[0]
    if len(l) > 110 then
        return left(l, 107) + "..."
    end if
    return l
end function

program main(args)
    src{file} = args[0]
    dir = args[1]
    bad = 0
    for each l in split(read(src), chr(10))
        if l = "" then
            continue
        end if
        d = try_decode(l)
        if not d.ok then
            bad = bad + 1
            print "NOT JSON: " + first_line(l)
            continue
        end if
        r = d.value
        if has(r, "error") then
            print string(r.id) + "  error " + string(r["error"].code) + "  " + r["error"].message
            continue
        end if
        res = r.result
        if has(res, "tools") then
            print string(r.id) + "  " + string(count(res.tools)) + " tools"
            continue
        end if
        if has(res, "protocolVersion") then
            print string(r.id) + "  initialized, protocol " + res.protocolVersion
            continue
        end if
        if not has(res, "content") then
            print string(r.id) + "  " + json_encode(res)
            continue
        end if
        how = "ok"
        if res.isError then
            how = "isError"
        end if
        for each b in res.content
            if b.type = "text" then
                if starts_with(b.text, "# recorded by") then
                    sh{file} = dir + "/session.shot"
                    z = write(sh, b.text)
                    print string(r.id) + "  " + how + "  a shot script of " + string(count(split(trim(b.text), chr(10)))) + " lines"
                    for each sl in split(trim(b.text), chr(10))
                        print "      | " + sl
                    end for
                else
                    print string(r.id) + "  " + how + "  " + first_line(b.text)
                end if
            else if b.type = "image" then
                png = base64_decode(b.data)
                sig = byte_slice(png, 0, 8) = from_bytes([137, 80, 78, 71, 13, 10, 26, 10])
                out{file} = dir + "/" + string(r.id) + ".png"
                z = write(out, png)
                print string(r.id) + "  " + how + "  " + b.mimeType + ", PNG signature " + string(sig)
            else
                print string(r.id) + "  " + how + "  a " + b.type + " block"
            end if
        end for
    end for
    print "lines that are not JSON-RPC: " + string(bad)
end program
