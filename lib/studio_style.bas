' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

'' studio_style.bas — how the window looks, decided in one place.
'
' Toolkit-free: no `qt.` call and nothing that loads a toolkit, so the shell
' (which must stay callable with no Qt) can reach it. What is here:
'
'   * the SPACING UNIT, 6px -- every margin and padding is a multiple of it;
'   * the DARK PALETTE (`dark_bg`, `dark_fg`, ...), the one set of colours
'     Studio owns, rendered as a Qt style sheet by `dark_qss`;
'   * the decisions that FOLLOW THE THEME -- which editor theme a `source` is
'     built with, the toolbar's button style, which icon a toolbar entry wears
'     -- and the editor's text size as a `font` property string.
'
' The GTK half -- CSS providers, GtkSourceView schemes, a GtkTextTag tint --
' went with the GTK window. A style sheet does not move Qt's PALETTE, which is
' why `dark_qss` names every container it darkens rather than writing a bare
' `QWidget` rule; see CLAUDE.md, "A STYLESHEET CANNOT REACH WHAT THE PALETTE
' PAINTS".
library studio_style

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
    ' `dark_qss` is their Qt rendering.

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

    ' THE EDITOR'S TEXT SIZE UNDER Qt (STU-20), as a `font` property string.
    '
    ' A Qt font reads back as `QFont::toString` -- "Hack,10,-1,7,400,..." --
    ' so the size is field 1 of a comma list, and gBASIC's own cookbook zooms
    ' exactly this way. `base` is the font a FRESH editor came with, which is
    ' the desktop's fixed-width font at the desktop's size: the zoom stays a
    ' multiplier on what the user chose system-wide, the argument STU-20 made
    ' for `font-size: <n>em` under GTK. Every other field is kept, so the
    ' family and its fixed-pitch hint survive.
    '
    ' Rounded to a tenth: 10 * 1.15 is 11.499999999999998 in binary, and a
    ' size compared against its own readback must not differ in the last bit.
    function qt_zoomed_size(base, zoom)
        f = split(base, ",")
        return round(number(f[1]) * zoom * 10) / 10
    end function

    function qt_font_sized(base, size)
        f = split(base, ",")
        f[1] = string(size)
        return join(f, ",")
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
    ' `qt.set(win, part, "icon", path)` answers true and `qt.has_icon` stays
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
        return out
    end function

    ' Where the shipped icons are, or "" when there is no share directory --
    ' the same `GBASIC_STUDIO_SHARE` the licences and templates are found
    ' through, exported by `./studio` and by the test runner.
    function toolbar_icon_dir()
        v = env("GBASIC_STUDIO_SHARE")
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
    ' restores the icons rather than leaving Studio's own on a light strip.
    function toolbar_icon(part, theme)
        for each e in studio_style.toolbar_icons()
            if e.part = part then
                if studio_style.qt_dark_for(theme) then
                    if studio_style.dark_icons_available() then
                        return studio_style.toolbar_icon_dir() + "/" + e.file + ".svg"
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
    ' The enum goes in as a NUMBER through the by-name route -- measured, a
    ' `qt.set` of 2 reads back `ToolButtonTextBesideIcon`.
    function qt_tool_button_style(theme)
        ' Icons both ways WHEN Studio's dark set is on disk; labels only when
        ' it is not, because a dark strip of invisible icons is the defect this
        ' whole arrangement exists to remove and a row of words is not.
        if studio_style.qt_dark_for(theme) then
            if studio_style.dark_icons_available() then
                return 0
            end if
            return 1
        end if
        return 0
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
        ' A LAYOUT `separator` is a QFrame line, drawn from the palette's LIGHT
        ' colour -- a bright white rule across a dark console, seen in a capture.
        ' frameShape 4 is HLine and 5 is VLine.
        l = append(l, "QFrame[frameShape=\"4\"] { border: none; background: " + line + "; max-height: 1px; min-height: 1px; }")
        l = append(l, "QFrame[frameShape=\"5\"] { border: none; background: " + line + "; max-width: 1px; min-width: 1px; }")
        l = append(l, "QDialog { background: " + bg + "; }")
        ' A SECOND WINDOW IS A PLAIN `QWidget` -- the grid, New Project, the
        ' snippets, the schema -- so neither rule above reaches it, and a
        ' capture showed the grid's caption as light text on a light window.
        ' `.QWidget` matches that exact class and NO subclass, so it is not the
        ' bare-`QWidget` trap: a view, a toolbar or a combo box is a subclass.
        ' An item view's VIEWPORT is a plain QWidget too, so it is given back
        ' to the view, whose own background rule paints it.
        l = append(l, ".QWidget { background: " + bg + "; }")
        l = append(l, "QAbstractScrollArea > .QWidget { background: transparent; }")
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
        l = append(l, "  border: 1px solid " + line + "; outline: 0; gridline-color: " + line + ";")
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
        ' The grid's top-left corner is a button of its own, white until named.
        l = append(l, "QTableCornerButton::section { background: " + ctl + "; border: 0px; border-bottom: 1px solid " + line + "; }")

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

        ' THE TOOLBAR IS DARK AGAIN, and it is only safe because its buttons
        ' show TEXT while dark -- see `qt_tool_button_style`. A label is the
        ' sheet's to colour where a style-generated pixmap is not, so this rule
        ' and that one are a pair: darkening the strip without switching to
        ' text is what made five icons invisible.
        l = append(l, "QToolBar { background: " + bg + "; border: 0px; spacing: 2px; padding: 2px; }")
        l = append(l, "QToolBar::separator { background: " + line + "; width: 1px; margin: 4px 4px; }")
        l = append(l, "QToolButton { background: transparent; color: " + fg + ";")
        l = append(l, "  border: 1px solid transparent; padding: 4px 8px; border-radius: 3px; }")
        l = append(l, "QToolButton:hover { background: " + hi + "; border: 1px solid " + line + "; }")
        l = append(l, "QToolButton:pressed { background: " + sel + "; color: #ffffff; }")
        l = append(l, "QToolButton:disabled { color: " + faint + "; }")
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
        ' UNLESS STUDIO SHIPS ITS OWN ARROW, which it does
        ' (`share/icons/controls/down.svg`): then the closed box is dark too, and
        ' a white box in every second window -- the brightest thing on screen --
        ' is gone. No file, no rule, and the platform's box stands.
        arrow = studio_style.control_icon("down")
        if arrow != "" then
            l = append(l, "QComboBox { background: " + ctl + "; color: " + fg + ";")
            l = append(l, "  border: 1px solid " + line + "; border-radius: 3px; padding: 3px 8px; }")
            l = append(l, "QComboBox:hover { background: " + hi + "; }")
            l = append(l, "QComboBox::drop-down { border: 0px; width: 22px; }")
            l = append(l, "QComboBox::down-arrow { image: url(" + arrow + "); width: 12px; height: 12px; }")
        end if
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
