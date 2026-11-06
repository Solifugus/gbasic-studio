' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_mcp — Studio as an MCP server, the protocol half (headless).
'
' `./studio mcp` serves Studio over the Model Context Protocol on stdio, so
' Claude Code or Claude Desktop can start Studio as a subprocess and use it
' (docs/gbasic_studio_book_snapshots.md §4.4). Every decision is here, over
' plain data: what a request is, which tools are offered, what a reply says,
' and what a session leaves behind as a shot script. `app/studio.bas`'s `mcp`
' mode is the adapter -- it reads a line, performs the call, prints the reply.
'
' THE TOOLS ARE A SHOT SCRIPT'S VOCABULARY, no more and no less: Studio's own
' tools (`studio_tools.registry()`, through `studio_tools.invoke`, the one
' gate) and the frame verbs a figure needs (`studio_shots.verbs()`, less
' `frame`, which a window that is already open cannot honour). One vocabulary
' is what lets a session be handed back as a script (`shot_script`): the
' sequence an AI tried live is the figure `./studio shoot` replays, which is
' how the proposal says scripts get written.
'
' NOT gBASIC's `mcp.handle`, and for two reasons that are about this server
' rather than taste. Its tool result is TEXT only, and `capture` answers with
' an IMAGE -- the point of capture over MCP is that the client sees what it
' did. And `tools.dispatch` calls one function value per tool, which cannot
' close over the app; Studio's gate takes the tool's NAME. The protocol is
' small, and it is the same protocol: newline-delimited JSON-RPC 2.0, a
' notification never answered, a failed tool a RESULT with `isError` and not
' a JSON-RPC error.
library studio_mcp

    load studio_tools
    load studio_shots
    load studio_permissions

    function server_name()
        return "gbasic-studio"
    end function

    function server_version()
        return "0.1.0"
    end function

    ' The protocol revisions this server speaks. A client asking for one of
    ' them gets it back; any other gets the first, which is what MCP's version
    ' negotiation says a server does.
    function protocol_versions()
        return ["2024-11-05", "2025-03-26", "2025-06-18"]
    end function

    ' A capture over MCP is for a model to LOOK at, so it is drawn at 1:1 --
    ' a 2x window is four times the bytes to say the same thing. A script
    ' replaying the session records the scale it used, so the figure is the
    ' same either way.
    function default_scale()
        return 1
    end function

    ' The policy a session runs under. Reads and Studio's local acts (open,
    ' type, run -- everything Studio can put back) are automatic; the EXTERNAL
    ' tier (save, delete, rename: what Studio cannot undo) is DENIED unless the
    ' person starting the server said otherwise, and then it is `auto` because
    ' the client's own per-tool approval is the confirmation -- a token the
    ' model hands back to itself would confirm nothing.
    function policy(external)
        ext = "deny"
        if external = "auto" then
            ext = "auto"
        end if
        return studio_permissions.effective({ read: "auto", local: "auto", external: ext }, nothing, nothing)
    end function

    ' How long `execute_section` waits for a run before answering that it is
    ' still going (it goes on, and every later request moves it along). From
    ' GBASIC_STUDIO_MCP_WAIT when that is a number of seconds above 0, else 30.
    function run_wait(raw)
        if is_string(raw) then
            v = try_decode(raw)
            if v.ok then
                if is_number(v.value) then
                    if v.value > 0 then
                        return v.value
                    end if
                end if
            end if
        end if
        return 30
    end function

    ' ---- the tools -----------------------------------------------------------

    function _verb_tools()
        out = []
        out = append(out, { name: "open_samples", tier: "local",
            description: "Open Studio's samples as a project (a copy in Studio's home, made once): small gBASIC programs showing sections, tables, errors, branches and SQL.",
            schema: { type: "object", properties: {}, required: [] } })
        out = append(out, { name: "open_folder", tier: "local",
            description: "Open an existing folder as a project. A relative path is relative to the directory ./studio mcp was started in.",
            schema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } })
        out = append(out, { name: "caret_to", tier: "local",
            description: "Put the editor's caret on the first line of the active document that starts with this text (leading spaces ignored). The caret decides which section Run runs and what the panes show. Column is 1-based.",
            schema: { type: "object",
                      properties: { text: { type: "string" }, column: { type: "number" } },
                      required: ["text"] } })
        out = append(out, { name: "raise", tier: "local",
            description: "Bring one of the side panes to the front (they share one dock as tabs).",
            schema: { type: "object",
                      properties: { pane: { type: "string", enum: studio_shots.panes() } },
                      required: ["pane"] } })
        wins = []
        for each w in studio_shots.windows()
            if w != "main" then
                wins = append(wins, w)
            end if
        end for
        out = append(out, { name: "open_window", tier: "local",
            description: "Open one of Studio's second windows: the grid for a Tables row (row is its index, default 0), New Project, Insert SQL (snippet) or the schema browser.",
            schema: { type: "object",
                      properties: { window: { type: "string", enum: wins }, row: { type: "number" } },
                      required: ["window"] } })
        out = append(out, { name: "capture", tier: "local",
            description: "A picture of the window, or of one part of it, returned as a PNG image. part is files, editor, console, toolbar, results, branch, tables, git or agent (omit it for the whole window); window is main unless a second window is open. Check what you did with the read tools; this is for seeing how it looks.",
            schema: { type: "object",
                      properties: { window: { type: "string", enum: studio_shots.windows() },
                                    part: { type: "string" },
                                    file: { type: "string" },
                                    scale: { type: "number" } },
                      required: [] } })
        out = append(out, { name: "shot_script", tier: "read",
            description: "What this session has done to the window, as a shot script: one JSON line per step. ./studio shoot <script> <out-dir> replays it offscreen and writes its captures as figures.",
            schema: { type: "object", properties: {}, required: [] } })
        return out
    end function

    function verb_names()
        out = []
        for each t in studio_mcp._verb_tools()
            out = append(out, t.name)
        end for
        return out
    end function

    function is_verb(name)
        return contains(studio_mcp.verb_names(), name)
    end function

    ' Every tool a session can be offered, with its tier. Studio's own first,
    ' as the registry orders them; the verbs after.
    function all_tools()
        out = []
        for each t in studio_tools.registry()
            tier = "read"
            if has(t, "tier") then
                tier = t.tier
            end if
            out = append(out, { name: t.name, tier: tier, description: t.description, schema: t.schema })
        end for
        for each t in studio_mcp._verb_tools()
            out = append(out, t)
        end for
        return out
    end function

    ' What the client is told about, under a policy. A tool the policy DENIES
    ' is not listed: not offering one is the stronger statement, the line the
    ' window's assistant takes with the acts.
    function offered(pol)
        out = []
        for each t in studio_mcp.all_tools()
            if studio_permissions.policy_for(pol, t.tier) != "deny" then
                out = append(out, t)
            end if
        end for
        return out
    end function

    function is_offered(pol, name)
        for each t in studio_mcp.offered(pol)
            if t.name = name then
                return true
            end if
        end for
        return false
    end function

    function tool_list(pol)
        out = []
        for each t in studio_mcp.offered(pol)
            e = {}
            e["name"] = t.name
            e["description"] = t.description
            e["inputSchema"] = t.schema
            out = append(out, e)
        end for
        r = {}
        r["tools"] = out
        return r
    end function

    ' A verb's arguments, checked as a script line is checked -- the same
    ' rules, so a call the server takes is a step `./studio shoot` takes.
    ' `capture`'s file is filled in first: a model asking for a picture should
    ' not have to name a file it will never see.
    function verb_args(name, a, n)
        if name = "capture" then
            if is_unknown(a["file"]) then
                a["file"] = "capture-" + string(n) + ".png"
            end if
            if is_unknown(a["scale"]) then
                a["scale"] = studio_mcp.default_scale()
            end if
        end if
        return a
    end function

    function verb_problem(name, a)
        if name = "shot_script" then
            if count(keys(a)) > 0 then
                return "shot_script takes no arguments"
            end if
            return ""
        end if
        return studio_shots._check(name, a, 1)
    end function

    ' ---- the protocol --------------------------------------------------------

    function _reply(id, field, value)
        r = {}
        r["jsonrpc"] = "2.0"
        r["id"] = id
        r[field] = value
        return json_encode(r)
    end function

    function error_reply(id, code, message)
        e = {}
        e["code"] = code
        e["message"] = message
        return studio_mcp._reply(id, "error", e)
    end function

    function ok_reply(id, result)
        return studio_mcp._reply(id, "result", result)
    end function

    function instructions()
        return "gBASIC Studio, an IDE for the gBASIC language, running offscreen. A document is divided into SECTIONS, and the caret decides which one runs: open a document, put the caret in a section (caret_to or move_cursor), then execute_section. The read tools (list_sections, run_state, section_output, section_variables, ...) are how to understand what happened; capture shows how the window looks. shot_script hands back what you did as a script that ./studio shoot replays into figures."
    end function

    function _initialize(id, params)
        known = studio_mcp.protocol_versions()
        v = known[0]
        if is_record(params) then
            asked = params["protocolVersion"]
            if is_string(asked) then
                if contains(known, asked) then
                    v = asked
                end if
            end if
        end if
        caps = {}
        caps["tools"] = {}
        info = {}
        info["name"] = studio_mcp.server_name()
        info["version"] = studio_mcp.server_version()
        res = {}
        res["protocolVersion"] = v
        res["capabilities"] = caps
        res["serverInfo"] = info
        res["instructions"] = studio_mcp.instructions()
        return studio_mcp.ok_reply(id, res)
    end function

    ' One request line, decided. Answers one of
    '   { reply: "<json>" }           send this
    '   { reply: "" }                 a notification: send nothing
    '   { call: { id, name, args } }  a tool call the adapter must perform
    ' and NEVER raises: a line arrives from another program, and a malformed
    ' one is an ordinary event that gets a JSON-RPC error, not a dead server.
    function request(pol, line)
        d = try_decode(line)
        if not d.ok then
            return { reply: studio_mcp.error_reply(nothing, -32700, "parse error: " + d.message) }
        end if
        req = d.value
        if not is_record(req) then
            return { reply: studio_mcp.error_reply(nothing, -32600, "a request must be an object") }
        end if
        m = req["method"]
        if not is_string(m) then
            return { reply: studio_mcp.error_reply(default(req["id"], nothing), -32600, "a request needs a method") }
        end if
        ' A NOTIFICATION HAS NO id AND GETS NO REPLY: answering one is how a
        ' server confuses a client, which is not waiting for it and takes the
        ' reply as the answer to whatever it asks next.
        if not has(req, "id") then
            return { reply: "" }
        end if
        id = req.id
        params = req["params"]
        if is_unknown(params) then
            params = {}
        end if
        if m = "initialize" then
            return { reply: studio_mcp._initialize(id, params) }
        end if
        if m = "ping" then
            return { reply: studio_mcp.ok_reply(id, {}) }
        end if
        if m = "tools/list" then
            return { reply: studio_mcp.ok_reply(id, studio_mcp.tool_list(pol)) }
        end if
        if m = "tools/call" then
            if not is_record(params) then
                return { reply: studio_mcp.error_reply(id, -32602, "params must be an object") }
            end if
            name = params["name"]
            if not is_string(name) then
                return { reply: studio_mcp.error_reply(id, -32602, "tools/call needs a tool name") }
            end if
            a = params["arguments"]
            if is_unknown(a) then
                a = {}
            end if
            if not is_record(a) then
                return { reply: studio_mcp.error_reply(id, -32602, "arguments must be an object") }
            end if
            return { call: { id: id, name: name, args: a } }
        end if
        return { reply: studio_mcp.error_reply(id, -32601, "no such method: " + m) }
    end function

    function text_block(t)
        b = {}
        b["type"] = "text"
        b["text"] = t
        return b
    end function

    function image_block(png_base64)
        b = {}
        b["type"] = "image"
        b["data"] = png_base64
        b["mimeType"] = "image/png"
        return b
    end function

    ' A tool's answer. A refusal is a RESULT with isError -- the model asked
    ' for something reasonable and can react to the answer -- not a JSON-RPC
    ' error, which would say the CLIENT is malformed.
    function call_reply(id, blocks, is_error)
        r = {}
        r["content"] = blocks
        r["isError"] = is_error
        return studio_mcp.ok_reply(id, r)
    end function

    ' ---- the session, as a script --------------------------------------------

    ' What goes into the script: whatever changes the window. A read changes
    ' nothing a figure shows, and `shot_script` is the session asking about
    ' itself.
    function recordable(name)
        if name = "shot_script" then
            return false
        end if
        if studio_mcp.is_verb(name) then
            return true
        end if
        return studio_tools.is_act(name)
    end function

    ' One more step, or a COMMENT standing for it. An external act (allowed
    ' only when the person starting the server said so) cannot be a figure's
    ' step -- `./studio shoot` refuses the whole script over one -- so it is
    ' recorded as a comment saying where it happened, and the script stays
    ' one that runs.
    function record(steps, name, a)
        if not studio_mcp.recordable(name) then
            return steps
        end if
        if not studio_mcp.is_verb(name) then
            if studio_tools.tier_of(name) = "external" then
                return append(steps, { comment: name + " was called here; a figure does not change the project, so it is left out" })
            end if
        end if
        return append(steps, { tool: name, args: a })
    end function

    ' How many captures the session has recorded -- the default file name is
    ' the next one's number, so a session's pictures are capture-1, -2, ...
    function captures(steps)
        n = 0
        for each s in steps
            if has(s, "tool") then
                if s.tool = "capture" then
                    n = n + 1
                end if
            end if
        end for
        return n
    end function

    function _line(tool, a)
        r = {}
        r["tool"] = tool
        if count(keys(a)) > 0 then
            r["args"] = a
        end if
        return json_encode(r)
    end function

    ' The script: a frame line for the window the session ran in, then each
    ' step. `studio_shots.script_steps` takes it back with no errors -- the
    ' `mcp_session` tier checks exactly that.
    function script_text(frame, steps)
        out = ["# recorded by ./studio mcp -- replay with: ./studio shoot <this file> <out-dir>"]
        out = append(out, studio_mcp._line("frame", frame))
        for each s in steps
            if has(s, "comment") then
                out = append(out, "# " + s.comment)
            else
                out = append(out, studio_mcp._line(s.tool, s.args))
            end if
        end for
        return join(out, chr(10)) + chr(10)
    end function

end library
