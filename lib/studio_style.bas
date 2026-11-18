' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

'' studio_style.bas — how the window looks, decided in one place.
'
' Toolkit-free: no `ui.` call and nothing that loads a toolkit, so the shell
' (which must stay callable with no Qt) can reach it. What is here:
'
'   * the SPACING UNIT, 6px -- every margin and padding is a multiple of it;
'   * the DARK PALETTE (`dark_bg`, `dark_fg`, ...), the one set of colours
'     Studio owns, gathered as the theme record `ui.theme` takes;
'   * the decisions that FOLLOW THE THEME -- which editor theme a `source` is
'     built with, the toolbar's button style, which icon a toolbar entry wears
'     -- and the editor's text size in points.
'
' The GTK half -- CSS providers, GtkSourceView schemes, a GtkTextTag tint --
' went with the GTK window. So did Studio's Qt style sheet (2026-11-16):
' gBASIC renders the theme record itself now and sets Qt's palette too, which
' a sheet never could (CLAUDE.md, "A STYLESHEET CANNOT REACH WHAT THE PALETTE
' PAINTS", is the history).
library studio_style
    load studio_paths

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

    ' ---- the dark palette (STU-19) ------------------------------------------
    '
    ' Studio OWNS one look -- dark -- and otherwise defers to the platform. The
    ' colours were chosen by eye under GTK and carried across to Qt unchanged;
    ' `dark_palette` gathers them into the theme record.

    ' The palette, named once each. Literals, unavoidably -- a dark sheet IS a
    ' set of colours, and there is no token to defer to when the whole point is
    ' that the theme has none that suit.
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

    ' The dark palette as ONE record, which is what `sheet` renders. The
    ' functions above stay the names the rest of Studio (and a tier) reads a
    ' colour by; this is them gathered, not a second copy.
    function dark_palette()
        return { bg: studio_style.dark_bg(), base: studio_style.dark_base(),
                 ctl: studio_style.dark_ctl(), hi: studio_style.dark_ctl_hi(),
                 fg: studio_style.dark_fg(), faint: studio_style.dark_dim(),
                 line: studio_style.dark_line(), sel: studio_style.dark_sel(),
                 on_sel: "#ffffff",
                 arrow: studio_style.control_icon("down"),
                 tick: studio_style.control_icon("check"),
                 dock_close: "", dock_float: "" }
    end function

    ' ---- the PRINT palette, for book figures ---------------------------------
    '
    ' A figure in a paperback is printed in black ink, so this theme is made of
    ' GRAYS ONLY: converting it to grayscale changes nothing, and what a reader
    ' sees on paper is what the figure showed. It is light because a page is,
    ' and it is a FIGURE theme -- `./studio shoot`'s `frame` can ask for it,
    ' the Settings menu does not offer it (`studio_ui.figure_themes`).
    '
    ' The selection is a mid-light gray with BLACK text rather than a colour
    ' with white text: a blue selection is about 45% gray in print, and white
    ' text on it is the least legible thing on the page.
    '
    ' The EDITOR has a print theme of Studio's own (`print_editor_theme`):
    ' pure grays, told apart by weight, italics and shade. See `editor_theme`.
    function print_palette()
        return { bg: "#f0f0f0", base: "#ffffff", ctl: "#e2e2e2", hi: "#d4d4d4",
                 fg: "#111111", faint: "#666666", line: "#a8a8a8",
                 sel: "#c4c4c4", on_sel: "#000000",
                 arrow: studio_style.control_icon("down-light"),
                 tick: studio_style.control_icon("check-light"),
                 dock_close: studio_style.control_icon("close-light"),
                 dock_float: studio_style.control_icon("float-light") }
    end function

    ' ======================================================================
    ' STU-22 -- THE SAME DARK, AS A QT STYLE SHEET.
    '
    ' `ui.theme(sheet)` takes ONE sheet for the whole application, which is the
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
    ' The GTK window asked the toolkit three questions (the theme name, the
    ' prefer-dark setting, GTK_THEME), none of which alone carried the answer.
    ' Qt offers Studio NO equivalent: gBASIC exposes no
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

    ' The print editor's syntax theme: Studio's own, all grays --
    ' share/org.kde.syntax-highlighting/themes/studio-print.theme, found because
    ' the launcher puts share/ on XDG_DATA_DIRS. KDE's own "Printing" was tried
    ' first and is not gray (its strings are red).
    function print_editor_theme()
        return "gBASIC Studio Print"
    end function

    ' The theme an editor is BUILT with. `qt_source_theme`'s dark or light,
    ' except under the print theme when the entry point found the print theme
    ' usable (`app.qt_print_theme_ok`): `theme:` takes a theme NAME only since
    ' gBASIC ad1cb9dc, and the file has to be on the path. An
    ' editor that cannot have it is Breeze Light, which is what it was before.
    function editor_theme(app)
        t = app.model.settings["theme"]
        if is_string(t) then
            if t = "print" then
                if default(app["qt_print_theme_ok"], false) = true then
                    return studio_style.print_editor_theme()
                end if
            end if
        end if
        return studio_style.qt_source_theme(t)
    end function

    ' What `ui.theme` is given under `theme`: Studio's dark palette, the print
    ' palette, or "" -- no theme of Studio's, the platform's look ("Follow the
    ' desktop"); an empty text clears a record too.
    '
    ' THE RECORD IS gBASIC's NOW (ui_design.md §7, push A, 2026-11-16): gBASIC
    ' adopted this very record as its theme, renders the rules `sheet(p)` used
    ' to render here -- ported verbatim, the `.QWidget` and indicator lessons
    ' included -- AND sets Qt's palette, which a stylesheet never could, so
    ' what Qt paints from the palette follows the theme too. Studio no longer
    ' writes a line of QSS.
    function qt_theme_for(theme)
        if studio_style.qt_dark_for(theme) then
            return studio_style.dark_palette()
        end if
        if theme = "print" then
            return studio_style.print_palette()
        end if
        return ""
    end function

    ' THE EDITOR'S TEXT SIZE (STU-20): `base` points times the zoom.
    '
    ' `base` is the `font_size` a FRESH editor came with, which is the
    ' desktop's fixed-width font at the desktop's size: the zoom stays a
    ' multiplier on what the user chose system-wide, the argument STU-20 made
    ' for `font-size: <n>em` under GTK. (Under `qt.` this was field 1 of a
    ' `QFont::toString` list; `font_size` is a number, and fractional.)
    '
    ' Rounded to a tenth: 10 * 1.15 is 11.499999999999998 in binary, and a
    ' size compared against its own readback must not differ in the last bit.
    function qt_zoomed_size(base, zoom)
        return round(base * zoom * 10) / 10
    end function

    ' THE TOOLBAR SHOWS TEXT WHILE DARK, AND ICONS OTHERWISE.
    '
    ' Not a preference -- the icons are `SP_` standard pixmaps that Qt's own
    ' style generates from the palette, and `qt.theme` does not move the
    ' palette, so on a dark strip they are dark glyphs on dark. Measured:
    ' darkening the toolbar made all five vanish while `qt.has_icon` went on
    ' answering true for every one of them.
    '
    ' A LABEL IS THE SHEET'S TO COLOUR, so text is the one treatment that is
    ' legible without a palette -- and every toolbar item already carries a
    ' `label`, which is what a tooltip and the teaching registry use. The
    ' alternative was leaving the strip at the platform's lightness, which
    ' works and puts a pale band under the menus in a dark window; the user
    ' chose text. Under "Follow the desktop" there is no sheet, the palette is
    ' the platform's, and the icons are right again.
    '
    ' ===================================================================
    ' THE TOOLBAR'S ICONS, which Studio ships for the dark theme.
    '
    ' The declared icons are `SP_` STANDARD PIXMAPS -- Qt's own 81, the only
    ' source that works with no desktop icon theme installed, which this
    ' machine does not have. Qt's style draws them FROM THE PALETTE, and
    ' `qt.theme` does not move the palette, so on a dark strip they were dark
    ' glyphs on dark: measured invisible while `qt.has_icon` answered true for
    ' every one of them.
    '
    ' So the dark theme gets files Studio ships, in a light stroke -- and
    ' `icon:` takes a path as readily as an `SP_` name ("a string that names an
    ' existing file is that file"). Measured settable AT RUN TIME:
    ' `ui.set(win, part, "icon", path)` answers true and `qt.has_icon` stays
    ' true, which is what lets the toolbar follow a theme change rather than
    ' wait for a relaunch -- a `toolbar` is NOT a container `qt.refresh` will
    ' rebuild.
    '
    ' THEY ARE SVG, and that is worth the sentence. Measured: a valid SVG sets
    ' and reads back as an icon, and a MALFORMED one is refused by name with
    ' Qt's own parser error on stderr -- so the file is really parsed rather
    ' than trusted by its extension. The gain over the PNGs these replaced is
    ' HiDPI: `libqsvgicon.so` re-renders at whatever size is asked for, where
    ' one 24px bitmap is resampled and soft at 200%. The second gain is that an
    ' SVG IS ITS OWN PROVENANCE -- it is text, it diffs, and you can read what
    ' the shape is without running a generator, which is the same argument that
    ' keeps this project's templates declarative.
    '
    ' A MISSING FILE IS REFUSED BY `qt.set`, not warned about, so this checks
    ' before offering a path. AND SO IS A FILE QT CANNOT READ, which a build
    ' without Qt's SVG plugin would make of every one of these -- that one
    ' cannot be answered by looking at the filesystem, so the caller catches it
    ' and falls back to labels. See `app/studio.bas`'s `qt_apply_toolbar`:
    ' the guard lives in the entry point because a RENDERER MUST NOT CATCH.
    ' ===================================================================
    function toolbar_icons()
        out = []
        out = append(out, { part: "save", sp: "SP_DialogSaveButton", file: "save" })
        out = append(out, { part: "tb_reload", sp: "SP_BrowserReload", file: "reload" })
        out = append(out, { part: "tb_open_folder", sp: "SP_DialogOpenButton", file: "open-folder" })
        out = append(out, { part: "tb_new_file", sp: "SP_FileIcon", file: "new-file" })
        out = append(out, { part: "tb_new_folder", sp: "SP_FileDialogNewFolder", file: "new-folder" })
        ' No standard pixmap is a pilcrow, so `sp` is "" and the light theme
        ' gets Studio's own dark-stroked copy (`<file>-light.svg`) instead.
        out = append(out, { part: "tb_whitespace", sp: "", file: "whitespace" })
        return out
    end function

    ' Where the shipped icons are, or "" when there is no share directory --
    ' the same `GBASIC_STUDIO_SHARE` the licences and templates are found
    ' through, exported by `./studio` and by the test runner.
    function toolbar_icon_dir()
        v = studio_paths.from_os(env("GBASIC_STUDIO_SHARE"))
        if is_string(v) then
            if v != "" then
                return v + "/icons/toolbar"
            end if
        end if
        return ""
    end function

    ' Whether the dark set is actually on disk. Checked on the ONE icon that
    ' stands for the set rather than on all five: they are written by a single
    ' script in a single commit, and five `exists` calls per redraw to answer
    ' the same question is work for nothing.
    ' A control's own art for the dark sheet, by name, or "" when the file is
    ' not there -- the sheet then leaves that control to the platform.
    function control_icon(name)
        d = studio_style.toolbar_icon_dir()
        if d = "" then
            return ""
        end if
        p = replace(d, "/icons/toolbar", "/icons/controls") + "/" + name + ".svg"
        if exists({file} p) then
            return p
        end if
        return ""
    end function

    function dark_icons_available()
        d = studio_style.toolbar_icon_dir()
        if d = "" then
            return false
        end if
        p = d + "/save.svg"
        return exists({file} p)
    end function

    ' The icon string to put on one toolbar item under `theme`, or "" for
    ' "leave it alone". Light is the declared `SP_` name, so a switch BACK
    ' restores the icons rather than leaving Studio's own on a light strip --
    ' unless `named` is false: a backend without gBASIC's `icons` group cannot
    ' take a NAME at all, so light wears Studio's own dark-stroked files too.
    function toolbar_icon(part, theme, named)
        for each e in studio_style.toolbar_icons()
            if e.part = part then
                if not named and theme != "print" and not studio_style.qt_dark_for(theme) then
                    light = studio_style.toolbar_icon_dir() + "/" + e.file + "-light.svg"
                    if studio_style.toolbar_icon_dir() != "" then
                        if exists({file} light) then
                            return light
                        end if
                    end if
                    return ""
                end if
                ' PRINT WEARS STUDIO'S OWN ICONS, dark-stroked and gray only:
                ' an `SP_` pixmap is the platform style's, coloured, and a
                ' figure must not depend on which Qt drew it.
                if theme = "print" then
                    light = studio_style.toolbar_icon_dir() + "/" + e.file + "-light.svg"
                    if studio_style.toolbar_icon_dir() != "" then
                        if exists({file} light) then
                            return light
                        end if
                    end if
                    return e.sp
                end if
                if studio_style.qt_dark_for(theme) then
                    if studio_style.dark_icons_available() then
                        return studio_style.toolbar_icon_dir() + "/" + e.file + ".svg"
                    end if
                    return ""
                end if
                if e.sp = "" then
                    light = studio_style.toolbar_icon_dir() + "/" + e.file + "-light.svg"
                    if studio_style.toolbar_icon_dir() != "" then
                        if exists({file} light) then
                            return light
                        end if
                    end if
                    return ""
                end if
                return e.sp
            end if
        end for
        return ""
    end function

    ' THE ENUM, AND I GOT IT WRONG ONCE. `Qt::ToolButtonStyle` is IconOnly 0,
    ' TextOnly 1, TextBesideIcon 2, TextUnderIcon 3, FollowStyle 4 -- so
    ' TextOnly is ONE. Writing 3 produced `ToolButtonTextUnderIcon`, which puts
    ' each label under the blank where its invisible icon is and makes the
    ' strip taller for nothing. Caught by reading the property back in the
    ' tier, which is the only reason it did not ship: the window would have
    ' looked merely odd rather than broken.
    '
    ' It is gBASIC's `toolbar_shows` word: "icons" or "text". (Under `qt.` it
    ' was Qt's enum as a number, and 3 once read back as text UNDER icons.)
    function qt_tool_button_style(theme)
        ' Icons both ways WHEN Studio's dark set is on disk; labels only when
        ' it is not, because a dark strip of invisible icons is the defect this
        ' whole arrangement exists to remove and a row of words is not.
        if studio_style.qt_dark_for(theme) then
            if studio_style.dark_icons_available() then
                return "icons"
            end if
            return "text"
        end if
        return "icons"
    end function

end library
