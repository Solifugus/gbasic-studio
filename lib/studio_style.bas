' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_style.bas — the one stylesheet, and the one way to wear it.
'
' Studio had no visual design: no margins anywhere in the repository, one CSS
' provider carrying two teaching outlines, and a right-hand column that read as
' an undifferentiated list of sentences. This library is where the window's
' appearance is decided, so a pane does not get to invent its own.
'
' WHY A LIBRARY AND NOT A DISPLAY-WIDE PROVIDER. This header used to say the
' conventional answer -- `Gtk.StyleContext.add_provider_for_display` -- was out
' of reach because it is a class static. MEASURED, it is NOT: `gi.invoke` calls
' it, and `widget.get_display()` supplies the display an instance method at a
' time, exactly as `get_settings()` does for `Gtk.Settings.get_default`. So the
' per-widget provider is a CHOICE, not a constraint. It still earns its keep --
' a provider scoped to the widgets that need it cannot leak into another window
' -- but a whole-window theme would use the display-wide call, and that is now
' a measured option rather than a closed door. Providers here go on ONE WIDGET
' AT A TIME — which is what studio_teaching already discovered for its two outline
' classes. The cost of that is a rule every call site would otherwise have to
' remember ("add the class AND attach the provider, or the class is a name
' nothing renders"), so `apply` does both and nothing calls `add_css_class`
' directly any more.
'
' THE PROVIDER IS A PROGRAM GLOBAL, `_STUDIO_STYLE`, assigned once by
' app/studio.bas beside `_DATAGRID` and `_STUDIO_TABLE` and for the same reason:
' gBASIC functions do not close over state, and a provider rebuilt per call would
' reparse this stylesheet on every widget and stack one provider per redraw on
' the labels that change state. It is assigned in the display-mode block, after
' the `load`s and before any widget exists, so every path that can reach a widget
' has it. Reading an unassigned global RAISES in gBASIC — there is no probing
' around it — which is why the assignment is unconditional rather than lazy.
'
' THE THEME IS THE USER'S. Every colour here is one of GTK's own named colours
' (@theme_fg_color, @theme_bg_color, @borders, @accent_color, @error_color) or an
' alpha()/shade() of one, so the window follows the system light/dark setting
' instead of assuming a light background. Nothing is a hex literal; the only
' deliberate hues in Studio are studio_teaching's, which say "look here" and must
' not be a theme colour.
'
' SPACING UNIT: 6px. Every margin and padding in Studio is a multiple of it — 6
' inside a group, 12 between groups and at the window edge, 18 where a pane needs
' to breathe. Container padding lives in this stylesheet (.toolbar, .statusbar,
' .panel); per-widget margins live in studio_shell as `studio_style.unit()`
' multiples, because a margin set in CSS and a margin set in code do not add up
' in any order a reader can predict.
library studio_style

    ' Dependencies, declared rather than assumed.
    load gi

    ' The spacing unit, in pixels. Callers multiply; nobody writes a bare number.
    function unit()
        return 6
    end function

    ' One level of the browser's tree, in pixels.
    '
    ' Eight and not `unit() * 2`, measured rather than chosen: the tree used to
    ' be indented with two SPACES per level inside the row's text, and twelve
    ' pixels is visibly wider than that font's two spaces — enough that two
    ' file names started ellipsizing which had fitted before. Making the
    ' indentation exact must not cost the names the width it was meant to save
    ' them, so this is about what two spaces were, and the gain is that it is
    ' now the same at every depth and in every font.
    function indent()
        return 8
    end function

    ' Logical class name -> the class actually written on the widget. The short
    ' names are what call sites read ("head", "dim"); the prefix is what keeps
    ' them from colliding with a theme class of the same name — `.toolbar` and
    ' `.dim` are both live in stock Adwaita, and silently inheriting whatever a
    ' theme does with them is not styling, it is a coincidence.
    '
    ' Two names deliberately pass through unprefixed because they ARE stock and we
    ' want the theme's version: "suggested-action" and "destructive-action".
    function css_class(name)
        if name = "suggested-action" then
            return name
        end if
        if name = "destructive-action" then
            return name
        end if
        return "studio-" + name
    end function

    ' The stylesheet. One string, one provider, every class Studio uses.
    function css()
        lines = []

        ' ---- type scale -----------------------------------------------------
        ' Body is whatever the theme says; the scale is expressed relative to it
        ' so a user who has set a larger interface font keeps the proportions.
        lines = append(lines, ".studio-body { font-size: 1em; }")
        ' Help text and other prose. Smaller and muted so CONTROLS outrank
        ' sentences: the right-hand column was five explanatory paragraphs with
        ' the buttons lost between them.
        lines = append(lines, ".studio-dim {")
        lines = append(lines, "  font-size: 0.9em;")
        lines = append(lines, "  color: alpha(@theme_fg_color, 0.62);")
        lines = append(lines, "}")
        ' A panel heading: bold, slightly SMALLER than body, and a shade lighter —
        ' the combination that reads as a label for what follows rather than as a
        ' sentence competing with it.
        '
        ' NO `letter-spacing`, and that is not taste. A label with letter-spacing
        ' reports a NATURAL WIDTH that does not include the spacing, so a wrapping
        ' label allocated its own natural width wraps inside it: measured here,
        ' "Errors" came back 38px wide and rendered on two lines, broken as
        ' "Error-/s". The output pane's three headings all did it the moment the
        ' class went on. It is the same class of defect as `wrap = true` not
        ' making a label wrap — the widget's own measurement disagrees with what
        ' it draws — and no golden can see either, because the text is identical
        ' whether the label folded it or not.
        lines = append(lines, ".studio-head {")
        lines = append(lines, "  font-size: 0.82em;")
        lines = append(lines, "  font-weight: bold;")
        lines = append(lines, "  color: alpha(@theme_fg_color, 0.78);")
        lines = append(lines, "}")
        ' Captured output and anything else a user will copy out.
        lines = append(lines, ".studio-mono {")
        lines = append(lines, "  font-family: monospace;")
        lines = append(lines, "  font-size: 0.92em;")
        lines = append(lines, "}")
        ' The toolbar's leading wordmark. It looked like a dead button sitting
        ' flush against New Project; this makes it read as the window's name.
        lines = append(lines, ".studio-title {")
        lines = append(lines, "  font-weight: bold;")
        lines = append(lines, "  color: alpha(@theme_fg_color, 0.72);")
        lines = append(lines, "}")

        ' ---- regions --------------------------------------------------------
        ' Padding lives here, not in code, for the three containers that want an
        ' edge as well as an inset.
        lines = append(lines, ".studio-toolbar {")
        lines = append(lines, "  background-color: shade(@theme_bg_color, 0.97);")
        lines = append(lines, "  border-bottom: 1px solid @borders;")
        lines = append(lines, "  padding: 6px 12px 6px 12px;")
        lines = append(lines, "}")
        lines = append(lines, ".studio-statusbar {")
        lines = append(lines, "  background-color: shade(@theme_bg_color, 0.97);")
        lines = append(lines, "  border-top: 1px solid @borders;")
        lines = append(lines, "  padding: 6px 12px 6px 12px;")
        lines = append(lines, "  font-size: 0.9em;")
        lines = append(lines, "  color: alpha(@theme_fg_color, 0.75);")
        lines = append(lines, "}")
        ' A pane in the right-hand column or under the editor. No padding at the
        ' TOP: the rule that opens a pane brings its own margin, and adding both
        ' put 42px between every pair of panes — enough that the assistant's last
        ' line fell off the bottom of a column that used to hold all five.
        lines = append(lines, ".studio-panel {")
        lines = append(lines, "  padding: 0px 12px 6px 12px;")
        lines = append(lines, "}")
        ' The rule above a panel heading. GtkSeparator draws itself; this only
        ' keeps it from touching what it separates.
        lines = append(lines, ".studio-rule {")
        lines = append(lines, "  margin-top: 6px;")
        lines = append(lines, "  margin-bottom: 6px;")
        lines = append(lines, "  background-color: alpha(@borders, 0.8);")
        lines = append(lines, "}")
        ' A list with nothing in it should not draw a list. A GtkListBox paints
        ' the theme's view background, and an empty browser shrunk to its one
        ' "(no workspace open)" row painted a white strip floating in the middle
        ' of a grey pane — which reads as a control, not as an absence.
        lines = append(lines, ".studio-flat {")
        lines = append(lines, "  background-color: transparent;")
        lines = append(lines, "}")
        ' What fills a pane that has nothing in it. Centred by the caller, muted
        ' here: "(no document open)" is a state, not a message worth shouting.
        lines = append(lines, ".studio-empty {")
        lines = append(lines, "  font-size: 1.05em;")
        lines = append(lines, "  color: alpha(@theme_fg_color, 0.45);")
        lines = append(lines, "}")

        ' ---- state ----------------------------------------------------------
        ' The run strip said "run: running" and "run: failed" in identical grey.
        ' The TEXT is unchanged — the goldens assert it — and the colour is the
        ' part a person reads from across the desk.
        lines = append(lines, ".studio-state-idle {")
        lines = append(lines, "  color: alpha(@theme_fg_color, 0.70);")
        lines = append(lines, "}")
        ' @success_color and NOT @accent_color. The accent is a FILL colour in
        ' several themes — Breeze's is the pale blue a selected row is painted
        ' with — and "run: running" in it was very nearly invisible against the
        ' pane, which is the one state where the colour is the whole point.
        ' @error_color, @warning_color and @success_color are the three GTK
        ' defines as text, so those are the three this uses.
        lines = append(lines, ".studio-state-running {")
        lines = append(lines, "  color: @success_color;")
        lines = append(lines, "  font-weight: bold;")
        lines = append(lines, "}")
        lines = append(lines, ".studio-state-error {")
        lines = append(lines, "  color: @error_color;")
        lines = append(lines, "  font-weight: bold;")
        lines = append(lines, "}")
        ' The one menu item that removes a file from disk. NOT the stock
        ' `.destructive-action`: that class paints a BACKGROUND, and the
        ' theme's own `button:hover` background beats it -- looked at, with the
        ' hover state forced on, the tint vanished and Delete rendered
        ' identically to Close Tab. The warning disappeared at the one moment
        ' it is being read, the instant before the click, and it did so whether
        ' the button had a frame or not.
        '
        ' Colouring the TEXT survives that, because @error_color is one of the
        ' three GTK defines as a text colour (the note above says so), and this
        ' provider goes on at 500 where the theme is at 200 -- so the hover
        ' background changes underneath and the label stays red. Said twice, at
        ' rest and on hover, so the rule reads as the deliberate thing it is.
        lines = append(lines, ".studio-danger {")
        lines = append(lines, "  color: @error_color;")
        lines = append(lines, "}")
        lines = append(lines, ".studio-danger:hover {")
        lines = append(lines, "  color: @error_color;")
        lines = append(lines, "}")
        ' An unsaved buffer. Reserved for the tab marker studio_ui already spells
        ' with a "*", so the mark is legible with or without colour.
        lines = append(lines, ".studio-dirty {")
        lines = append(lines, "  font-style: italic;")
        lines = append(lines, "  color: @warning_color;")
        lines = append(lines, "}")

        return join(lines, "\n") + "\n"
    end function

    ' ---- the source editor's colours ----------------------------------------
    '
    ' A GtkSourceView paints from a STYLE SCHEME, which is its own thing and not
    ' the GTK theme — and nothing ever set one. So the editor sat on the light
    ' default while every widget around it followed a dark theme, and the window
    ' read as two applications sharing a frame. This stylesheet cannot reach it:
    ' a scheme is a GtkSourceStyleScheme object, not CSS.
    '
    ' PURE, over four plain values the shell reads off the toolkit. That split is
    ' the point: which scheme to use is a decision, and a decision that lives in
    ' a signal handler is one no headless test can make. `scheme_for` is the
    ' whole of it; the shell only reads `get_settings()` and hands the strings
    ' over.

    ' `classic` is what a GtkSourceBuffer picks on its own — measured, by asking
    ' a fresh buffer for `get_style_scheme` before anything set one. So the light
    ' editor is EXACTLY what it has always been, and `classic-dark` is that same
    ' scheme's own dark counterpart. Naming the light one explicitly rather than
    ' leaving it unset is the point: the two are then a matched pair chosen here,
    ' instead of one choice and one accident.
    function light_scheme()
        return "classic"
    end function

    function dark_scheme()
        return "classic-dark"
    end function

    ' `theme` is Studio's OWN setting (studio_model's `settings.theme`), which
    ' has been persisted since STU-0 with nothing reading it. "system" defers to
    ' the toolkit; "light" and "dark" are the user overruling it, and they win —
    ' someone who has said which one they want is not asking to be guessed at.
    function dark_for(theme, theme_name, prefer_dark, gtk_theme_env)
        if theme = "dark" then
            return true
        end if
        if theme = "light" then
            return false
        end if
        return studio_style.toolkit_is_dark(theme_name, prefer_dark, gtk_theme_env)
    end function

    ' ONE decision, two things read it — the editor's scheme and the section
    ' tint. Asking the toolkit twice would let a user who set `theme: "dark"` on
    ' a light desktop get a dark editor with a light tint smeared across it.
    function scheme_for(theme, theme_name, prefer_dark, gtk_theme_env)
        dark = studio_style.dark_for(theme, theme_name, prefer_dark, gtk_theme_env)
        if dark then
            return studio_style.dark_scheme()
        end if
        return studio_style.light_scheme()
    end function

    ' THREE signals, because no one of them is enough — measured on this machine
    ' rather than assumed:
    '
    '   `gtk-application-prefer-dark-theme`  the honest answer when it is set,
    '       which is GNOME and anything using libadwaita. It was FALSE here in a
    '       window that was plainly dark.
    '   `gtk-theme-name`                     carries it for the themes that ship
    '       a separate dark variant ("Breeze-Dark", "Adwaita-dark"). It said
    '       "Breeze" here in the same dark window.
    '   GTK_THEME                            the env override ("Adwaita:dark"),
    '       which changes what is DRAWN without touching either setting above.
    '       It is the one that was true here.
    '
    ' Any one of them saying dark is taken as dark. The failure this guards is
    ' asymmetric: a light editor in a dark window is the bug being fixed, and a
    ' dark editor in a light window is the same bug mirrored, so neither default
    ' is safe — but only the three together got this machine right.
    function toolkit_is_dark(theme_name, prefer_dark, gtk_theme_env)
        if prefer_dark = true then
            return true
        end if
        named = studio_style._names_dark(theme_name)
        if named then
            return true
        end if
        return studio_style._names_dark(gtk_theme_env)
    end function

    ' "Adwaita-dark", "Breeze-Dark", "Adwaita:dark" — three separators between
    ' the same two words. Substring and case-insensitive rather than a list of
    ' spellings, which would go stale the first time a theme invented a fourth.
    ' `find` answers `nothing` for a string miss, not -1.
    function _names_dark(s)
        if not is_string(s) then
            return false
        end if
        hit = find(lower(s), "dark")
        return hit != nothing
    end function

    ' The tint over the section at the caret, which had the same problem in
    ' smaller print: a hardcoded pale blue is a highlight on a light editor and
    ' a smear over unreadable text on a dark one. Not CSS either — it is a
    ' GtkTextTag background, so it cannot be an `@theme` reference.
    ' The band behind the section the caret is in.
    '
    ' The dark value was lowered once it actually filled the line. `#2f3b4d`
    ' was chosen against a tint that hugged the characters -- a ragged outline
    ' needs contrast to read as anything at all. As a full-width band across
    ' `#141516` the same colour was louder than the code it was marking, which
    ' is backwards: this says WHERE you are, and the text is what you are
    ' reading. Reported as too strong, and lowered by roughly a third.
    function section_tint(dark)
        if dark then
            return "#212934"
        end if
        return "#eaf1fb"
    end function

    ' Build the shared provider. Called ONCE, by app/studio.bas, into
    ' `_STUDIO_STYLE`.
    function new_provider()
        prov = gi.new("Gtk.CssProvider")
        prov.load_from_string(studio_style.css())
        return prov
    end function

    ' Put a class on a widget AND make sure the widget can see the stylesheet
    ' that defines it. Both halves, always, because either one alone renders
    ' nothing. Returns the widget, so it chains onto the label helpers.
    '
    ' Priority 500 — below studio_teaching's 600, so a teaching outline still
    ' wins over the panel look it is drawn on top of.
    function apply(w, name)
        if w = nothing then
            return w
        end if
        w.add_css_class(studio_style.css_class(name))
        ' Bound rather than chained: gBASIC does not accept a method call on the
        ' result of a method call as a statement.
        ctx = w.get_style_context()
        ctx.add_provider(_STUDIO_STYLE, 500)
        return w
    end function

    ' Attach the stylesheet without adding a class — for a widget that carries a
    ' stock class (suggested-action) but still needs Studio's own rules to reach
    ' it, and for a container whose children are styled.
    function attach(w)
        if w = nothing then
            return w
        end if
        ctx = w.get_style_context()
        ctx.add_provider(_STUDIO_STYLE, 500)
        return w
    end function

    ' ---- state ---------------------------------------------------------------

    ' Which state class a run session wears. A PURE function over the session
    ' record — no GTK — so the mapping can be read, and later asserted, without a
    ' display.
    '
    ' Three buckets, not eight: idle covers "nothing is happening and nothing went
    ' wrong", running covers every state studio_session calls active, error covers
    ' every way a run can fail to be a clean exit. A palette with one colour per
    ' state would be a legend to memorize.
    function state_class(session)
        if session = nothing then
            return "state-idle"
        end if
        s = session.state
        if s = "materializing" then
            return "state-running"
        end if
        if s = "running" then
            return "state-running"
        end if
        if s = "stopping" then
            return "state-running"
        end if
        if s = "unresponsive" then
            return "state-error"
        end if
        if s = "failed" then
            return "state-error"
        end if
        if s = "refused" then
            return "state-error"
        end if
        if s = "finished" then
            if session.signal != 0 then
                return "state-error"
            end if
            if session.exit_code != 0 then
                return "state-error"
            end if
            return "state-idle"
        end if
        return "state-idle"
    end function

    ' Every state class, so setting one can clear the others. A widget that
    ' accumulated classes would end up wearing the first state it was ever in.
    function state_classes()
        return ["state-idle", "state-running", "state-error"]
    end function

    ' Move a widget to one state class. Called on every run poll — sixteen times a
    ' second — so it adds no provider: `apply` did that once when the widget was
    ' built, and a provider added per tick would stack one per tick for the life of
    ' the process.
    ' Returns nothing on purpose. A widget handle is a reference, so the classes
    ' are already changed when this returns; handing the widget back would invite
    ' `shell.bar.state = set_state(...)`, which writes a record field for no
    ' reason — and gBASIC warns about a discarded result only when there is one.
    function set_state(w, name)
        if w = nothing then
            return nothing
        end if
        for each c in studio_style.state_classes()
            w.remove_css_class(studio_style.css_class(c))
        end for
        w.add_css_class(studio_style.css_class(name))
        return nothing
    end function

    ' Take a widget OUT of every state class without putting it in another one.
    ' `set_state` cannot express this — it always adds — and "no state" is not
    ' the same as `state-idle`: idle is a colour of its own, and a widget that
    ' already had a look (a heading, say) should get its own look back rather
    ' than the idle one. Same no-provider reason as `set_state`: whatever put
    ' the widget's own class on it attached the provider once, at build time.
    function clear_state(w)
        if w = nothing then
            return nothing
        end if
        for each c in studio_style.state_classes()
            w.remove_css_class(studio_style.css_class(c))
        end for
        return nothing
    end function

    ' ---- the dark sheet (STU-19) --------------------------------------------
    '
    ' WHY THIS EXISTS AT ALL, when every other colour here is a GTK named
    ' colour so the window follows the desktop. Because that rule gave Studio no
    ' way to BE dark: the editor's style scheme is Studio's to choose, but the
    ' chrome around it is the theme's, so choosing Dark produced a black editor
    ' inside a light window -- the "two applications sharing a frame" complaint
    ' that started the style work, arriving from the other direction.
    '
    ' The conventional fix is `gtk-application-prefer-dark-theme`. Measured: it
    ' does nothing under Breeze, which is what `toolkit_is_dark` already records
    ' about that property. GTK 4 moved the concern into libadwaita, which the
    ' bridge cannot reach.
    '
    ' So Studio ships its own. This is a small, app-scoped GTK theme, and the
    ' honest description is that Studio OWNS one look (dark) and otherwise
    ' defers entirely.
    '
    ' ---------------------------------------------------------------------------
    ' TWO THINGS MEASURED BEFORE IT WAS WRITTEN, both of which shape it.
    '
    ' 1. `@define-color` of the conventional tokens changes NOTHING on its own.
    '    Breeze-gtk does not draw with `@theme_bg_color`; it has its own values
    '    baked in. Redefining them at priority 800 left the window untouched.
    '    Only direct RULES override what the theme drew.
    '
    ' 2. But the tokens ARE worth defining, because they cross providers. A
    '    `@define-color` in THIS sheet (display-wide, 800) is visible to the
    '    rules in `css()` (per widget, 500) -- proven with a label that went
    '    red. That is why `css()` needed no changes: every `.studio-*` rule
    '    follows these definitions automatically.
    '
    ' So the sheet has two halves: tokens for Studio's own rules, and node rules
    ' for what the theme draws.
    '
    ' ---------------------------------------------------------------------------
    ' A WRONG NODE NAME FAILS SILENTLY, which is the whole risk here. `listbox`
    ' is not the node -- it is `list` -- and a row's background is on `row`, not
    ' on the list. Two silent misses in a five-minute probe. Nothing errors; the
    ' widget just stays light. No golden can see it either, because the asserted
    ' text is identical. The only check is to LOOK.

    ' Where this provider sits. Above the theme (200) and above Studio's own
    ' per-widget sheet (500), because it has to beat what Breeze drew.
    function dark_priority()
        return 800
    end function

    ' ---- the editor's text size (STU-20) ------------------------------------

    ' `em`, not `pt`. The multiplier is applied to whatever the desktop's font
    ' setting already gives, so enlarging the system font still enlarges the
    ' editor and this only says how much FURTHER the code goes. An absolute
    ' size would opt the editor out of that.
    '
    ' `textview` is the node a GtkSourceView draws under, so this reaches the
    ' source editors and the overlay editor and nothing else -- Studio's other
    ' text is labels.
    function zoom_css(scale)
        return "textview { font-size: " + string(scale) + "em; }"
    end function

    ' Its own provider and its own priority, separate from the dark sheet:
    ' the two are independent (text size applies in either theme) and a single
    ' provider would mean rebuilding the whole dark sheet to change a font.
    function zoom_priority()
        return 810
    end function

    function dark_css()
        l = []

        ' ---- tokens -----------------------------------------------------------
        ' Read by `css()`, one provider down. These are the only reason the
        ' existing stylesheet did not have to change.
        l = append(l, "@define-color theme_bg_color " + studio_style.dark_bg() + ";")
        l = append(l, "@define-color theme_base_color " + studio_style.dark_base() + ";")
        l = append(l, "@define-color theme_fg_color " + studio_style.dark_fg() + ";")
        l = append(l, "@define-color theme_text_color " + studio_style.dark_fg() + ";")
        l = append(l, "@define-color theme_selected_bg_color " + studio_style.dark_sel() + ";")
        l = append(l, "@define-color theme_selected_fg_color #ffffff;")
        l = append(l, "@define-color insensitive_bg_color " + studio_style.dark_bg() + ";")
        l = append(l, "@define-color insensitive_fg_color " + studio_style.dark_dim() + ";")
        l = append(l, "@define-color borders " + studio_style.dark_line() + ";")
        ' The three GTK defines as TEXT colours, brightened for a dark ground --
        ' the light-theme reds and greens are unreadable on #1f2022.
        l = append(l, "@define-color error_color #ff6b63;")
        l = append(l, "@define-color warning_color #e0b341;")
        l = append(l, "@define-color success_color #63c073;")
        l = append(l, "@define-color accent_color #4a9eff;")

        ' ---- the surface ------------------------------------------------------
        l = append(l, "window, .background { background-color: " + studio_style.dark_bg() + "; color: " + studio_style.dark_fg() + "; }")
        ' Bare labels need saying explicitly: a label with no class keeps the
        ' theme's own foreground, which on a dark ground is nearly invisible.
        ' Looked at -- "plain label, no class" rendered dark grey on dark grey.
        l = append(l, "label { color: " + studio_style.dark_fg() + "; }")
        l = append(l, "box, grid, paned, stack { background-color: transparent; }")

        ' ---- controls ---------------------------------------------------------
        ' `background-image: none` as well as a colour: GTK themes paint buttons
        ' with a gradient, and setting only the colour leaves the gradient on
        ' top of it.
        l = append(l, "button { background-image: none; background-color: " + studio_style.dark_ctl() + "; color: " + studio_style.dark_fg() + "; border: 1px solid " + studio_style.dark_line() + "; }")
        l = append(l, "button:hover { background-color: " + studio_style.dark_ctl_hi() + "; }")
        l = append(l, "button:active, button:checked { background-color: " + studio_style.dark_sel() + "; color: #ffffff; }")
        l = append(l, "button:disabled { color: " + studio_style.dark_dim() + "; }")
        l = append(l, "entry, spinbutton { background-image: none; background-color: " + studio_style.dark_base() + "; color: " + studio_style.dark_fg() + "; border: 1px solid " + studio_style.dark_line() + "; }")
        l = append(l, "entry:focus { border-color: " + studio_style.dark_sel() + "; }")
        l = append(l, "checkbutton, radiobutton { color: " + studio_style.dark_fg() + "; }")
        l = append(l, "dropdown, dropdown > button { background-color: " + studio_style.dark_ctl() + "; color: " + studio_style.dark_fg() + "; }")

        ' ---- lists ------------------------------------------------------------
        ' `list`, not `listbox` -- and the row carries its own background, which
        ' is the same fact `_fill_nav` already works around for the empty
        ' browser. Both were silent misses when first written.
        l = append(l, "list, listview, columnview { background-color: " + studio_style.dark_base() + "; color: " + studio_style.dark_fg() + "; }")
        l = append(l, "row { background-color: " + studio_style.dark_base() + "; color: " + studio_style.dark_fg() + "; }")
        l = append(l, "row:hover { background-color: " + studio_style.dark_ctl() + "; }")
        l = append(l, "row:selected { background-color: " + studio_style.dark_sel() + "; color: #ffffff; }")

        ' ---- structure --------------------------------------------------------
        l = append(l, "notebook > header { background-color: " + studio_style.dark_bg() + "; }")
        l = append(l, "notebook > header > tabs > tab { background-color: " + studio_style.dark_ctl() + "; color: " + studio_style.dark_fg() + "; }")
        l = append(l, "notebook > header > tabs > tab:checked { background-color: " + studio_style.dark_base() + "; }")
        l = append(l, "notebook > stack { background-color: " + studio_style.dark_base() + "; }")
        l = append(l, "paned > separator { background-color: " + studio_style.dark_line() + "; }")
        l = append(l, "separator { background-color: " + studio_style.dark_line() + "; }")
        l = append(l, "scrolledwindow, viewport { background-color: " + studio_style.dark_base() + "; }")
        l = append(l, "scrollbar { background-color: " + studio_style.dark_bg() + "; }")
        l = append(l, "scrollbar slider { background-color: " + studio_style.dark_ctl_hi() + "; }")
        ' The menus and the browser's right-click menu.
        l = append(l, "popover > contents, popover > arrow { background-color: " + studio_style.dark_ctl() + "; color: " + studio_style.dark_fg() + "; border: 1px solid " + studio_style.dark_line() + "; }")
        ' The gutter beside the editor. The editor's own colours are the STYLE
        ' SCHEME's, not CSS, and are chosen by `scheme_for` -- this is only the
        ' margin around it.
        l = append(l, "textview { background-color: " + studio_style.dark_base() + "; color: " + studio_style.dark_fg() + "; }")
        l = append(l, "tooltip, tooltip.background { background-color: " + studio_style.dark_ctl() + "; color: " + studio_style.dark_fg() + "; }")

        return join(l, "\n")
    end function

    ' The palette, named once each. Literals, unavoidably -- a dark sheet IS a
    ' set of colours, and there is no token to defer to when the whole point is
    ' that the theme has none that suit. `section_tint` already made this trade
    ' for the same reason.
    function dark_bg()
        return "#1f2022"
    end function

    function dark_base()
        return "#141516"
    end function

    function dark_ctl()
        return "#2b2d31"
    end function

    function dark_ctl_hi()
        return "#363940"
    end function

    function dark_fg()
        return "#d6d6d6"
    end function

    function dark_dim()
        return "#6f7175"
    end function

    function dark_line()
        return "#3a3c3f"
    end function

    function dark_sel()
        return "#2f6fb5"
    end function

    ' ======================================================================
    ' STU-22 -- THE SAME DARK, AS A QT STYLE SHEET.
    '
    ' `qt.theme(sheet)` takes ONE sheet for the whole application, which is the
    ' display-wide GTK provider's counterpart and arrived for the same reason:
    ' it restyles nodes Studio never touches. What it is NOT is the same text.
    ' A QSS selects on Qt CLASS NAMES (`QMenuBar::item`) where `dark_css`
    ' selects on GTK node names (`menubar > item`), so none of those 72 lines
    ' carry over -- but every COLOUR does, through the same `dark_*` functions
    ' above. One palette, two renderings: the arrangement `row_label` and
    ' `row_text` already have, and the opposite of two independent sets of
    ' literals drifting apart.
    '
    ' WHAT THIS SHEET CANNOT DO, stated because the menu has to say it: a
    ' stylesheet DOES NOT MOVE QT'S PALETTE, and the editor's syntax colours
    ' come from the `source` part's own `theme:` -- which is a CONSTRUCTION
    ' option, measured: `qt.read` and `qt.set` both refuse it by name ("a
    ' QPlainTextEdit has no `theme` property"). So the chrome re-themes the
    ' instant the menu is pressed and the highlighting of an editor already
    ' built does not. That is the GTK fault this phase exists to avoid --
    ' dark chrome around a light editor -- so the SOURCE PART IS DECLARED FROM
    ' THE SETTING and the notice says the rest follows next launch.
    '
    ' NOT ASSERTED BY ANY GOLDEN, AND IT CANNOT BE: a wrong Qt selector is
    ' silently ignored exactly as a wrong GTK node name is, and the risk
    ' `studio_style`'s own header states ("a wrong node name fails silently,
    ' and that is the whole risk") applies here unchanged. What a tier CAN
    ' assert is that the sheet is set, that it is the sheet asked for, and that
    ' Qt parsed it without complaint. Whether it LOOKS right is a judgement
    ' that needs eyes on the window.
    ' ======================================================================
    ' ONE DECISION, and under Qt it has no toolkit half.
    '
    ' `dark_for` asks GTK three questions (the theme name, the prefer-dark
    ' setting, GTK_THEME) because none of them alone carries the answer -- see
    ' `toolkit_is_dark`. Qt offers Studio NO equivalent: gBASIC exposes no
    ' colour-scheme reader, so "follow the desktop" can only mean SET NO SHEET
    ' OF OUR OWN and let the platform style stand, which is what the words
    ' already promise.
    '
    ' THE COST IS NAMED RATHER THAN HIDDEN. A person on a dark desktop who
    ' chooses "Follow the desktop" gets dark chrome from their own platform
    ' style and LIGHT highlighting in the editor, because the `source` part's
    ' `theme:` has to be declared and there is nothing to derive it from. That
    ' is the GTK defect STU-19 removed, and the answer is the same one STU-19
    ' gave: Studio owns one look, dark, and choosing Dark is how you get it.
    function qt_dark_for(theme)
        return theme = "dark"
    end function

    ' The `source` part's `theme:`, which is `"light"` or `"dark"` and nothing
    ' else. One place, because the shell declares it and a tier asserts it.
    function qt_source_theme(theme)
        if studio_style.qt_dark_for(theme) then
            return "dark"
        end if
        return "light"
    end function

    function dark_qss()
        bg = studio_style.dark_bg()
        base = studio_style.dark_base()
        ctl = studio_style.dark_ctl()
        hi = studio_style.dark_ctl_hi()
        fg = studio_style.dark_fg()
        faint = studio_style.dark_dim()
        line = studio_style.dark_line()
        sel = studio_style.dark_sel()
        l = []

        ' NO BARE `QWidget` RULE, and that was the whole defect. Styling every
        ' widget at once darkened two surfaces whose CONTENT Qt paints from the
        ' palette rather than from the sheet -- so the content kept its
        ' light-theme colours and became invisible. Measured: the tree was
        ' still 256x216 with `▸ docs` at row 2, the toolbar still 39 high with
        ' all five icons present and visible. Nothing had gone; it was being
        ' drawn in dark-on-dark. So each container is named, and the two that
        ' cannot be reached this way are left to the platform.
        l = append(l, "QMainWindow { background: " + bg + "; }")
        l = append(l, "QMainWindow::separator { background: " + line + "; width: 4px; height: 4px; }")
        l = append(l, "QDialog { background: " + bg + "; }")
        l = append(l, "QLabel { color: " + fg + "; background: transparent; }")

        ' Text surfaces sit DARKER than the chrome, which is what `dark_base`
        ' is for -- the same relationship the GTK sheet gives them.
        l = append(l, "QPlainTextEdit, QTextEdit, QLineEdit {")
        l = append(l, "  background: " + base + "; color: " + fg + ";")
        l = append(l, "  border: 1px solid " + line + "; selection-background-color: " + sel + ";")
        l = append(l, "  selection-color: #ffffff; }")

        ' THE TREE AND THE TABLE, with their ITEM COLOUR SAID OUT LOUD. A
        ' `color` on the view is not what paints a row: the delegate draws item
        ' text, and on a dark background an unstated item colour is the thing
        ' that disappeared. `::item` carries it, and `::branch` is left alone --
        ' Studio draws its own expander glyphs and `itemsExpandable` is off, so
        ' there is nothing of Qt's there to colour.
        l = append(l, "QTreeView, QTableView, QListView {")
        l = append(l, "  background: " + base + "; color: " + fg + ";")
        l = append(l, "  border: 1px solid " + line + "; outline: 0;")
        l = append(l, "  selection-background-color: " + sel + "; selection-color: #ffffff; }")
        l = append(l, "QTreeView::item, QTableView::item, QListView::item {")
        l = append(l, "  color: " + fg + "; background: transparent; padding: 2px; }")
        l = append(l, "QTreeView::item:selected, QTableView::item:selected, QListView::item:selected {")
        l = append(l, "  background: " + sel + "; color: #ffffff; }")
        l = append(l, "QTreeView::item:hover, QTableView::item:hover, QListView::item:hover {")
        l = append(l, "  background: " + hi + "; color: " + fg + "; }")
        l = append(l, "QHeaderView { background: " + ctl + "; }")
        l = append(l, "QHeaderView::section { background: " + ctl + "; color: " + fg + ";")
        l = append(l, "  padding: 4px; border: 0px; border-bottom: 1px solid " + line + "; }")

        ' THE MENUS, which are the toolkit's own now and so need naming here.
        ' A menu's text is the sheet's to colour, which is why these are safe
        ' where the toolbar is not.
        l = append(l, "QMenuBar { background: " + bg + "; color: " + fg + "; border-bottom: 1px solid " + line + "; }")
        l = append(l, "QMenuBar::item { background: transparent; color: " + fg + "; padding: 4px 8px; }")
        l = append(l, "QMenuBar::item:selected { background: " + hi + "; }")
        l = append(l, "QMenu { background: " + ctl + "; color: " + fg + "; border: 1px solid " + line + "; }")
        l = append(l, "QMenu::item { color: " + fg + "; padding: 4px 24px 4px 24px; }")
        l = append(l, "QMenu::item:selected { background: " + sel + "; color: #ffffff; }")
        l = append(l, "QMenu::item:disabled { color: " + faint + "; }")
        l = append(l, "QMenu::separator { height: 1px; background: " + line + "; margin: 4px 8px; }")

        ' THE TOOLBAR IS DELIBERATELY NOT DARKENED, and that is the honest cost
        ' of having no palette. Its buttons carry `SP_` STANDARD PIXMAPS, which
        ' Qt's own style generates from the palette -- this machine has no icon
        ' theme at all, so there is no themed file to recolour -- and a sheet
        ' cannot reach them. Darkening the strip under them made five icons
        ' vanish. Left alone it is a lighter band in a dark window, which is
        ' visibly imperfect and is a thing you can still use. The real fix is a
        ' palette verb, asked for upstream.
        l = append(l, "QStatusBar { background: " + bg + "; color: " + faint + "; border-top: 1px solid " + line + "; }")
        l = append(l, "QStatusBar QLabel { color: " + fg + "; }")

        ' The docks. Their title bar is the one piece of chrome a person drags,
        ' so it reads as a handle rather than as more background. The close and
        ' float buttons are the style's own pixmaps, so they are NOT hidden and
        ' NOT recoloured -- same reason as the toolbar.
        l = append(l, "QDockWidget { color: " + fg + "; }")
        l = append(l, "QDockWidget::title { background: " + ctl + "; color: " + fg + ";")
        l = append(l, "  padding: 4px 6px; border-bottom: 1px solid " + line + "; }")

        ' The notebook. A selected tab is lifted to the EDITOR's own base, so
        ' the page and its tab read as one surface.
        l = append(l, "QTabWidget::pane { border: 1px solid " + line + "; background: " + bg + "; }")
        l = append(l, "QTabBar { background: " + bg + "; }")
        l = append(l, "QTabBar::tab { background: " + ctl + "; color: " + faint + ";")
        l = append(l, "  padding: 5px 10px; border: 1px solid " + line + "; border-bottom: 0px; }")
        l = append(l, "QTabBar::tab:selected { background: " + base + "; color: " + fg + "; }")
        l = append(l, "QTabBar::tab:hover { background: " + hi + "; color: " + fg + "; }")

        ' Controls whose text the sheet owns.
        l = append(l, "QPushButton { background: " + ctl + "; color: " + fg + ";")
        l = append(l, "  border: 1px solid " + line + "; padding: 4px 12px; border-radius: 3px; }")
        l = append(l, "QPushButton:hover { background: " + hi + "; }")
        l = append(l, "QPushButton:pressed { background: " + sel + "; color: #ffffff; }")
        l = append(l, "QPushButton:disabled { color: " + faint + "; }")
        l = append(l, "QCheckBox, QRadioButton { color: " + fg + "; background: transparent; }")
        l = append(l, "QGroupBox { color: " + fg + "; border: 1px solid " + line + "; margin-top: 8px; padding-top: 6px; }")
        l = append(l, "QGroupBox::title { color: " + fg + "; subcontrol-origin: margin; left: 8px; padding: 0px 4px; }")
        l = append(l, "QSplitter::handle { background: " + line + "; }")
        l = append(l, "QToolTip { background: " + ctl + "; color: " + fg + "; border: 1px solid " + line + "; }")
        l = append(l, "QScrollArea { background: " + bg + "; border: 0px; }")

        ' A `QComboBox`'s drop-down ARROW is a style pixmap like the toolbar's
        ' icons, so the closed box is left near the platform's lightness and
        ' only its popup list is darkened -- the list is item text, which the
        ' sheet does own.
        l = append(l, "QComboBox QAbstractItemView { background: " + ctl + "; color: " + fg + ";")
        l = append(l, "  selection-background-color: " + sel + "; selection-color: #ffffff; }")

        ' The scrollbars, which are the clearest sign a window was half-themed.
        l = append(l, "QScrollBar:vertical { background: " + bg + "; width: 12px; margin: 0px; }")
        l = append(l, "QScrollBar:horizontal { background: " + bg + "; height: 12px; margin: 0px; }")
        l = append(l, "QScrollBar::handle { background: " + hi + "; border-radius: 4px; min-height: 24px; min-width: 24px; }")
        l = append(l, "QScrollBar::handle:hover { background: " + faint + "; }")
        l = append(l, "QScrollBar::add-line, QScrollBar::sub-line { height: 0px; width: 0px; }")
        l = append(l, "QScrollBar::add-page, QScrollBar::sub-page { background: transparent; }")

        return join(l, "\n")
    end function

end library
