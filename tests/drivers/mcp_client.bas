' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' mcp_client.bas — a CONVERSATION with `./studio mcp`, through gBASIC's own
' MCP client (`mcp.connect`, stdio). One request, wait for the reply, the next:
' the way Claude Code talks to a server. A piped batch of requests cannot see
' a reply stuck in a block buffer -- it all comes out at exit -- and this can:
' `mcp.connect` gives up after 10 seconds without an answer, naming it.
'
'   gbasic tests/drivers/mcp_client.bas <studio launcher> <slow project>

load mcp

function show(h, name, a, mask)
    r = mcp.call(h, name, a)
    how = "ok"
    if r.is_error then
        how = "REFUSED"
    end if
    print "-- " + name + "  " + how
    ' Cut at 100: a refused capture lists every part of the window, and that
    ' list is the window's business, not this tier's.
    for each l in split(r.content, chr(10))
        l = replace(l, mask, "<slow>")
        if len(l) > 100 then
            l = left(l, 97) + "..."
        end if
        print "   " + l
    end for
    return r
end function

program main(args)
    h = mcp.connect({ transport: "stdio", command: args[0], args: ["mcp"],
                      expect: ["open_folder", "execute_section", "run_state", "capture", "shot_script"] })
    names = []
    for each t in mcp.tools_of(h)
        names = append(names, t.name)
    end for
    print "connected: " + string(count(names)) + " tools"
    print "external offered: " + string(contains(names, "save_document") or contains(names, "delete_path") or contains(names, "rename_path"))
    print "frame offered: " + string(contains(names, "frame"))

    z = show(h, "open_folder", { path: args[1] }, args[1])
    z = show(h, "open_document", { path: "slow.bas" }, args[1])
    ' MOVE_CURSOR MOVES THE EDITOR'S CARET, not only the model's: the act's
    ' answer is the caret read back off the widget, and the section it is in.
    z = show(h, "move_cursor", { line: 5 }, args[1])
    z = show(h, "section_at_cursor", {}, args[1])
    ' A run longer than the wait is answered as still going, and the run goes
    ' on: a later request finds it finished.
    z = show(h, "execute_section", {}, args[1])
    r = mcp.call(h, "run_state", {})
    print "-- run_state at once  running=" + string(contains(r.content, "\"running\""))
    sleep(2.5)
    r = mcp.call(h, "run_state", {})
    print "-- run_state later  finished=" + string(contains(r.content, "finished"))
    r = mcp.call(h, "section_output", { section_id: "sec-2" })
    print "-- section_output  " + r.content
    z = show(h, "capture", { part: "nosuch" }, args[1])
    z = show(h, "delete_path", {}, args[1])
    z = show(h, "no_such_tool", {}, args[1])
    z = mcp.disconnect(h)
    print "disconnected"
end program
