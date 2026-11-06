' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_shots — a book figure as a SCRIPT of Studio's own actions (headless).
'
' `./studio shoot <script> <out>` replays a shot script in a fresh home,
' offscreen, and writes the PNGs it asks for (docs/gbasic_studio_book_snapshots.md
' §4.3). A script is one JSON object per line, `{"tool": ..., "args": {...}}`,
' and the tools are of two kinds:
'
'   * STUDIO'S OWN TOOLS -- every name in `studio_tools.registry()`, the same
'     surface the assistant reads through and an MCP server will serve. They
'     go through `studio_tools.invoke`, the one gate, so a figure is made by the
'     operations a person's clicks make and not by a second automation path;
'   * THE FRAME VERBS here -- what a figure needs that is about the WINDOW
'     rather than the model: its size and theme, the samples, a caret placed
'     by a line's text, a pane raised, a second window opened, a capture.
'
' THE WHOLE SCRIPT IS CHECKED BEFORE ANYTHING RUNS. A figure build that runs
' nine steps and refuses the tenth has already done nine steps' worth of work
' nobody wanted, and one that skipped a step it did not understand prints a
' plausible wrong picture -- the failure this project keeps meeting. So an
' unknown tool, a malformed line, a misplaced frame, an unknown option or a file
' name that climbs out of the output directory is refused with its LINE NUMBER,
' and nothing is opened.
'
' A FIGURE DOES NOT WRITE TO THE PROJECT. An `external` tool (save, delete,
' rename) is refused at the check, not at run time: the script would otherwise
' be a way to change somebody's files that looks like a way to photograph them.
library studio_shots

    load studio_tools
    load studio_ui
    load studio_permissions

    ' The frame verbs, a CLOSED set. Each one's options are closed too
    ' (`_options`), because a misspelt `scale` would print a figure at the
    ' wrong resolution and say nothing -- the argument gBASIC's own `capture`
    ' makes for closing its option set.
    function verbs()
        return ["frame", "open_samples", "open_folder", "caret_to", "raise",
                "open_window", "capture"]
    end function

    function _options(verb)
        if verb = "frame" then
            return ["width", "height", "theme", "zoom", "whitespace"]
        end if
        if verb = "open_folder" then
            return ["path"]
        end if
        if verb = "caret_to" then
            return ["text", "column"]
        end if
        if verb = "raise" then
            return ["pane"]
        end if
        if verb = "open_window" then
            return ["window", "row"]
        end if
        if verb = "capture" then
            return ["window", "part", "file", "scale"]
        end if
        return []
    end function

    function _required(verb)
        if verb = "open_folder" then
            return ["path"]
        end if
        if verb = "caret_to" then
            return ["text"]
        end if
        if verb = "raise" then
            return ["pane"]
        end if
        if verb = "open_window" then
            return ["window"]
        end if
        if verb = "capture" then
            return ["file"]
        end if
        return []
    end function

    ' The second windows a script can open and capture, and the main one.
    function windows()
        return ["main", "table", "newproject", "snippet", "schema"]
    end function

    ' The side panes `raise` can bring to the front -- the ids
    ' `studio_shell_qt.side_panes()` declares.
    function panes()
        return ["results", "branch", "tables", "git", "agent"]
    end function

    ' A capture's PART, by the name a figure caption would use. Anything else
    ' passes through as a real part name, which `qt.capture` checks and refuses
    ' listing the window's parts -- so a script can reach any part, and the
    ' common ones read as what they are. "" is the whole window.
    function part_for(name)
        if name = "" then
            return ""
        end if
        if name = "window" then
            return ""
        end if
        if name = "files" then
            return "dock_files"
        end if
        if name = "editor" then
            return "book"
        end if
        if name = "console" then
            return "dock_console"
        end if
        if name = "toolbar" then
            return "toolbar"
        end if
        if contains(studio_shots.panes(), name) then
            return "dock_" + name
        end if
        return name
    end function

    ' 2x unless the script says otherwise: a book's 6-inch text block at 300 dpi
    ' is about 1,800 pixels, which a 900-pixel pane fills at 2.
    function default_scale()
        return 2
    end function

    ' The steps of a script, or the reasons it will not run. Blank lines and
    ' lines starting with `#` are skipped, so a script can say what each figure
    ' is for; every other line is one JSON object.
    '
    ' Returns { steps: [ { line, tool, args } ], errors: [ "line N: ..." ] }.
    function script_steps(text)
        steps = []
        errors = []
        n = 0
        for each raw in split(text, chr(10))
            n += 1
            l = trim(raw)
            if l = "" then
                continue
            end if
            if starts_with(l, "#") then
                continue
            end if
            d = try_decode(l)
            if not d.ok then
                errors = append(errors, "line " + string(n) + ": not JSON")
                continue
            end if
            v = d.value
            if not is_record(v) then
                errors = append(errors, "line " + string(n) + ": not a JSON object")
                continue
            end if
            tool = v["tool"]
            if not is_string(tool) then
                errors = append(errors, "line " + string(n) + ": no \"tool\"")
                continue
            end if
            a = v["args"]
            if is_unknown(a) then
                a = {}
            end if
            if not is_record(a) then
                errors = append(errors, "line " + string(n) + ": \"args\" is not an object")
                continue
            end if
            for each k in keys(v)
                if not contains(["tool", "args"], k) then
                    errors = append(errors, "line " + string(n) + ": unknown key \"" + k + "\" (a step is tool and args)")
                end if
            end for
            why = studio_shots._check(tool, a, count(steps))
            if why != "" then
                errors = append(errors, "line " + string(n) + ": " + why)
                continue
            end if
            steps = append(steps, { line: n, tool: tool, args: a })
        end for
        if count(steps) = 0 then
            if count(errors) = 0 then
                errors = append(errors, "the script has no steps")
            end if
        end if
        return { steps: steps, errors: errors }
    end function

    ' Why one step will not run, or "". `at` is how many steps came before it.
    function _check(tool, a, at)
        if contains(studio_shots.verbs(), tool) then
            for each k in keys(a)
                if not contains(studio_shots._options(tool), k) then
                    return tool + " has no option \"" + k + "\" (it takes " + join(studio_shots._options(tool), ", ") + ")"
                end if
            end for
            for each k in studio_shots._required(tool)
                if is_unknown(a[k]) then
                    return tool + " needs \"" + k + "\""
                end if
            end for
            return studio_shots._check_verb(tool, a, at)
        end if
        if not studio_tools.is_tool(tool) then
            return "no such tool: " + tool
        end if
        if studio_tools.tier_of(tool) = "external" then
            return tool + " writes outside Studio, and a figure does not change the project"
        end if
        return ""
    end function

    function _check_verb(tool, a, at)
        if tool = "frame" then
            ' The frame is fixed BEFORE the window opens -- its size is
            ' declared, and an editor's theme is construction-only -- so it can
            ' only be the first step.
            if at != 0 then
                return "frame must be the first step (the window is built from it)"
            end if
            for each k in ["width", "height"]
                v = a[k]
                if not is_unknown(v) then
                    if not is_number(v) then
                        return "frame " + k + " must be a number"
                    end if
                    if v < 200 then
                        return "frame " + k + " must be at least 200"
                    end if
                    if v > 4000 then
                        return "frame " + k + " must be at most 4000"
                    end if
                end if
            end for
            t = a["theme"]
            if not is_unknown(t) then
                if not is_string(t) then
                    return "frame theme must be one of " + join(studio_ui.themes(), ", ")
                end if
                if not contains(studio_ui.themes(), t) then
                    return "frame theme must be one of " + join(studio_ui.themes(), ", ")
                end if
            end if
            z = a["zoom"]
            if not is_unknown(z) then
                ok = false
                if is_number(z) then
                    ok = contains(studio_ui.zoom_steps(), z)
                end if
                if not ok then
                    steps = []
                    for each st in studio_ui.zoom_steps()
                        steps = append(steps, string(st))
                    end for
                    return "frame zoom must be a step of the ladder: " + join(steps, ", ")
                end if
            end if
            w = a["whitespace"]
            if not is_unknown(w) then
                if not is_boolean(w) then
                    return "frame whitespace must be true or false"
                end if
            end if
            return ""
        end if
        if tool = "caret_to" then
            if not is_string(a["text"]) then
                return "caret_to text must be a string"
            end if
            if a["text"] = "" then
                return "caret_to text must not be empty"
            end if
            c = a["column"]
            if not is_unknown(c) then
                if not is_number(c) then
                    return "caret_to column must be a number"
                end if
                if c < 1 then
                    return "caret_to column is 1-based"
                end if
            end if
            return ""
        end if
        if tool = "open_folder" then
            if not is_string(a["path"]) then
                return "open_folder path must be a string"
            end if
            return ""
        end if
        if tool = "raise" then
            if not contains(studio_shots.panes(), default(a["pane"], "")) then
                return "raise pane must be one of " + join(studio_shots.panes(), ", ")
            end if
            return ""
        end if
        if tool = "open_window" then
            w = default(a["window"], "")
            if w = "main" then
                return "open_window: the main window is always open"
            end if
            if not contains(studio_shots.windows(), w) then
                return "open_window window must be one of " + join(studio_shots.windows(), ", ")
            end if
            r = a["row"]
            if not is_unknown(r) then
                if w != "table" then
                    return "open_window row is the Tables row, so only a table takes one"
                end if
                if not is_number(r) then
                    return "open_window row must be a number"
                end if
            end if
            return ""
        end if
        if tool = "capture" then
            why = studio_shots.file_problem(a["file"])
            if why != "" then
                return "capture " + why
            end if
            w = a["window"]
            if not is_unknown(w) then
                if not contains(studio_shots.windows(), w) then
                    return "capture window must be one of " + join(studio_shots.windows(), ", ")
                end if
            end if
            p = a["part"]
            if not is_unknown(p) then
                if not is_string(p) then
                    return "capture part must be a string"
                end if
            end if
            s = a["scale"]
            if not is_unknown(s) then
                if not is_number(s) then
                    return "capture scale must be a number"
                end if
                if s <= 0 then
                    return "capture scale must be above 0"
                end if
                if s > 8 then
                    return "capture scale must be at most 8"
                end if
            end if
            return ""
        end if
        return ""
    end function

    ' A figure's file is a PLAIN NAME IN THE OUTPUT DIRECTORY and nothing
    ' else: a `.png`, no `/`, no `~`. A shot script is a thing you can be sent,
    ' and one whose capture wrote `/home/you/.bashrc` would make replaying it a
    ' way to overwrite somebody's files -- the template `from` rule, again.
    ' No subdirectories either: `qt.capture` writes as `write` does and makes
    ' no folders, and one flat directory of figures is what a book build wants.
    function file_problem(f)
        if not is_string(f) then
            return "file must be a string"
        end if
        if f = "" then
            return "file must not be empty"
        end if
        if contains(f, "/") then
            return "file must be a plain name in the output directory, with no /"
        end if
        if starts_with(f, "~") then
            return "file must be a plain name in the output directory"
        end if
        if starts_with(f, ".") then
            return "file must not start with a dot"
        end if
        if not ends_with(lower(f), ".png") then
            return "file must be a .png"
        end if
        return ""
    end function

    ' The frame the script asks for, with Studio's defaults for what it leaves
    ' out. The size is the figure's, not the user's last window: a retake next
    ' month must be the same size.
    function frame_of(steps)
        f = { width: 1200, height: 800, theme: "dark", zoom: 1, whitespace: false }
        if count(steps) = 0 then
            return f
        end if
        if steps[0].tool != "frame" then
            return f
        end if
        a = steps[0].args
        for each k in keys(f)
            if not is_unknown(a[k]) then
                f[k] = a[k]
            end if
        end for
        return f
    end function

    ' The 1-based line whose text, leading whitespace aside, starts with
    ' `needle` -- or 0. By TEXT and not by number, as `qtview_samples` finds
    ' its lines: a figure of a section must not move when a comment above it
    ' is reworded.
    function line_of(text, needle)
        n = 1
        for each l in split(text, chr(10))
            if starts_with(trim(l), needle) then
                return n
            end if
            n += 1
        end for
        return 0
    end function

    ' A path in a script is relative to the SCRIPT, because a script lives
    ' beside the program it shows (`companion/volume-3/ch01/shots/`) and has to
    ' mean the same thing in every clone.
    function resolve(script_dir, p)
        if starts_with(p, "/") then
            return p
        end if
        if p = "." then
            return script_dir
        end if
        return script_dir + "/" + p
    end function

    ' The directory a script path is in.
    function dir_of(path)
        parts = split(path, "/")
        if count(parts) < 2 then
            return "."
        end if
        out = []
        i = 0
        while i < count(parts) - 1
            out = append(out, parts[i])
            i += 1
        end while
        d = join(out, "/")
        if d = "" then
            return "/"
        end if
        return d
    end function

    ' The policy a figure runs under: Studio's own reads and its local acts,
    ' and nothing external -- which the check has already refused, so this is
    ' the second statement of one rule and not the only one.
    function policy()
        return studio_permissions.effective({ read: "auto", local: "auto", external: "deny" }, nothing, nothing)
    end function

end library
