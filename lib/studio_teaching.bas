' studio_teaching — STU-10 the agent teaches by pointing (headless).
'
' §13: the agent should be able to say "the gutter, here" and have Studio draw
' attention to it — without screenshots and without pixel coordinates. What makes
' that possible is that Studio's UI elements have STABLE MACHINE-READABLE
' IDENTITIES, so "point at a thing" is a name lookup rather than a guess about
' where a window happens to be on screen.
'
' GENERALIZED, NOT A SPECIAL PATH (the §13 REQUIRED). This module knows nothing
' about GTK. It answers two questions over plain data:
'
'   * does this widget name exist, and what is it?
'   * what gesture was asked for, and is it one this widget can perform?
'
' and returns a CUE — a plain record the shell renders with the generic
' facilities the platform already has: a CSS class toggle, `grab_focus`, a
' `gi.timeout` pulse, a temporary `GtkTextTag` over a source range. No native
' component, and nothing in the shell that exists only for teaching.
'
' WHY A REGISTRY RATHER THAN "WHATEVER THE SHELL HAPPENS TO HOLD". A name the
' agent can point at is part of the agent's interface, and an interface derived
' from a widget tree changes silently whenever someone renames a field. Listing
' them makes a rename a visible edit — and lets a bad name be REFUSED with the
' list of real ones, which is what a model needs to correct itself.
'
' A CUE:
'   { widget, kind, gesture, ms, detail, ok, why }
library studio_teaching


    function schema_version()
        return 1
    end function

    ' The gestures §13 names, and what each is FOR. The distinction that matters
    ' is not visual, it is about attention: `focus` moves the keyboard, `reveal`
    ' moves the viewport, `highlight` and `pulse` move the eye. An agent that
    ' focuses when it meant to highlight takes the keyboard away from someone
    ' mid-sentence.
    function gestures()
        return ["highlight", "pulse", "focus", "reveal", "annotate"]
    end function

    function is_gesture(g)
        return contains(studio_teaching.gestures(), g)
    end function

    ' How long a pulse runs. Long enough to be seen, short enough that it is over
    ' before it becomes something the user has to wait out.
    function pulse_ms()
        return 1200
    end function

    ' The widgets an agent may point at, each with the kinds of gesture it can
    ' actually perform.
    '
    '   control  a button or entry: it can be highlighted, pulsed, focused
    '   pane     a region: highlighted, pulsed, revealed
    '   source   the editor's text: everything, plus `annotate` over a range
    '
    ' `annotate` is deliberately available on exactly one widget. It marks a RANGE
    ' of source, and a range means nothing on a button.
    function registry()
        out = []
        out = append(out, studio_teaching._w("browser", "pane", "the project file browser"))
        out = append(out, studio_teaching._w("tabs", "pane", "the row of open document tabs"))
        out = append(out, studio_teaching._w("editor", "source", "the source editor for the active document"))
        out = append(out, studio_teaching._w("gutter", "source", "the editor's gutter, where section boundaries are marked"))
        out = append(out, studio_teaching._w("run_strip", "pane", "the run controls and the state of the current run"))
        out = append(out, studio_teaching._w("output", "pane", "the prefix, target and error output panes"))
        out = append(out, studio_teaching._w("results", "pane", "the results pane for the section at the caret"))
        out = append(out, studio_teaching._w("branches", "pane", "the branch selector for the section at the caret"))
        out = append(out, studio_teaching._w("tables", "pane", "the table offers for the latest run"))
        out = append(out, studio_teaching._w("assistant", "pane", "the assistant pane"))
        out = append(out, studio_teaching._w("name_field", "control", "the header field that names new files, folders and branches"))
        out = append(out, studio_teaching._w("run_button", "control", "the Run button"))
        out = append(out, studio_teaching._w("save_button", "control", "the Save button"))
        out = append(out, studio_teaching._w("new_file_button", "control", "the New File button"))
        out = append(out, studio_teaching._w("new_folder_button", "control", "the New Folder button"))
        out = append(out, studio_teaching._w("overlay_strip", "control", "the overlay acts: edit, save, compare, rebase, promote, discard"))
        return out
    end function

    function _w(name, kind, description)
        return { name: name, kind: kind, description: description }
    end function

    function names()
        out = []
        for each w in studio_teaching.registry()
            out = append(out, w.name)
        end for
        return out
    end function

    function widget(name)
        for each w in studio_teaching.registry()
            if w.name = name then
                return w
            end if
        end for
        return nothing
    end function

    ' Which gestures a kind of widget can perform.
    function allowed(kind)
        if kind = "source" then
            return ["highlight", "pulse", "focus", "reveal", "annotate"]
        end if
        if kind = "pane" then
            return ["highlight", "pulse", "reveal"]
        end if
        if kind = "control" then
            return ["highlight", "pulse", "focus"]
        end if
        return []
    end function

    ' Build the cue, or say precisely why not.
    '
    ' A refusal LISTS THE REAL NAMES. A model that pointed at "the run panel" has
    ' to be able to correct itself, and "no such widget" alone leaves it guessing
    ' a second time — which is how a teaching request turns into three of them.
    function cue(name, gesture, detail)
        w = studio_teaching.widget(name)
        if w = nothing then
            return { widget: name, kind: "", gesture: gesture, ms: 0, detail: detail,
                     ok: false,
                     why: "no widget named " + quote(name) + "; there is " + join(studio_teaching.names(), ", ") }
        end if
        if not studio_teaching.is_gesture(gesture) then
            return { widget: name, kind: w.kind, gesture: gesture, ms: 0, detail: detail,
                     ok: false,
                     why: "no gesture named " + quote(gesture) + "; there is " + join(studio_teaching.gestures(), ", ") }
        end if
        if not contains(studio_teaching.allowed(w.kind), gesture) then
            return { widget: name, kind: w.kind, gesture: gesture, ms: 0, detail: detail,
                     ok: false,
                     why: name + " is a " + w.kind + ", which cannot " + gesture + "; it can " + join(studio_teaching.allowed(w.kind), ", ") }
        end if
        ' An annotation names a RANGE, and the range is validated here rather than
        ' later by the shell. A cue that reports ok and then cannot be drawn is a
        ' refusal the agent never hears about — it would believe it had pointed at
        ' something.
        if gesture = "annotate" then
            r = studio_teaching.range_of(detail)
            if not r.ok then
                return { widget: name, kind: w.kind, gesture: gesture, ms: 0, detail: detail,
                         ok: false, why: r.why }
            end if
        end if
        ms = 0
        if gesture = "pulse" then
            ms = studio_teaching.pulse_ms()
        end if
        return { widget: name, kind: w.kind, gesture: gesture, ms: ms, detail: detail,
                 ok: true, why: "" }
    end function

    ' The CSS class the shell toggles for a gesture. One place, because the shell
    ' and any stylesheet have to agree and a literal in each is two places to
    ' change.
    function css_class(gesture)
        if gesture = "highlight" then
            return "studio-teach-highlight"
        end if
        if gesture = "pulse" then
            return "studio-teach-pulse"
        end if
        return ""
    end function

    ' The stylesheet, so the classes above are defined somewhere rather than
    ' being names nothing renders. Deliberately restrained: teaching should draw
    ' the eye, not repaint the window.
    function css()
        lines = []
        lines = append(lines, "." + studio_teaching.css_class("highlight") + " {")
        lines = append(lines, "  outline: 2px solid #d08770;")
        lines = append(lines, "  outline-offset: -2px;")
        lines = append(lines, "}")
        lines = append(lines, "." + studio_teaching.css_class("pulse") + " {")
        lines = append(lines, "  outline: 3px solid #d08770;")
        lines = append(lines, "  outline-offset: -3px;")
        lines = append(lines, "  background-color: alpha(#d08770, 0.15);")
        lines = append(lines, "}")
        return join(lines, "\n") + "\n"
    end function

    ' What an annotation tints. A different colour from STU-5's section tint on
    ' purpose: one says "this is where you are" and the other says "look here",
    ' and if they matched, the second would be invisible inside the first.
    function annotate_colour()
        return "#ffe9b0"
    end function

    ' A source annotation's range, parsed from the tool's detail. Two forms, both
    ' 0-based as the editor counts:  "12"  a single line
    '                                "12-18"  a span
    ' A malformed range is refused rather than defaulted to line 0, which would
    ' point confidently at the wrong place — worse than not pointing at all.
    function range_of(detail)
        if not is_string(detail) then
            return { ok: false, first: 0, last: 0, why: "an annotation needs a line or a line range" }
        end if
        t = trim(detail)
        if t = "" then
            return { ok: false, first: 0, last: 0, why: "an annotation needs a line or a line range" }
        end if
        parts = split(t, "-")
        if count(parts) > 2 then
            return { ok: false, first: 0, last: 0, why: quote(detail) + " is not a line or a line range" }
        end if
        a = studio_teaching._num(parts[0])
        if not a.ok then
            return { ok: false, first: 0, last: 0, why: quote(detail) + " is not a line or a line range" }
        end if
        b = a
        if count(parts) = 2 then
            b = studio_teaching._num(parts[1])
            if not b.ok then
                return { ok: false, first: 0, last: 0, why: quote(detail) + " is not a line or a line range" }
            end if
        end if
        if b.value < a.value then
            return { ok: false, first: 0, last: 0, why: "the range " + detail + " ends before it starts" }
        end if
        return { ok: true, first: a.value, last: b.value, why: "" }
    end function

    ' `number()` raises on text that is not a number, and gBASIC cannot catch a
    ' raise — so the digits are checked before the conversion rather than after.
    function _num(text)
        t = trim(text)
        if t = "" then
            return { ok: false, value: 0 }
        end if
        i = 0
        while i < len(t)
            c = mid(t, i, 1)
            if c < "0" then
                return { ok: false, value: 0 }
            end if
            if c > "9" then
                return { ok: false, value: 0 }
            end if
            i = i + 1
        end while
        return { ok: true, value: number(t) }
    end function

    function describe(c)
        if not c.ok then
            return "refused: " + c.why
        end if
        line = c.gesture + " " + c.widget + " (" + c.kind + ")"
        if c.ms > 0 then
            line = line + " for " + c.ms + "ms"
        end if
        if c.detail != "" then
            line = line + " at " + c.detail
        end if
        return line
    end function

    function summary()
        out = []
        out = append(out, "widgets an agent may point at:")
        for each w in studio_teaching.registry()
            out = append(out, "  " + w.name + " (" + w.kind + ") — " + w.description)
            out = append(out, "      can: " + join(studio_teaching.allowed(w.kind), ", "))
        end for
        return out
    end function

end library
