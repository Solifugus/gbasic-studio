' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' mcp.bas — `studio_mcp`, the protocol half of `./studio mcp`, with no Qt and
' no transport: what a request line is decided to be, what is offered under
' which policy, how a verb's arguments are checked, and that a session's
' record comes back as a script `studio_shots` takes with no errors.

load studio_tools
load studio_shots
load studio_permissions
load studio_mcp

function said(d)
    if has(d, "call") then
        return "call " + d.call.name + " " + json_encode(d.call.args) + " id=" + json_encode(d.call.id)
    end if
    if d.reply = "" then
        return "(no reply)"
    end if
    return d.reply
end function

function tool_names(ts)
    out = []
    for each t in ts
        out = append(out, t.name)
    end for
    return out
end function

program main(args)
    deny = studio_mcp.policy("deny")
    auto = studio_mcp.policy("auto")

    print "== a request line, decided"
    for each l in ["not json", "[1,2]", "{\"jsonrpc\":\"2.0\",\"id\":1}",
                   "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
                   "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"capture\"}}",
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}",
                   "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\"}",
                   "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{}}",
                   "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"capture\",\"arguments\":[1]}}",
                   "{\"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"tools/call\",\"params\":{\"name\":\"capture\",\"arguments\":{\"part\":\"files\"}}}",
                   "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"run_state\"}}"]
        print "  " + said(studio_mcp.request(deny, l))
    end for

    print "== initialize: the client's version when it is one we speak"
    for each v in ["2025-06-18", "2024-11-05", "1999-01-01"]
        d = studio_mcp.request(deny, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"" + v + "\"}}")
        r = decode(d.reply).result
        print "  asked " + v + " -> " + r.protocolVersion + "  server " + r.serverInfo.name + " " + r.serverInfo.version + "  tools capability " + string(has(r.capabilities, "tools"))
    end for

    print "== what is offered"
    all = tool_names(studio_mcp.all_tools())
    seen = []
    dup = []
    for each n in all
        if contains(seen, n) then
            dup = append(dup, n)
        end if
        seen = append(seen, n)
    end for
    print "  every tool: " + string(count(all)) + ", names repeated: " + string(count(dup))
    print "  every Studio tool is there: " + string(count(all) = count(studio_tools.names()) + count(studio_mcp.verb_names()))
    for each pair in [{ n: "external denied", p: deny }, { n: "external auto", p: auto }]
        off = tool_names(studio_mcp.offered(pair.p))
        print "  " + pair.n + ": " + string(count(off)) + " offered; save " + string(contains(off, "save_document")) + ", delete " + string(contains(off, "delete_path")) + ", rename " + string(contains(off, "rename_path")) + ", frame " + string(contains(off, "frame"))
    end for
    listed = decode(studio_mcp.ok_reply(9, studio_mcp.tool_list(deny))).result.tools
    print "  listed as MCP spells it: " + string(has(listed[0], "inputSchema")) + ", first " + listed[0].name + ", last " + listed[count(listed) - 1].name
    print "  verbs: " + join(studio_mcp.verb_names(), ", ")

    print "== a verb's arguments, checked as a script line is"
    a = studio_mcp.verb_args("capture", {}, 3)
    print "  capture {} -> " + json_encode(a) + "  problem [" + studio_mcp.verb_problem("capture", a) + "]"
    a = studio_mcp.verb_args("capture", { file: "mine.png", scale: 2 }, 3)
    print "  capture named -> " + json_encode(a)
    print "  capture ../x.png -> " + studio_mcp.verb_problem("capture", studio_mcp.verb_args("capture", { file: "../x.png" }, 1))
    print "  capture scale 9 -> " + studio_mcp.verb_problem("capture", studio_mcp.verb_args("capture", { scale: 9 }, 1))
    print "  raise sideways -> " + studio_mcp.verb_problem("raise", { pane: "sideways" })
    print "  caret_to {} -> " + studio_mcp.verb_problem("caret_to", {})
    print "  open_window main -> " + studio_mcp.verb_problem("open_window", { window: "main" })
    print "  shot_script {x} -> " + studio_mcp.verb_problem("shot_script", { x: 1 })
    print "  shot_script {} -> [" + studio_mcp.verb_problem("shot_script", {}) + "]"

    print "== the run wait"
    for each raw in ["", "soon", "0", "-2", "2.5", "45"]
        print "  [" + raw + "] -> " + string(studio_mcp.run_wait(raw))
    end for
    print "  unset -> " + string(studio_mcp.run_wait(unknown))

    print "== a session, recorded and handed back as a script"
    steps = []
    for each st in [{ t: "list_sections", a: {} }, { t: "open_samples", a: {} },
                    { t: "open_document", a: { path: "02_tables.bas" } },
                    { t: "caret_to", a: { text: "sales = []" } },
                    { t: "execute_section", a: {} }, { t: "run_state", a: {} },
                    { t: "save_document", a: {} }, { t: "shot_script", a: {} },
                    { t: "capture", a: studio_mcp.verb_args("capture", { part: "tables" }, 1) }]
        steps = studio_mcp.record(steps, st.t, st.a)
    end for
    print "  recorded " + string(count(steps)) + " of 9, captures " + string(studio_mcp.captures(steps))
    text = studio_mcp.script_text(studio_shots.frame_of([]), steps)
    for each l in split(text, chr(10))
        if l != "" then
            print "  | " + l
        end if
    end for
    back = studio_shots.script_steps(text)
    print "  studio_shots takes it back: " + string(count(back.steps)) + " steps, " + string(count(back.errors)) + " errors"
    for each e in back.errors
        print "    " + e
    end for

    print "== a reply"
    print "  " + studio_mcp.call_reply(7, [studio_mcp.text_block("done")], false)
    print "  " + studio_mcp.call_reply(8, [studio_mcp.text_block("no"), studio_mcp.image_block("AAAA")], true)
end program
