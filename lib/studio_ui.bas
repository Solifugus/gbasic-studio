' studio_ui.bas — the INTENT layer between the GTK shell and the app model.
'
' STU-2B exists because the shell rendered but could not be driven: there were no
' signal handlers at all. Wiring them raises a testing problem, because a handler
' runs inside GTK's dispatch and the headless suite has no GTK. The answer this
' phase settles on is a split:
'
'   * A HANDLER is an ADAPTER. It extracts one plain value from the widget (a row
'     index, a page number, a buffer's text), calls exactly one function here, and
'     asks for a redraw. It contains no decisions and touches no model state.
'   * EVERY decision lives in this library, as an ordinary function over plain
'     data that a headless test calls directly.
'
' The point is not that handlers are tidy. It is that what a handler still does
' after the split is too small to hide a bug in, so the untestable surface shrinks
' to the widget-to-value extraction itself — which the display tier then covers by
' synthesising real GTK signals (see tests/run_studio.sh, ui_gui).
'
' Every function here takes the app record and plain values, returns a record
' whose `app` field is the updated app, and NEVER touches gi/GTK. This file must
' stay loadable with no display and no typelib.
'
' The row model is the load-bearing part. `nav_rows` produces the browser's rows
' ONCE, and both the renderer and `activate_row` consume that same array — the
' renderer to build one widget per row, the dispatcher to decide what row N means.
' A second, independently-derived row list would drift the moment the filesystem
' changed between a render and a click, and the user would activate a row they
' never saw. Rendering and dispatch read the same array or this is not safe.
library studio_ui


    ' Dependencies, declared rather than assumed. A library that calls into
    ' another must load it: relying on the caller to have done so turns a
    ' missing load into a runtime failure deep inside a call, and it stops
    ' working entirely once these libraries live in separate projects.
    load filetree
    load persist
    load studio_model
    load studio_docs
    load studio
    load studio_sections
    load studio_session
    load studio_results
    load studio_projects
    load studio_projfile
    load studio_branches
    load studio_overlays
    load studio_viewers
    load studio_table
    load studio_git

    ' Entries the browser does not show.
    '
    ' `.git` is the one that matters and it is not merely noise: it is a
    ' directory of thousands of files that a user can EXPAND, and filetree scans
    ' an expanded directory eagerly. One curious click on a real repository would
    ' have walked every loose object in it.
    '
    ' Dotfiles generally are hidden for the ordinary reason — `.gbasic/` is
    ' Studio's own metadata (§2.2 says unobtrusive) and a project browser that
    ' leads with four dot-directories is showing plumbing before content.
    ' One deliberate exception: `.gstudio.json`. It is the only file in this
    ' directory Studio ever writes, it is written only because somebody asked
    ' for it, and hiding a file you consented to is how it becomes the
    ' uninvited metadata the whole design is avoiding. It is also hand-edited,
    ' which a browser that will not show it makes needlessly awkward.
    function hidden_entry(name)
        if name = studio_projfile.filename() then
            return false
        end if
        return left(name, 1) = "."
    end function

    ' ---- a project's own state file -----------------------------------------
    '
    ' Section anchors, the branch tree and the overlays live in
    ' `<home>/state/<key>.json`, one file per project, instead of all together
    ' in the session record. Cached on `app.pstate` and flushed by
    ' `studio.persist`, which is the same in-memory-until-exit behaviour they
    ' had inside the workspace — only the file they land in changed. It is NOT
    ' written on every mutation: the section fold runs at cursor-move rate.

    ' Which project a document belongs to, by path prefix, LONGEST match first
    ' so a project nested inside another wins. "" when the document is under no
    ' project at all, which is a real case — a file can be opened by path with
    ' no project adopted — and its state then lives in memory only.
    function project_path_for(app, doc)
        if doc = nothing then
            return ""
        end if
        ws = app.model.workspace
        if ws = nothing then
            return ""
        end if
        ' `_under` already exists here and already refuses "/a/srcery" as a
        ' child of "/a/src" — the separator is part of the test.
        best = ""
        for each pr in ws.projects
            if studio_ui._under(doc.path, pr.path) then
                if len(pr.path) > len(best) then
                    best = pr.path
                end if
            end if
        end for
        return best
    end function

    ' The active document's project state, loading it on first use and swapping
    ' it when the caret moves to a document in another project. The outgoing
    ' state is WRITTEN on the way out: a project switch is exactly when its
    ' anchors would otherwise be dropped on the floor.
    function project_state(app)
        doc = studio_docs.active_doc(app.dm)
        want = studio_ui.project_path_for(app, doc)
        held = app["pstate"]
        if held != unknown then
            if held != nothing then
                if held.path = want then
                    return { app: app, state: held.state, path: want, key: held.key }
                end if
                if held.key != "" then
                    saved = studio_projects.save(app.paths.home, held.key, held.state)
                end if
            end if
        end if
        ' Identity is resolved HERE and nowhere else: this is the one place
        ' holding both the path and the project's own file. `studio_projects`
        ' takes a key from here on and never learns what a directory is.
        key = studio_projects.key_for(want, studio_ui.project_id(want))
        st = studio_projects.open(app.paths.home, key)
        app["pstate"] = { path: want, key: key, state: st }
        return { app: app, state: st, path: want, key: key }
    end function

    ' A project's stable id, or "" — read straight off `.gstudio.json`.
    '
    ' NOT cached. The read is one small file and it happens on a project switch,
    ' which is a click; `nav_rows` already stats a whole directory tree on every
    ' redraw, so a cache here would buy nothing measurable and cost the thing
    ' that matters — hand-editing `.gstudio.json` takes effect on the next
    ' redraw, with no invalidation rule to get wrong.
    function project_id(project_path)
        if project_path = "" then
            return ""
        end if
        return studio_projfile.read_spec(project_path).id
    end function

    ' Put a mutated state back on the app. In memory only; `studio.persist`
    ' writes it, and so does a project switch above.
    function set_project_state(app, state)
        held = app["pstate"]
        pth = ""
        key = ""
        if held != unknown then
            if held != nothing then
                pth = held.path
                key = held.key
            end if
        end if
        app["pstate"] = { path: pth, key: key, state: state }
        return app
    end function

    ' ---- how PERSISTED per-document state is keyed --------------------------
    '
    ' By PATH, not by the minted `doc-N` id.
    '
    ' A document id is a live-session handle: closing a tab throws it away, and
    ' reopening the same file mints the next one. Anything persisted under it is
    ' therefore unreachable after a close — and worse than unreachable. Section
    ' ids are deliberately NOT in file order (STU-3 re-matches them across edits,
    ' so an inserted function keeps the ids below it), while a state derived
    ' fresh numbers them in file order. Measured: a file whose sections were
    ' sec-4, sec-3, sec-1, sec-2 came back as sec-1, sec-2, sec-3, sec-4 — so
    ' every result filed against sec-4 now names a DIFFERENT function, and the
    ' results pane shows it confidently. Silent misattribution is worse than
    ' loss.
    '
    ' `studio_sections` and `studio_branches` never interpret this value; they
    ' only compare it. So the fix is entirely in what gets handed to them.
    function doc_key(doc)
        if doc = nothing then
            return ""
        end if
        return doc.path
    end function

    ' ---- what KIND of file is open ------------------------------------------
    '
    ' Studio opens anything — a README, a Makefile, a JSON fixture beside the
    ' code are all part of a project — but only gBASIC has sections, an outline,
    ' diagnostics or a Run button. Every document used to be handed to
    ' `source_outline` regardless, so opening README.md answered "this file does
    ' not parse — error 1:1 unexpected token" about a file that is not supposed
    ' to parse, and the gutter marked line 1. A pane asserting that a markdown
    ' document is broken gBASIC is worse than a pane saying nothing.
    '
    ' The suffixes are the `globs` of `gbasic.lang` (`*.bas;*.gb`), which is the
    ' file the EDITOR highlights from — so "is this gBASIC" has one answer here
    ' and not two that can drift apart.
    function gbasic_suffixes()
        return [".bas", ".gb"]
    end function

    ' Case-insensitively, because a file named README.BAS is still gBASIC and
    ' the only thing a case-sensitive check would change is whether Studio can
    ' run it.
    function is_gbasic(path)
        low = lower(path)
        for each ext in studio_ui.gbasic_suffixes()
            if ends_with(low, ext) then
                return true
            end if
        end for
        return false
    end function

    ' ---- the browser row model ---------------------------------------------

    ' The visible browser rows, in display order. Each row:
    '   { kind, label, path, project_id }
    ' kind is "info" (not actionable), "project", "dir" or "file" — the last two
    ' carried straight through from filetree so the tree and the dispatcher agree
    ' on what a row is by construction rather than by a parallel convention.
    '
    ' `label` is the exact text the renderer draws, so the label and the action can
    ' never describe different things.
    function nav_rows(app)
        rows = []
        ws = app.model.workspace
        if ws = nothing then
            rows = append(rows, studio_ui._row("info", "(no workspace open)", 0, "", "", ""))
            ' The empty state is exactly where someone finds out what this window
            ' can do, and it said only what it could NOT do. Both routes in are
            ' named here, because neither is guessable from a row of buttons and
            ' a field labelled "name".
            rows = append(rows, studio_ui._row("info", "New Project starts a fresh one", 0, "", "", ""))
            rows = append(rows, studio_ui._row("info", "or type a folder path and press Open Folder", 0, "", "", ""))
            return rows
        end if
        rows = append(rows, studio_ui._row("info", "Workspace: " + ws.name, 0, "", "", ""))
        for each pr in ws.projects
            ' A STATUS marker, not indentation: which project is active. It is
            ' the glyph rather than part of the name so the renderer can tell
            ' the two apart, and `row_label` puts them back together.
            marker = "  "
            if pr.id = ws.active_project then
                marker = "* "
            end if
            rows = append(rows, studio_ui._row("project", pr.name, 0, marker, pr.path, pr.id))
        end for
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return rows
        end if
        ' The project's own say about what is not worth showing. Read per
        ' redraw on purpose (see `project_id`): `filetree.scan` below walks the
        ' tree anyway, so one small file is inside the noise, and editing
        ' `.gstudio.json` then takes effect on the next redraw.
        spec = studio_projfile.read_spec(proj.path)
        nodes = filetree.scan(proj.path, ws.nav.expanded)
        for each r in filetree.flatten(nodes)
            if studio_ui.hidden_entry(r.name) then
                continue
            end if
            if studio_projfile.ignored(spec, r.name) then
                continue
            end if
            glyph = "  "
            if r.kind = "dir" then
                if r.expanded then
                    glyph = "v "
                else
                    glyph = "> "
                end if
            end if
            ' One deeper than `filetree` counts, because everything in the tree
            ' sits under the project row above it.
            rows = append(rows, studio_ui._row(r.kind, r.name, r.depth + 1, glyph, r.path, proj.id))
        end for
        return rows
    end function

    ' A browser row: what it IS, in parts, plus the flat `label` the goldens and
    ' the status line read.
    '
    ' The parts are the point. Indentation used to be spaces inside `label`, so
    ' depth was encoded in a presentation string and the renderer had no choice
    ' but to draw it that way — in a PROPORTIONAL font, where two spaces are
    ' whatever the font says they are. The shell indents with a margin now and
    ' the label carries only the glyph and the name, which is also what lets the
    ' name ellipsize without the indentation ellipsizing with it.
    '
    ' `label` is still produced, here, once. It is what `tests/drivers/ui.bas`
    ' addresses rows by and what the display tiers print, and deriving it in one
    ' place is what keeps the two renderings from drifting — the mistake
    ' `projects[].documents` made was two independent records of one thing.
    function _row(kind, name, depth, glyph, path, project_id)
        return { kind: kind, name: name, depth: depth, glyph: glyph,
                 label: studio_ui.row_label(kind, name, depth, glyph),
                 path: path, project_id: project_id }
    end function

    ' The flat rendering: two spaces per level, then the glyph, then the name.
    function row_label(kind, name, depth, glyph)
        indent = ""
        i = 0
        while i < depth
            indent = indent + "  "
            i = i + 1
        end while
        return indent + glyph + name
    end function

    ' Activate the row at `index` of the row array the view actually rendered.
    ' Returns { app, action, detail }, where action is one of:
    '   "out-of-range" — no such row (a stale index; the model is untouched)
    '   "none"         — an informational row; nothing to do
    '   "project"      — the project became active
    '   "expand"       — a directory was opened
    '   "collapse"     — a directory was closed
    '   "open"         — a file was opened into a document tab; detail is
    '                    "<status> <doc-id>" from the document manager
    '
    ' `rows` is passed in rather than recomputed so the action is decided against
    ' what the user saw, not against a filesystem that may have moved underneath.
    function activate_row(app, rows, index)
        if index < 0 then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        n = count(rows)
        if index >= n then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        row = rows[index]
        kind = row.kind

        if kind = "info" then
            return { app: app, action: "none", detail: "" }
        end if

        if kind = "project" then
            ws = app.model.workspace
            ws = studio_model.set_active_project(ws, row.project_id)
            app = studio.set_workspace(app, ws)
            return { app: app, action: "project", detail: row.project_id }
        end if

        if kind = "dir" then
            ws = app.model.workspace
            was_open = studio_model.is_expanded(ws, row.path)
            ws = studio_model.toggle_expanded(ws, row.path)
            ws = studio_model.set_selected_path(ws, row.path)
            app = studio.set_workspace(app, ws)
            act = "expand"
            if was_open then
                act = "collapse"
            end if
            return { app: app, action: act, detail: row.path }
        end if

        ' A file: select it in the browser, then open it into a tab. Opening is
        ' the document manager's business — reuse of an already-open path, the
        ' missing-file case and the directory case are all decided there.
        ws = app.model.workspace
        ws = studio_model.set_selected_path(ws, row.path)
        app = studio.set_workspace(app, ws)
        opened = studio.open_from_browser(app, row.project_id, row.path)
        return { app: opened.app, action: "open", detail: opened.status + " " + opened.id }
    end function

    ' ---- the tab row model --------------------------------------------------

    ' The notebook's pages, in tab order: { doc_id, label }. The welcome page that
    ' stands in for an empty document set is NOT a row here — it carries no
    ' document, so it can never be selected into one.
    function tab_rows(app)
        rows = []
        for each d in app.dm.docs
            rows = append(rows, { doc_id: d.id, label: studio_ui.tab_label(d) })
        end for
        return rows
    end function

    ' A tab label with markers, most alarming first:
    '   "! "  the file is gone
    '   "~ "  the file CHANGED on disk while you had unsaved edits
    '   "* "  you have unsaved edits
    '
    ' The middle one used to render as "* " like any other unsaved buffer, which
    ' made a conflict indistinguishable from ordinary typing — and Save on a
    ' conflicted document overwrites whatever else wrote the file. A marker that
    ' cannot tell you that is worse than no marker.
    function tab_label(doc)
        marker = ""
        if doc.missing then
            marker = "! "
        else
            if doc.external = "changed" then
                marker = "~ "
            else
                dirty = studio_docs.is_dirty(doc)
                if dirty then
                    marker = "* "
                end if
            end if
        end if
        return marker + doc.display_name
    end function

    ' Make the document behind page `index` the active one. Returns
    ' { app, action, detail } with action "select" or "out-of-range".
    function select_tab(app, rows, index)
        if index < 0 then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        n = count(rows)
        if index >= n then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        row = rows[index]
        app = studio.set_active_document(app, row.doc_id)
        return { app: app, action: "select", detail: row.doc_id }
    end function

    ' ---- editing ------------------------------------------------------------

    ' Push an editor buffer's text into its document. Dirty is DERIVED by the
    ' document manager from content-vs-saved, so re-applying identical text is a
    ' no-op and typing back to the saved text un-dirties the tab on its own.
    '
    ' An unknown id is ignored rather than raised: a buffer can outlive its
    ' document (a tab closed while its "changed" signal was in flight), and a
    ' crash is a worse answer than a dropped keystroke on a document that is gone.
    function apply_edit(app, doc_id, text)
        doc = studio_docs.doc_by_id(app.dm, doc_id)
        if doc = nothing then
            return { app: app, action: "unknown", detail: doc_id }
        end if
        app = studio.edit_document(app, doc_id, text)
        after = studio_docs.doc_by_id(app.dm, doc_id)
        dirty = studio_docs.is_dirty(after)
        act = "clean"
        if dirty then
            act = "dirty"
        end if
        return { app: app, action: act, detail: doc_id }
    end function

    ' Push every visible editor buffer into its document.
    '
    ' GtkTextBuffer's "changed" carries no indication of WHICH document is being
    ' typed into, and comparing GObject references for identity from gBASIC is not
    ' something this codebase relies on anywhere else. So the adapter hands over
    ' every open page's (doc_id, text) pair and this decides — which is correct no
    ' matter which buffer fired, and costs one string comparison per open tab
    ' because an unchanged document is a no-op inside the document manager.
    '
    ' `buffers` is [ { doc_id, text } ]. Returns { app, action, detail } where
    ' detail names the documents whose dirty state actually moved.
    ' `moved` tells the caller whether anything a full redraw would show actually
    ' changed. Typing fires this on every keystroke, and a full redraw rebuilds
    ' the browser pane — so the common case (text changed, dirty state did not)
    ' must not cost one.
    function sync_buffers(app, buffers)
        moved = []
        for each b in buffers
            doc = studio_docs.doc_by_id(app.dm, b.doc_id)
            if doc != nothing then
                before = studio_docs.is_dirty(doc)
                if doc.content != b.text then
                    app = studio.edit_document(app, b.doc_id, b.text)
                    after_doc = studio_docs.doc_by_id(app.dm, b.doc_id)
                    after = studio_docs.is_dirty(after_doc)
                    if before != after then
                        state = "clean"
                        if after then
                            state = "dirty"
                        end if
                        moved = append(moved, b.doc_id + "->" + state)
                    end if
                end if
            end if
        end for
        return { app: app, action: "synced", detail: join(moved, ","), moved: count(moved) > 0 }
    end function

    ' Save the active document. Returns { app, action, detail } with action
    ' "saved" | "error" | "unknown" | "none" (nothing open).
    ' Save the active document. `armed` is the document id a previous Save
    ' armed — the same two-click shape Delete and Close use, and here for the
    ' same reason: saving a document whose file changed underneath OVERWRITES
    ' whatever made that change, and doing it on one unremarkable click is how
    ' someone else's work disappears.
    '
    ' Only a conflict arms. An ordinary save is one click, because there is
    ' nothing at stake in it.
    '
    ' Returns { app, action, detail, armed } with action
    ' "saved" | "armed-save" | "error" | "unknown" | "none".
    function save_active(app, armed)
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "none", detail: "", armed: "" }
        end if
        if doc.external = "changed" then
            if armed != doc.id then
                return { app: app, action: "armed-save", detail: doc.id, armed: doc.id }
            end if
        end if
        sv = studio.save_document(app, doc.id)
        return { app: sv.app, action: sv.status, detail: doc.id, armed: "" }
    end function

    ' ---- workspace / project creation --------------------------------------

    ' The next project name and directory for a "New Project" with no dialog
    ' behind it: "Project N" under <home>/projects/, N being one past the count
    ' already in the workspace. Deterministic, so a test can assert it.
    function next_project_name(app)
        ws = app.model.workspace
        n = 1
        if ws != nothing then
            n = count(ws.projects) + 1
        end if
        return "Project " + n
    end function

    function project_dir(home, name)
        return home + "/projects/" + studio_ui._slug(name)
    end function

    ' Lower-case, spaces to hyphens, and drop anything that is not alphanumeric or
    ' a hyphen — so a display name becomes a directory name that cannot escape its
    ' parent or need quoting.
    function _slug(name)
        out = []
        lowered = lower(name)
        i = 0
        while i < len(lowered)
            ch = mid(lowered, i, 1)
            keep = ""
            if ch >= "a" then
                if ch <= "z" then
                    keep = ch
                end if
            end if
            if ch >= "0" then
                if ch <= "9" then
                    keep = ch
                end if
            end if
            if ch = "-" then
                keep = ch
            end if
            if ch = " " then
                keep = "-"
            end if
            if keep != "" then
                out = append(out, keep)
            end if
            i = i + 1
        end while
        joined = join(out, "")
        if joined = "" then
            return "project"
        end if
        return joined
    end function

    ' "New Project". This is the one action that has to work on a COLD home: with
    ' no workspace open the shell renders "(no workspace open)" and every other
    ' action is a no-op, so if this needed a workspace to already exist there
    ' would still be no way in. It therefore creates one when none is open.
    '
    ' The project directory is created on disk, because a project whose path does
    ' not exist scans to an empty browser and looks identical to a broken one.
    ' Returns { app, action, detail } with action "created" and detail
    ' "<project-id> <name>".
    function new_project(app, home)
        ws = app.model.workspace
        if ws = nothing then
            app = studio.create_registered_workspace(app, "workspace")
            ws = app.model.workspace
        end if
        name = studio_ui.next_project_name(app)
        dir = studio_ui.project_dir(home, name)
        persist.ensure_dir(dir)
        ws = studio_model.add_project(ws, name, dir)
        proj = studio_model.last_project(ws)
        ws = studio_model.set_active_project(ws, proj.id)
        app = studio.set_workspace(app, ws)
        return { app: app, action: "created", detail: proj.id + " " + name }
    end function

    ' ---- New Project, with options (STU-12) --------------------------------
    '
    ' `new_project` above is the one-click version and stays: it mints a name,
    ' makes a directory and opens it. What follows is the same act with the
    ' questions asked — a NAME you chose, somewhere you chose, and the four
    ' things a new project usually wants and sometimes does not.
    '
    ' Every default here is the minimal one. `main.bas` is ON because a project
    ' with no file in it dead-ends: an empty directory scans to zero browser
    ' rows and there is nothing to click. Everything else is OFF, including the
    ' project file — Studio putting `.gstudio.json` in a directory by default
    ' would be exactly the behaviour the file exists to avoid, and a box you
    ' had to untick is not consent.

    ' The options record the window starts from, and the shape `project_plan`
    ' consumes. Plain data, so the headless driver builds one directly.
    function default_options(app, home)
        return {
            name: studio_ui.next_project_name(app),
            location: home + "/projects",
            author: studio_ui.default_author(),
            main: true,
            projfile: false,
            readme: false,
            git: false,
            license: "none"
        }
    end function

    ' Who a licence would name. `git config user.name` is the one place on a
    ' developer's machine that holds a REAL name rather than a login, so it is
    ' asked first — through `studio_git`, which finds git with `process.which`
    ' and never by running it. `USER` is the fallback and is usually a login,
    ' which is why the field is editable and why a blank one refuses rather
    ' than being filled in with a guess.
    function default_author()
        avail = studio_git.available()
        if avail then
            ' `run` needs a directory that exists to work in, and refuses ""
            ' — this is a GLOBAL config read, so any real directory does. It
            ' is one process spawn when the window OPENS, not on a redraw.
            r = studio_git.run(studio_ui.home_dir(), ["config", "--get", "user.name"])
            if r.ok then
                nm = trim(r.out)
                if nm != "" then
                    return nm
                end if
            end if
        end if
        u = env("USER")
        if is_string(u) then
            return u
        end if
        return ""
    end function

    ' ---- licences -----------------------------------------------------------
    '
    ' Studio does not author a licence; it copies a file out of
    ' `share/licenses/` and substitutes the two SPDX placeholders in the two
    ' templates that carry them. See that directory's README for where each
    ' text came from.

    function license_ids()
        return ["none", "MIT", "Apache-2.0", "BSD-3-Clause", "GPL-3.0", "MPL-2.0"]
    end function

    ' The only two that name a copyright holder in the LICENSE file itself.
    ' The other three are copied verbatim and carry their notice elsewhere.
    function license_needs_holder(id)
        if id = "MIT" then
            return true
        end if
        return id = "BSD-3-Clause"
    end function

    ' Where the texts live. Exported by `./studio` the same way the viewer
    ' registry is, because an installed copy keeps `share/` somewhere else and
    ' Studio's own working directory is never the answer.
    function license_dir()
        v = env("GBASIC_STUDIO_SHARE")
        if is_string(v) then
            if v != "" then
                return v + "/licenses"
            end if
        end if
        return ""
    end function

    ' The text, with the placeholders filled, or "" when there is none to be
    ' had — no id, an id with no file, or a file that will not read. The caller
    ' REFUSES on "", rather than writing an empty LICENSE: a LICENSE file that
    ' is not the licence is worse than no LICENSE file at all.
    function license_text(id, year, holder)
        if id = "" then
            return ""
        end if
        if id = "none" then
            return ""
        end if
        dir = studio_ui.license_dir()
        if dir = "" then
            return ""
        end if
        path = dir + "/" + id + ".txt"
        probe{file} = path
        if not exists(probe) then
            return ""
        end if
        f{file} = path
        text = read(f)
        text = replace(text, "[year]", year)
        text = replace(text, "[fullname]", holder)
        return text
    end function

    ' The year a licence is granted in, from the same clock everything else
    ' reads. `from_epoch` renders "YYYY-MM-DD HH:MM:SS", so the year is its
    ' first four characters — and a pinned test clock gives a fixed one.
    function license_year(stamp)
        return left(string(from_epoch(stamp)), 4)
    end function

    ' ---- the plan -----------------------------------------------------------

    ' What a set of options MEANS, as the exact list of files to write.
    '
    ' Pure over plain data apart from reading the licence text, so the whole of
    ' "what does ticking that box do" is one function a test calls with a
    ' record and reads an answer from. Nothing is created here; a plan that
    ' refuses has touched nothing.
    '
    ' Returns { ok, reason, detail, path, name, files, git }, where `files` is
    ' [{ name, text }] in the order they will be written and `reason` is one of
    ' "planned" | "no-name" | "invalid" | "no-path" | "exists" | "no-author" |
    ' "no-license".
    function project_plan(opts, stamp)
        name = trim(opts.name)
        if name = "" then
            return studio_ui._plan_no("no-name", "")
        end if
        problem = studio_ui.name_problem(name)
        if problem != "" then
            return studio_ui._plan_no("invalid", problem)
        end if
        loc = trim(opts.location)
        if loc = "" then
            return studio_ui._plan_no("no-path", "")
        end if
        loc = studio_ui.expand_path(loc, studio_ui.home_dir(), studio_ui.launch_dir())
        ' The DIRECTORY is the slug, the project keeps the name. "My Thing"
        ' should not make a directory called `My Thing` that everything after
        ' this has to quote.
        path = loc + "/" + studio_ui._slug(name)
        probe{file} = path
        if exists(probe) then
            return studio_ui._plan_no("exists", path)
        end if

        holder = trim(opts.author)
        lic = opts.license
        text = ""
        if lic != "none" then
            needs = studio_ui.license_needs_holder(lic)
            if needs then
                if holder = "" then
                    ' Refused BEFORE anything is written. A licence naming
                    ' nobody grants nothing, and the field to fill is on screen.
                    return studio_ui._plan_no("no-author", lic)
                end if
            end if
            text = studio_ui.license_text(lic, studio_ui.license_year(stamp), holder)
            if text = "" then
                return studio_ui._plan_no("no-license", lic)
            end if
        end if

        files = []
        if opts.main then
            files = append(files, { name: "main.bas", text: studio_ui._main_text(name) })
        end if
        if opts.readme then
            files = append(files, { name: "README.md", text: studio_ui._readme_text(name, lic) })
        end if
        if lic != "none" then
            files = append(files, { name: "LICENSE", text: text })
        end if
        if opts.git then
            ' Written whether or not `git init` succeeds: it is an ordinary
            ' file and it is what keeps Studio's own scratch out of a
            ' repository somebody makes later by hand.
            files = append(files, { name: ".gitignore", text: studio_ui._gitignore_text() })
        end if
        return {
            ok: true, reason: "planned", detail: "", path: path, name: name,
            files: files, git: opts.git, projfile: opts.projfile
        }
    end function

    function _plan_no(reason, detail)
        return { ok: false, reason: reason, detail: detail, path: "", name: "",
                 files: [], git: false, projfile: false }
    end function

    ' A file that RUNS. The point of ticking main.bas is to land somewhere you
    ' can press Run Section, so the boilerplate is one runnable section and not
    ' a comment explaining that this is where code goes.
    function _main_text(name)
        return "' " + name + "\n\nprint \"hello from " + name + "\"\n"
    end function

    ' Minimal on purpose: a title, a line to fill in, and how to run it. A
    ' generated README padded with headings nobody asked for is a file the
    ' author has to delete before writing their own.
    function _readme_text(name, lic)
        out = "# " + name + "\n\n"
        out = out + "What this is.\n\n"
        out = out + "## Running it\n\n"
        out = out + "```sh\ngbasic main.bas\n```\n"
        if lic != "none" then
            out = out + "\n## Licence\n\n" + lic + " — see LICENSE.\n"
        end if
        return out
    end function

    ' Studio's own leavings and nothing else. It is NOT a language-wide ignore
    ' list: guessing at build artefacts for a project that has no build yet is
    ' how a generated .gitignore ends up hiding somebody's source.
    function _gitignore_text()
        line1 = "# gBASIC Studio keeps this project's state in YOUR home, not"
        line2 = "# here, so there is normally nothing of Studio's to ignore."
        return line1 + "\n" + line2 + "\n"
    end function

    ' ---- doing it -----------------------------------------------------------

    ' Carry out a plan: make the directory, write the files, optionally make it
    ' a repository, then adopt it as a project and make it active.
    '
    ' Returns { app, action, detail }. `action` is the plan's reason when the
    ' plan refused — so every refusal above reaches the status line by name and
    ' NOTHING has been created — and "created" otherwise, with a detail listing
    ' what was written so the window can say it.
    function create_project(app, opts)
        stamp = app["clock_fixed"]
        if stamp = unknown then
            stamp = epoch()
        end if
        if stamp = 0 then
            stamp = epoch()
        end if
        plan = studio_ui.project_plan(opts, stamp)
        if not plan.ok then
            return { app: app, action: plan.reason, detail: plan.detail }
        end if
        persist.ensure_dir(plan.path)
        made = []
        for each f in plan.files
            out{file} = plan.path + "/" + f.name
            write(out, f.text)
            made = append(made, f.name)
        end for
        ' Through the ONE writer, so "Studio never creates .gstudio.json except
        ' when asked" stays true of a checkbox as well as of a button.
        if plan.projfile then
            id = studio_projfile.mint_id(plan.path, stamp)
            pr = studio_projfile.create(plan.path, { id: id, name: plan.name })
            if pr.ok then
                made = append(made, studio_projfile.filename())
            end if
        end if
        ' git is OPTIONAL and its absence is not this project's problem. The
        ' directory and its files are already there; reporting "no git" beats
        ' refusing to make a project over it.
        if plan.git then
            avail = studio_git.available()
            if avail then
                g = studio_git.init(plan.path)
                if g.ok then
                    made = append(made, "git")
                end if
            end if
        end if
        ws = app.model.workspace
        if ws = nothing then
            app = studio.create_registered_workspace(app, "workspace")
            ws = app.model.workspace
        end if
        ws = studio_model.add_project(ws, plan.name, plan.path)
        proj = studio_model.last_project(ws)
        ws = studio_model.set_active_project(ws, proj.id)
        app = studio.set_workspace(app, ws)
        ' Its OWN action, not the "created" that New File answers with. That
        ' one reduces its detail to a single token, which for a project is the
        ' minted id — "created proj-1", about a thing the user named. Here the
        ' detail is the name and what was actually written, and it is reported
        ' whole.
        return { app: app, action: "project-created",
                 detail: plan.name + " — " + join(made, ", ") }
    end function

    ' ---- file and folder creation (STU-2C) ---------------------------------
    '
    ' STU-2B left New Project creating an EMPTY directory and no way to put
    ' anything into it, so a cold start dead-ended after one click: an empty
    ' project scans to zero browser rows, and opening, expanding, editing and
    ' saving are all reachable only through a file row. These two functions are
    ' the way out.
    '
    ' Neither asks for a name, for the same reason New Project does not: a modal
    ' text dialog is an async GTK surface with no synthesisable signal behind it,
    ' and the phase that adds one should be the phase that designs how such a
    ' dialog is covered. A deterministic minted name is renameable later and is
    ' assertable now.

    ' Where a creation lands: the selected directory, the directory holding the
    ' selected file, or the active project's root when nothing is selected. This
    ' is the whole of "where does it go", so a test can pin it without creating
    ' anything. Returns "" when no project is open.
    function target_dir(app)
        ws = app.model.workspace
        if ws = nothing then
            return ""
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return ""
        end if
        sel = ws.nav.selected_path
        if sel = "" then
            return proj.path
        end if
        ' `studio_docs._is_dir` rather than a second copy of the rule: there is no
        ' is_dir builtin, `read`/`file_size` RAISE on a directory (uncatchable in
        ' gBASIC), and `list` returns empty for a plain file AND for an empty
        ' directory — so the answer has to come from the PARENT's entry type, and
        ' that subtlety should exist in exactly one place.
        ' The selection must be inside the ACTIVE project, or creations land in
        ' one project's directory while being recorded as belonging to another.
        ' That is reachable in an ordinary way: switching the active project does
        ' not clear the browser selection, which still points into the tree of the
        ' project you just left. Studio's own workspace showed a document filed
        ' under proj-2 sitting in project-1's folder because of it.
        inside = studio_ui._under(sel, proj.path)
        if inside = false then
            return proj.path
        end if
        isdir = studio_docs._is_dir(sel)
        if isdir then
            return sel
        end if
        parent = studio_docs._dirname(sel)
        if parent = "" then
            return proj.path
        end if
        return parent
    end function

    ' Why a name is unusable, or "" when it is fine. Names arrive from the
    ' header's name field, so this is the only guard between a user's typing and
    ' `move`/`write` — "a/b" would relocate rather than rename, and ".."/"."
    ' would target the parent or the directory itself.
    function name_problem(name)
        if trim(name) = "" then
            return "empty"
        end if
        hit = find(name, "/")
        if hit != nothing then
            return "separator"
        end if
        if name = "." then
            return "dots"
        end if
        if name = ".." then
            return "dots"
        end if
        return ""
    end function

    ' The first "untitled-N.bas" that does not already exist in `dir`. Minting a
    ' name that is free rather than one that is next means a New File can never
    ' silently truncate a file the user made outside Studio.
    function next_untitled(dir)
        return studio_ui._free_name(dir, "untitled-", ".bas")
    end function

    function next_folder_name(dir)
        return studio_ui._free_name(dir, "new-folder-", "")
    end function

    ' Resolve "what should this be called" once for both creators: a typed name
    ' is validated and must not already exist; an empty one is minted, and a
    ' minted name is free by construction. Returns { name, action, detail } where
    ' a non-empty `action` means refuse and report it.
    function _chosen_name(dir, name, kind)
        if trim(name) = "" then
            if kind = "folder" then
                return { name: studio_ui.next_folder_name(dir), action: "", detail: "" }
            end if
            return { name: studio_ui.next_untitled(dir), action: "", detail: "" }
        end if
        wanted = trim(name)
        problem = studio_ui.name_problem(wanted)
        if problem != "" then
            return { name: "", action: "invalid", detail: problem }
        end if
        probe{file} = dir + "/" + wanted
        taken = exists(probe)
        if taken then
            return { name: "", action: "exists", detail: dir + "/" + wanted }
        end if
        return { name: wanted, action: "", detail: "" }
    end function

    function _free_name(dir, prefix, suffix)
        n = 1
        while n < 1000
            cand = prefix + n + suffix
            probe{file} = dir + "/" + cand
            taken = exists(probe)
            if taken then
                n = n + 1
            else
                return cand
            end if
        end while
        return prefix + "x" + suffix
    end function

    ' "New File": create an empty file in the target directory, make it visible,
    ' select it, and open it into a tab so the user can type immediately.
    '
    ' `name` is whatever the header's name field held. Empty means "mint one", so
    ' the button still works with the field untouched — which is how STU-2C left
    ' it and what a first-time click does. Returns { app, action, detail } with
    ' action "created" | "none" (nothing open) | "invalid" | "exists".
    function new_file(app, name)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        dir = studio_ui.target_dir(app)
        chosen = studio_ui._chosen_name(dir, name, "file")
        if chosen.action != "" then
            return { app: app, action: chosen.action, detail: chosen.detail }
        end if
        path = dir + "/" + chosen.name
        persist.write_text_atomic(path, "")
        ' A file created inside a collapsed directory would exist and not be on
        ' screen, which reads as the button having done nothing.
        if dir != proj.path then
            ws = studio_model.expand_path(ws, dir)
        end if
        ws = studio_model.set_selected_path(ws, path)
        app = studio.set_workspace(app, ws)
        opened = studio.open_from_browser(app, proj.id, path)
        return { app: opened.app, action: "created", detail: path + " " + opened.id }
    end function

    ' "New Folder": create a directory in the target directory and expand the
    ' target so the new row is visible.
    '
    ' The selection deliberately does NOT move into it. If it did, a second click
    ' would create a folder inside the first and a third inside the second, which
    ' is not what "New Folder" twice means anywhere else. Clicking the folder is
    ' how you go into it — the same gesture as every other file browser.
    function new_folder(app, name)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        dir = studio_ui.target_dir(app)
        chosen = studio_ui._chosen_name(dir, name, "folder")
        if chosen.action != "" then
            return { app: app, action: chosen.action, detail: chosen.detail }
        end if
        path = dir + "/" + chosen.name
        persist.ensure_dir(path)
        if dir != proj.path then
            ws = studio_model.expand_path(ws, dir)
        end if
        app = studio.set_workspace(app, ws)
        return { app: app, action: "created", detail: path }
    end function

    ' ---- rename (STU-2D) -----------------------------------------------------

    ' Rename whatever the browser has selected to `name` (a bare name, not a
    ' path). Returns { app, action, detail }, action one of:
    '   "renamed"   — moved; the selection, the expansion set and any open tab
    '                 followed it
    '   "none"      — nothing selected
    '   "invalid"   — the name is empty, has a separator, or is "."/".."
    '   "missing"   — the selected path is no longer there
    '   "exists"    — something already has that name here
    '   "unchanged" — it is already called that
    '   "dirty"     — the file is open with unsaved text (see below)
    '   "in-use"    — a directory with an open document somewhere inside it
    '
    ' The two refusals are about documents, not files. A document is bound to its
    ' path, so renaming one means closing and reopening it, and doing that to a
    ' buffer with unsaved text would throw the text away — a rename must not be a
    ' way to lose work. The directory case is the same hazard one level up.
    function rename_selected(app, name)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        sel = ws.nav.selected_path
        if sel = "" then
            return { app: app, action: "none", detail: "" }
        end if
        problem = studio_ui.name_problem(name)
        if problem != "" then
            return { app: app, action: "invalid", detail: problem }
        end if
        wanted = trim(name)
        src{file} = sel
        there = exists(src)
        if there = false then
            return { app: app, action: "missing", detail: sel }
        end if
        parent = studio_docs._dirname(sel)
        dest = parent + "/" + wanted
        if dest = sel then
            return { app: app, action: "unchanged", detail: sel }
        end if
        dst{file} = dest
        taken = exists(dst)
        if taken then
            return { app: app, action: "exists", detail: dest }
        end if

        isdir = studio_docs._is_dir(sel)
        if isdir then
            for each d in app.dm.docs
                inside = studio_ui._under(d.path, sel)
                if inside then
                    return { app: app, action: "in-use", detail: d.id }
                end if
            end for
        end if
        doc = studio_ui._doc_by_path(app.dm, sel)
        if doc != nothing then
            dirty = studio_docs.is_dirty(doc)
            if dirty then
                return { app: app, action: "dirty", detail: doc.id }
            end if
        end if

        move(src, dest)

        ' The expansion set holds absolute paths, so a renamed directory takes
        ' its whole subtree's expansion state with it or the tree silently
        ' collapses under the new name.
        ws = studio_ui._remap_expanded(ws, sel, dest)
        ws = studio_model.set_selected_path(ws, dest)
        app = studio.set_workspace(app, ws)

        if doc != nothing then
            was_active = doc.id = app.dm.active
            c = studio.close_document(app, doc.id, "discard")
            app = c.app
            proj = studio_model.project_by_id(ws, ws.active_project)
            pid = ""
            if proj != nothing then
                pid = proj.id
            end if
            opened = studio.open_from_browser(app, pid, dest)
            app = opened.app
            if was_active then
                app = studio.set_active_document(app, opened.id)
            end if
        end if
        return { app: app, action: "renamed", detail: sel + " " + dest }
    end function

    ' Every expanded path at or under `old_path`, rewritten to sit under
    ' `new_path` — or dropped entirely when `new_path` is "" (a deletion).
    ' (`to` and `from` are reserved words in gBASIC, hence the longer names.)
    function _remap_expanded(ws, old_path, new_path)
        nav = ws.nav
        moved = []
        for each p in nav.expanded
            keep = p
            if p = old_path then
                keep = new_path
            else
                under = studio_ui._under(p, old_path)
                if under then
                    if new_path = "" then
                        keep = ""
                    else
                        keep = new_path + mid(p, len(old_path), len(p) - len(old_path))
                    end if
                end if
            end if
            if keep != "" then
                moved = append(moved, keep)
            end if
        end for
        nav.expanded = moved
        ws.nav = nav
        return ws
    end function

    ' Is `path` inside directory `dir`? A prefix match alone would call
    ' "/a/srcery" a child of "/a/src", so the separator has to be part of it.
    function _under(path, dir)
        pre = dir + "/"
        if len(path) <= len(pre) then
            return false
        end if
        return mid(path, 0, len(pre)) = pre
    end function

    function _doc_by_path(dm, path)
        for each d in dm.docs
            if d.path = path then
                return d
            end if
        end for
        return nothing
    end function

    ' ---- delete (STU-2D) -----------------------------------------------------

    ' Delete the selected file or empty directory — but only on the SECOND click.
    ' `armed` is the path a previous click armed; the caller stores whatever comes
    ' back in `armed` and hands it in next time.
    '
    ' Arming is keyed to the path rather than to a flag, so clicking a different
    ' row between the two presses re-arms on the new row instead of deleting it.
    ' There is no confirmation dialog for the same reason there is no name dialog:
    ' it would be an async surface no test can drive. Two clicks is a
    ' confirmation the whole suite can press.
    '
    ' Returns { app, action, detail, armed }, action one of "armed" | "deleted" |
    ' "none" | "missing" | "not-empty".
    function delete_selected(app, armed)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "", armed: "" }
        end if
        sel = ws.nav.selected_path
        if sel = "" then
            return { app: app, action: "none", detail: "", armed: "" }
        end if
        if armed != sel then
            return { app: app, action: "armed", detail: sel, armed: sel }
        end if

        ref{file} = sel
        there = exists(ref)
        if there = false then
            ws = studio_model.set_selected_path(ws, "")
            app = studio.set_workspace(app, ws)
            return { app: app, action: "missing", detail: sel, armed: "" }
        end if

        isdir = studio_docs._is_dir(sel)
        if isdir then
            d{dir} = sel
            if count(list(d)) > 0 then
                ' Recursive deletion is a different promise from "delete this",
                ' and it deserves a confirmation that names what goes with it.
                return { app: app, action: "not-empty", detail: sel, armed: "" }
            end if
            remove_dir(sel)
        else
            doc = studio_ui._doc_by_path(app.dm, sel)
            if doc != nothing then
                ' The user confirmed the file; the buffer goes with it.
                c = studio.close_document(app, doc.id, "discard")
                app = c.app
            end if
            delete(ref)
        end if

        ws = app.model.workspace
        ws = studio_ui._remap_expanded(ws, sel, "")
        ws = studio_model.set_selected_path(ws, "")
        app = studio.set_workspace(app, ws)
        return { app: app, action: "deleted", detail: sel, armed: "" }
    end function

    ' ---- closing a tab (STU-2D) ---------------------------------------------

    ' Close the active document. A clean one closes on the first click; an unsaved
    ' one arms exactly like Delete, so discarding work always takes two presses.
    ' Returns { app, action, detail, armed }, action "closed" | "armed-close" |
    ' "none".
    function close_active(app, armed)
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "none", detail: "", armed: "" }
        end if
        dirty = studio_docs.is_dirty(doc)
        if dirty then
            if armed != doc.id then
                return { app: app, action: "armed-close", detail: doc.id, armed: doc.id }
            end if
        end if
        c = studio.close_document(app, doc.id, "discard")
        return { app: c.app, action: "closed", detail: doc.id, armed: "" }
    end function

    ' Select a row WITHOUT activating it.
    '
    ' A right-click has to put the selection where the menu is about, because
    ' Rename, Delete and `target_dir` all read it -- but it must not do what a
    ' left-click does. `activate_row` on a file OPENS it and on a directory
    ' toggles it, and a menu that opened the file before you had chosen anything
    ' from it would be a menu that acted first and asked afterwards.
    '
    ' Project rows are the exception and go through `activate_row` at the call
    ' site: "Add project file" and "Close project" are about a project, and the
    ' one a user just pointed at is the one they mean.
    function select_row(app, rows, index)
        if index < 0 then
            return { app: app, action: "none", detail: "" }
        end if
        if index >= count(rows) then
            return { app: app, action: "none", detail: "" }
        end if
        row = rows[index]
        if row.path = "" then
            return { app: app, action: "none", detail: "" }
        end if
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "none", detail: "" }
        end if
        ws = studio_model.set_selected_path(ws, row.path)
        app = studio.set_workspace(app, ws)
        return { app: app, action: "selected", detail: row.path }
    end function

    ' ---- the browser's context menu (STU-13) --------------------------------
    '
    ' What a right-click OFFERS is decided here, over the row model, so the menu
    ' can be asserted without a popover. The shell builds one popover holding
    ' every item there is and shows the ones this list names.
    '
    ' Nothing here is a new capability. Every action maps onto a function the
    ' toolbar already calls, so the menu is an adapter and not a second
    ' implementation -- which matters most for the two that ARM: a menu Delete
    ' that deleted outright would quietly undo the two-click rule the button
    ' obeys, on the same file.

    ' Every item the menu can hold, in the order it is built. The shell walks
    ' this to make the widgets; `context_actions` decides which of them a
    ' particular row shows.
    function context_all()
        return ["open", "new-file-here", "new-folder-here", "rename", "delete",
                "project-file", "close-project"]
    end function

    ' What this row offers, or [] for a row that offers nothing. An empty list
    ' means NO MENU -- a popover with nothing in it is worse than no popover,
    ' because it reads as a control that failed.
    function context_actions(rows, index)
        if index < 0 then
            return []
        end if
        if index >= count(rows) then
            return []
        end if
        r = rows[index]
        if r.kind = "file" then
            return ["open", "rename", "delete"]
        end if
        if r.kind = "dir" then
            ' Creating lands INSIDE the directory that was clicked, through the
            ' same `target_dir` rule the toolbar uses -- which is why the
            ' labels say "here" rather than leaving it to be guessed.
            return ["new-file-here", "new-folder-here", "rename", "delete"]
        end if
        if r.kind = "project" then
            return ["project-file", "close-project"]
        end if
        return []
    end function

    ' The wording on the item.
    function context_label(action)
        if action = "open" then
            return "Open"
        end if
        if action = "new-file-here" then
            return "New File here"
        end if
        if action = "new-folder-here" then
            return "New Folder here"
        end if
        if action = "rename" then
            return "Rename…"
        end if
        if action = "delete" then
            return "Delete"
        end if
        if action = "project-file" then
            return "Add project file"
        end if
        if action = "close-project" then
            return "Close project"
        end if
        return action
    end function

    ' ---- closing a project --------------------------------------------------

    ' Take a project out of the workspace.
    '
    ' NOT armed, unlike Delete and Close, because nothing is lost: the directory
    ' is untouched, the project's state file stays on disk under its own key,
    ' and Open Folder puts it back with its anchors intact. Arming a reversible
    ' act would spend the user's attention on the wrong one.
    '
    ' It REFUSES while a document under it has unsaved text, naming the file.
    ' Closing the project closes those tabs, and Studio keeps no drafts, so
    ' going ahead would be the silent loss that `armed-close` exists to prevent
    ' -- one level up, where it is easier to do by accident.
    '
    ' Returns { app, action, detail }, action one of "project-closed", "dirty",
    ' "no-project".
    function close_project(app, project_id)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "no-project", detail: "" }
        end if
        proj = studio_model.project_by_id(ws, project_id)
        if proj = nothing then
            return { app: app, action: "no-project", detail: "" }
        end if
        under = []
        for each d in app.dm.docs
            if studio_ui._under(d.path, proj.path) then
                dirty = studio_docs.is_dirty(d)
                if dirty then
                    return { app: app, action: "dirty", detail: d.path }
                end if
                under = append(under, d.id)
            end if
        end for
        ' Its anchors, written before the project stops being findable. After
        ' the removal below `project_path_for` answers "" for these documents,
        ' so the cache would be flushed to nowhere.
        held = app["pstate"]
        if held != unknown then
            if held != nothing then
                if held.path = proj.path then
                    wrote = studio_projects.save(app.paths.home, held.key, held.state)
                    app["pstate"] = nothing
                end if
            end if
        end if
        for each id in under
            c = studio.close_document(app, id, "discard")
            app = c.app
        end for
        ws = app.model.workspace
        ' A selection pointing into a project that is gone is a path nothing can
        ' render and `target_dir` would still be asked about. Cleared only when
        ' it was inside THIS project, so closing one does not disturb the
        ' selection in another.
        inside = studio_ui._under(ws.nav.selected_path, proj.path)
        if inside then
            ws = studio_model.set_selected_path(ws, "")
        end if
        ws = studio_model.remove_project(ws, project_id)
        app = studio.set_workspace(app, ws)
        return { app: app, action: "project-closed", detail: proj.name }
    end function

    ' ---- what the window says back (STU-2D) ---------------------------------

    ' The status-bar line for an outcome. Every action gets one: a refusal that
    ' says nothing is indistinguishable from a button that is not wired, which is
    ' precisely how STU-2B's window felt before it had any handlers at all.
    ' Returns "" for the outcomes that are their own feedback — a row opening, a
    ' tab switching, a keystroke landing — where a status line would just be
    ' noise over something the user can already see.
    function action_notice(action, detail)
        leaf = studio_ui._leaf(detail)
        if action = "created" then
            ' "<path> <doc-id>" — the status line wants the file, not the id.
            return "created " + studio_ui._token_leaf(detail, 0)
        end if
        if action = "renamed" then
            ' "<from> <to>" — and what the user wants confirmed is the `to`.
            return "renamed to " + studio_ui._token_leaf(detail, 1)
        end if
        if action = "deleted" then
            return "deleted " + leaf
        end if
        if action = "closed" then
            return "closed " + leaf
        end if
        if action = "saved" then
            return "saved " + leaf
        end if
        if action = "error" then
            return "could not save " + leaf
        end if
        if action = "armed" then
            return "delete " + leaf + "? — click Delete again to confirm"
        end if
        if action = "armed-close" then
            return leaf + " has unsaved changes — click Close again to discard them"
        end if
        if action = "armed-save" then
            return "the file changed on disk since you opened it — click Save again to overwrite it"
        end if
        if action = "invalid" then
            return "that name will not do (" + detail + ")"
        end if
        if action = "exists" then
            return leaf + " already exists"
        end if
        if action = "unchanged" then
            return "already called " + leaf
        end if
        if action = "missing" then
            return leaf + " is not there"
        end if
        ' The WHOLE path, not its last segment. `missing` above is about a
        ' browser row, where the leaf is the thing the user clicked; this is
        ' about a path they typed, and the part that is wrong is usually the
        ' part the leaf hides.
        if action = "no-folder" then
            return "no folder at " + detail
        end if
        if action = "no-path" then
            return "type a folder path into the name field, then press Open Folder"
        end if
        ' Named, so it reads as a statement about THIS file rather than about
        ' the button. Studio opens supporting files on purpose; it just cannot
        ' run them.
        if action = "not-gbasic" then
            return leaf + " is not a gBASIC file — Run Section needs .bas or .gb"
        end if
        if action = "not-empty" then
            return leaf + " is not empty — empty it first"
        end if
        if action = "dirty" then
            return "save " + leaf + " first"
        end if
        if action = "in-use" then
            return "something inside it is open (" + leaf + ")"
        end if
        ' "<project-id> <name>" — a user knows the folder by its name, not by an
        ' id Studio minted.
        if action = "adopted" then
            return "opened " + studio_ui._token_leaf(detail, 1)
        end if
        if action = "activated" then
            return "switched to " + studio_ui._token_leaf(detail, 1)
        end if
        ' The WHOLE path, like no-folder: the leaf is `.gstudio.json` for every
        ' project there has ever been, so it is the directory that says which
        ' one just acquired a file.
        if action = "project-file" then
            return "wrote " + detail
        end if
        if action = "rename-ready" then
            return "type the new name in the field, then press Rename"
        end if
        if action = "project-closed" then
            ' The directory is still there and Open Folder puts it back, so the
            ' line says what happened rather than warning about it.
            return "closed " + detail + " — the folder is untouched"
        end if
        if action = "no-project" then
            return "open a project first"
        end if
        ' ---- New Project, with options
        if action = "project-created" then
            ' Whole, not tokenised: a project name has spaces in it, and the
            ' list after it is the answer to "what did that button just do to
            ' my directory".
            return "created " + detail
        end if
        if action = "no-name" then
            return "give the project a name"
        end if
        if action = "no-author" then
            return detail + " names a copyright holder — fill in Author"
        end if
        if action = "no-license" then
            return "no text shipped for " + detail + " — check share/licenses"
        end if
        if action = "refreshed" then
            return "refreshed"
        end if
        if action = "branched" then
            return "branched: " + studio_ui._token_leaf(detail, 1)
        end if
        if action = "on-branch" then
            return "on branch " + leaf
        end if
        if action = "baseline" then
            return "back to the baseline"
        end if
        if action = "bound" then
            return "bound " + detail
        end if
        if action = "no-branch" then
            return "select a branch first — the baseline takes no bindings"
        end if
        if action = "running" then
            return "running " + detail
        end if
        if action = "materializing" then
            return "preparing " + detail
        end if
        if action = "ran" then
            ' "<section-id> <final-state>" — the strip already shows the state.
            return "finished " + studio_ui._token_leaf(detail, 0)
        end if
        if action = "refused" then
            return "will not run it — " + detail
        end if
        if action = "failed" then
            return "the run failed — " + detail
        end if
        if action = "busy" then
            return "a run is already going (" + detail + ") — stop it first"
        end if
        if action = "no-section" then
            return "the cursor is not inside a runnable section"
        end if
        ' The detail is already "severity line:column  message". A parse that
        ' fails with no diagnostic at all should still not produce a blank
        ' sentence ending in a dash.
        if action = "no-parse" then
            if detail = "" then
                return "this file does not parse — fix the syntax error first"
            end if
            return "this file does not parse — " + detail
        end if
        if action = "stopping" then
            return "stopping " + detail
        end if
        if action = "forced" then
            return "forced " + detail + " to stop"
        end if
        if action = "idle" then
            return "nothing is running"
        end if
        if action = "none" then
            return "nothing selected"
        end if
        if action = "unknown" then
            return ""
        end if
        return ""
    end function

    ' The last path segment of whitespace-token `i` of a detail, for the details
    ' that carry two things.
    function _token_leaf(detail, i)
        parts = split(detail, " ")
        if i >= count(parts) then
            return studio_ui._leaf(detail)
        end if
        return studio_ui._leaf(parts[i])
    end function

    ' Which arm, if any, an outcome keeps alive. Anything else clears BOTH, so an
    ' arm cannot survive an unrelated click and fire much later against a
    ' selection the user has long since moved.
    function arm_kind(action)
        if action = "armed" then
            return "path"
        end if
        if action = "armed-close" then
            return "doc"
        end if
        if action = "armed-save" then
            return "save"
        end if
        return ""
    end function

    ' After these, the header's name field has been consumed and should empty —
    ' otherwise the next click reuses the same name and is refused as "exists",
    ' which reads as the button having broken.
    function clears_name(action)
        if action = "created" then
            return true
        end if
        if action = "renamed" then
            return true
        end if
        if action = "adopted" then
            return true
        end if
        if action = "branched" then
            return true
        end if
        if action = "bound" then
            return true
        end if
        if action = "activated" then
            return true
        end if
        return false
    end function

    ' ---- opening an existing directory --------------------------------------

    ' ---- a path as a PERSON types it ----------------------------------------
    '
    ' A GtkEntry is not a shell, so nothing expanded what everybody types first.
    ' Measured before this existed: `~/development/gdash` came back "gdash is not
    ' there", about a directory that was plainly there, and `development/gdash`
    ' was resolved against Studio's own source tree because `./studio` cds into
    ' the install directory before exec.
    '
    ' Pure over three strings, so all of it is testable; the caller reads `home`
    ' and `cwd` out of the environment. `~user` is NOT expanded — that needs a
    ' passwd lookup, and a wrong guess at someone else's home is worse than
    ' leaving the path alone to fail honestly.
    function expand_path(raw, home, cwd)
        if raw = "" then
            return ""
        end if
        p = studio_ui._expand_home(raw, home)
        if left(p, 1) = "/" then
            return p
        end if
        if cwd = "" then
            return p
        end if
        ' Relative to where Studio was LAUNCHED, which is the same referent the
        ' third command-line argument already uses. Relative to Studio's own
        ' working directory — the install tree — is the one answer that is never
        ' what anyone meant.
        return cwd + "/" + p
    end function

    function _expand_home(raw, home)
        if home = "" then
            return raw
        end if
        if not is_string(home) then
            return raw
        end if
        if raw = "~" then
            return home
        end if
        if left(raw, 2) = "~/" then
            return home + "/" + mid(raw, 2, len(raw) - 2)
        end if
        return raw
    end function

    ' HOME, and the directory `./studio` was invoked from. Both may be absent —
    ' an unset variable is `unknown`, not "", and string operations raise on it.
    function home_dir()
        return studio_ui._env_string("HOME")
    end function

    function launch_dir()
        return studio_ui._env_string("GBASIC_STUDIO_CWD")
    end function

    function _env_string(name)
        v = env(name)
        if not is_string(v) then
            return ""
        end if
        return v
    end function

    ' Adopt `path` as a project, creating a workspace if none is open — so this,
    ' like New Project, works from a cold start. Studio is otherwise only usable
    ' on directories it made itself, which is the wrong way round for an IDE.
    '
    ' Returns { app, action, detail }, action one of:
    '   "adopted"   — a new project over that directory, named after its last
    '                 segment, and active
    '   "activated" — the directory was already a project here; it was made
    '                 active rather than added twice
    '   "no-folder" — no such directory (a plain file counts too: a project root
    '                 has to be somewhere files can live). The detail is the
    '                 EXPANDED path, because "gdash is not there" about
    '                 `~/development/gdash` blames the folder for a `~` nobody
    '                 expanded
    '   "no-path"   — an empty field, which is a question rather than a failure
    function adopt_folder(app, raw)
        if raw = "" then
            return { app: app, action: "no-path", detail: "" }
        end if
        ' Typed by a person, so `~` and a relative path have to mean what they
        ' mean everywhere else. Then canonicalise: the path also arrives from a
        ' command line, with a trailing slash from tab-completion, a "." or a
        ' "..", and the same directory must not adopt twice under two spellings.
        path = studio_docs._canonical(studio_ui.expand_path(raw,
                                                            studio_ui.home_dir(),
                                                            studio_ui.launch_dir()))
        if path = "" then
            return { app: app, action: "no-path", detail: "" }
        end if
        probe{file} = path
        there = exists(probe)
        isdir = false
        if there then
            isdir = studio_docs._is_dir(path)
        end if
        if isdir = false then
            return { app: app, action: "no-folder", detail: path }
        end if
        ws = app.model.workspace
        if ws = nothing then
            app = studio.create_registered_workspace(app, "workspace")
            ws = app.model.workspace
        end if
        ' READ, never written — Open Folder puts nothing in a directory it was
        ' merely pointed at. A project that carries its own name gets to say it,
        ' which is the answer to two checkouts both called `src`; the name lands
        ' when the folder is opened, so editing it in the file shows up the next
        ' time you open the project rather than mid-session.
        spec = studio_projfile.read_spec(path)
        for each pr in ws.projects
            if pr.path = path then
                ws = studio_model.set_active_project(ws, pr.id)
                if spec.name != "" then
                    ws = studio_model.rename_project(ws, pr.id, spec.name)
                end if
                app = studio.set_workspace(app, ws)
                pr2 = studio_model.project_by_id(ws, pr.id)
                return { app: app, action: "activated", detail: pr.id + " " + pr2.name }
            end if
        end for
        name = studio_ui._leaf(path)
        if spec.name != "" then
            name = spec.name
        end if
        ws = studio_model.add_project(ws, name, path)
        proj = studio_model.last_project(ws)
        ws = studio_model.set_active_project(ws, proj.id)
        app = studio.set_workspace(app, ws)
        return { app: app, action: "adopted", detail: proj.id + " " + name }
    end function

    ' ---- the project's own file ---------------------------------------------

    ' Write `.gstudio.json` into the active project — the ONLY thing in Studio
    ' that creates it, reached only from the button of the same name. Open
    ' Folder does not write it. New Project writes it only when the box is
    ' ticked. Nothing writes it on save, on exit, or on first run.
    '
    ' Returns { app, action, detail }, action one of:
    '   "project-file" — written; detail is its path
    '   "exists"       — there is one already, and this does not rewrite it
    '   "no-project"   — nothing is open to add it to
    function add_project_file(app)
        ws = app.model.workspace
        if ws = nothing then
            return { app: app, action: "no-project", detail: "" }
        end if
        proj = studio_model.project_by_id(ws, ws.active_project)
        if proj = nothing then
            return { app: app, action: "no-project", detail: "" }
        end if
        ' Pinned by the same seam the run clock uses, so a golden can hold the
        ' shape of a minted id without holding the second it was minted in.
        stamp = app["clock_fixed"]
        if stamp = unknown then
            stamp = epoch()
        end if
        if stamp = 0 then
            stamp = epoch()
        end if
        id = studio_projfile.mint_id(proj.path, stamp)
        r = studio_projfile.create(proj.path, { id: id, name: proj.name })
        if not r.ok then
            return { app: app, action: r.reason, detail: r.path }
        end if
        ' This project was filed under its PATH a moment ago and is filed under
        ' its ID from here on, so the anchors have to come with it. Without
        ' this, adding a project file would silently renumber every section in
        ' the project — the STU-3 misattribution, re-entered through a button
        ' whose whole promise is that it changes nothing about your code.
        app = studio_ui._refile_state(app, proj.path, id)
        return { app: app, action: "project-file", detail: r.path }
    end function

    ' Carry a project's state from its path key to its id key.
    '
    ' The old file is LEFT IN PLACE, like the workspace migration: until the
    ' next clean save it is the only copy, and there is no undo for the button
    ' that caused this.
    function _refile_state(app, project_path, id)
        oldk = studio_projects.key_for(project_path, "")
        newk = studio_projects.key_for(project_path, id)
        if oldk = newk then
            return app
        end if
        held = app["pstate"]
        if held != unknown then
            if held != nothing then
                if held.path = project_path then
                    ' Loaded, and newer than anything on disk. Re-file what is
                    ' in memory and re-point the cache; a read of the old file
                    ' here would lose this session's edits.
                    wrote = studio_projects.save(app.paths.home, newk, held.state)
                    app["pstate"] = { path: project_path, key: newk, state: held.state }
                    return app
                end if
            end if
        end if
        st = studio_projects.open(app.paths.home, oldk)
        if st.key = "" then
            return app
        end if
        empty = false
        if count(st.sections) = 0 then
            if st.branches = nothing then
                if st.overlays = nothing then
                    empty = true
                end if
            end if
        end if
        ' Nothing to carry. Writing an empty state file here would leave a
        ' record about a project Studio has learned nothing about yet.
        if empty then
            return app
        end if
        wrote = studio_projects.save(app.paths.home, newk, st)
        return app
    end function

    ' ---- closing ------------------------------------------------------------

    ' How many open documents hold unsaved text. Closing the window persists the
    ' workspace (which documents were open) but NOT their buffers, so the caller
    ' can say so instead of letting the edits disappear quietly.
    function dirty_count(app)
        n = 0
        for each d in app.dm.docs
            dirty = studio_docs.is_dirty(d)
            if dirty then
                n = n + 1
            end if
        end for
        return n
    end function

    ' ---- refresh ------------------------------------------------------------

    ' "Refresh" = re-read the world. The browser rescans on every render already
    ' (nav_rows calls filetree.scan), so what this adds is the document side:
    ' every open buffer is re-checked against disk under the safe policy — clean
    ' documents reload, dirty ones are flagged as conflicts rather than
    ' overwritten, deleted ones are marked missing.
    '
    ' Returns { app, action, detail }; detail summarises what moved, in a fixed
    ' order so it is assertable.
    function refresh(app)
        cp = studio.checkpoint_documents(app)
        detail = "reloaded=" + join(cp.reloaded, ",") + " conflicts=" + join(cp.conflicts, ",") + " deleted=" + join(cp.deleted, ",")
        return { app: cp.app, action: "refreshed", detail: detail }
    end function

    ' ---- running a section (STU-2E) -----------------------------------------
    '
    ' STU-4 built the execution engine and STU-5A the durable results, and both
    ' have been driven only by smoke modes since: the Run strip existed as a
    ' builder nothing mounted. This is the wiring, and it is the first interaction
    ' that is not instantaneous — a run starts, then continues across GTK timer
    ' ticks — so it needs one thing the others did not: somewhere to keep the
    ' in-flight run.
    '
    ' That is `app.exec`, alongside `app.dm`: live state the app carries and the
    ' shutdown pipeline does not write, because a half-finished child process is
    ' not something to restore into.
    '
    '   app.exec = { doc_id, doc_path, sid, secs, src, session, store }
    '
    ' The section is decided ONCE, when Run is pressed, from the cursor as it was
    ' at that moment — together with the source as it was at that moment. Both are
    ' kept for the rest of the run, because a result is a statement about the text
    ' that ran, not about whatever the user has typed since.

    ' How long a Force Stop gives the child between SIGTERM and giving up on a
    ' polite exit.
    function force_grace()
        return 2
    end function

    ' Which section a 1-based position means, with the gaps filled in.
    '
    ' Section ranges cover the statements, not the whitespace between and after
    ' them, so `section_at` returns nothing for a caret on a file's trailing blank
    ' line — which is exactly where a caret sits after opening a file, and a very
    ' common place for a user to leave it. Refusing there would make Run look
    ' broken for the most ordinary click there is.
    '
    ' So a position outside every section resolves to the section it is at or
    ' after — the blank line between two sections belongs to the one above it,
    ' and a file's trailing blank line to the last section. Above them all, it is
    ' the first. Only a document with no sections at all has no answer.
    '
    ' "The last section" as a blanket fallback was wrong and looked right: an
    ' interior gap is far more common than a trailing one, and it would have sent
    ' every blank line in the file to the bottom of it.
    function section_for(st, source, line1, column1)
        if st = nothing then
            return ""
        end if
        off = studio_sections.offset_of(source, line1, column1)
        hit = studio_sections.section_at(st, off)
        if hit != nothing then
            if hit != "" then
                return hit
            end if
        end if
        best = ""
        best_start = -1
        for each s in st.sections
            if s.status != "stale" then
                if s.start_offset <= off then
                    if s.start_offset >= best_start then
                        best = s.id
                        best_start = s.start_offset
                    end if
                end if
            end if
        end for
        if best != "" then
            return best
        end if
        for each s in st.sections
            if s.status != "stale" then
                return s.id
            end if
        end for
        return ""
    end function

    ' ---- branches (STU-7) ---------------------------------------------------

    ' The branch tree for the workspace. Lives in the workspace record beside the
    ' section anchors, because a branch means nothing without the sections it
    ' points at and the two must be restored together or not at all.
    function branch_tree(app)
        ps = studio_ui.project_state(app)
        return studio_branches.from_persist(ps.state.branches)
    end function

    function set_branch_tree(app, tree)
        ps = studio_ui.project_state(app)
        st = ps.state
        st.branches = studio_branches.to_persist(tree)
        return studio_ui.set_project_state(ps.app, st)
    end function

    ' ---- overlays (STU-9) ---------------------------------------------------

    ' A branch's code overlay, stored in the workspace beside the branch tree for
    ' the same reason the tree sits beside the section anchors: an overlay is
    ' addressed by section id, so it is meaningless without the anchors that give
    ' those ids meaning, and the three must be restored together or not at all.
    function overlays(app)
        ps = studio_ui.project_state(app)
        return studio_overlays.from_persist(ps.state.overlays)
    end function

    function set_overlays(app, ov)
        ps = studio_ui.project_state(app)
        st = ps.state
        st.overlays = studio_overlays.to_persist(ov)
        return studio_ui.set_project_state(ps.app, st)
    end function

    ' Which KIND of branch this is (§9.2) — DERIVED, never stored. A stored kind
    ' is a second source of truth that can disagree with the edits themselves, and
    ' the disagreement would show up as a branch that says "code" and runs the
    ' canonical text.
    function branch_kind(app, branch)
        if branch = "" then
            return "baseline"
        end if
        if studio_overlays.has_any(studio_ui.overlays(app), branch) then
            return "code"
        end if
        return "state"
    end function

    ' The source THIS BRANCH sees: canonical text with the selected chain's
    ' overlay edits projected over it.
    '
    ' Every edit in the chain is projected, not just the selected branch's own —
    ' a branch nested under an overlay branch inherits its parent's code, which is
    ' what "everything below the branch point may diverge" means once the
    ' divergence is code.
    '
    ' The canonical file is not read, written, or touched: the projection is a
    ' value, and the only thing that ever reaches a disk is the temp materialization
    ' the run pipeline already writes.
    function projected_source(app)
        v = studio_ui.view_for(app)
        app = v.app
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, text: "", applied: [], overlaid: false }
        end if
        ov = studio_ui.overlays(app)
        tree = studio_ui.branch_tree(app)
        edits = []
        for each b in studio_branches.selected_chain(tree, studio_ui.doc_key(doc), v.st)
            for each e in studio_overlays.for_branch(ov, b.id)
                edits = append(edits, e)
            end for
        end for
        if count(edits) = 0 then
            return { app: app, text: doc.content, applied: [], overlaid: false }
        end if
        ok = studio_overlays.applicable(v.st, edits, -1)
        p = studio_overlays.project(doc.content, v.st, ok)
        return { app: app, text: p.text, applied: p.applied, overlaid: true }
    end function

    ' The sections OF THE SOURCE THIS BRANCH SEES.
    '
    ' For a baseline or a state-only branch this is just the canonical outline.
    ' For an overlay branch it is the outline of the projection — and everything
    ' about that branch is then judged against it: which section the caret is in,
    ' which section a run targets, and whether a stored result still describes the
    ' text it ran. Judging an overlay branch's results against CANONICAL sections
    ' would mark every one of them changed the moment the overlay existed, which
    ' is noise dressed as honesty.
    '
    ' Section ids survive the projection because STU-3 re-matches on structural
    ' evidence — kind, name, ancestry, ordinal — and an overlay replaces a
    ' section's body, not its identity. An overlay that renames the function it
    ' replaces is the case where that stops being true, and it shows up honestly:
    ' the id does not re-match, and the run refuses rather than running a
    ' different section under the old id.
    '
    ' CACHED on the app beside the canonical view, and for the same reason: this
    ' runs on every render, and re-parsing a document at cursor-move rate is what
    ' the STU-5A cache exists to prevent. The key is the projected TEXT, which
    ' moves whenever the document, the overlay or the selection does — splicing to
    ' compare is cheap; parsing is not.
    function branch_sections(app)
        v = studio_ui.view_for(app)
        app = v.app
        ps = studio_ui.projected_source(app)
        app = ps.app
        if not ps.overlaid then
            return { app: app, st: v.st, src: ps.text, overlaid: false }
        end if
        cached = app["bview"]
        if cached != unknown then
            if cached != nothing then
                if cached.src = ps.text then
                    return { app: app, st: cached.st, src: ps.text, overlaid: true }
                end if
            end if
        end if
        bst = studio_sections.refresh(v.st, ps.text)
        app["bview"] = { src: ps.text, st: bst }
        return { app: app, st: bst, src: ps.text, overlaid: true }
    end function

    ' Every conflict in the selected chain's overlay, against the sections as they
    ' are now. Surfaced, never acted on (§9.3).
    function overlay_conflicts(app)
        v = studio_ui.view_for(app)
        app = v.app
        doc = studio_docs.active_doc(app.dm)
        out = []
        if doc = nothing then
            return { app: app, problems: out }
        end if
        ov = studio_ui.overlays(app)
        tree = studio_ui.branch_tree(app)
        for each b in studio_branches.selected_chain(tree, studio_ui.doc_key(doc), v.st)
            for each p in studio_overlays.conflicts(v.st, studio_overlays.for_branch(ov, b.id), -1)
                out = append(out, { branch: b.id, name: b.name, section_id: p.section_id,
                                    why: p.why, detail: p.detail })
            end for
        end for
        return { app: app, problems: out }
    end function

    ' The selected chain's bindings, as splice insertions for materialize_text:
    ' each at the LINE START of its branch point's section, so the assignments run
    ' immediately before the code that is allowed to diverge.
    '
    ' Everything above a branch point is shared ancestry — so a binding placed at
    ' the point cannot affect it, which is the model holding rather than a
    ' convention being observed.
    function branch_inserts(app)
        v = studio_ui.view_for(app)
        app = v.app
        if v.st = nothing then
            return { app: app, inserts: [], chain: [] }
        end if
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, inserts: [], chain: [] }
        end if
        tree = studio_ui.branch_tree(app)
        chain = studio_branches.selected_chain(tree, studio_ui.doc_key(doc), v.st)
        inserts = []
        for each b in chain
            text = studio_branches.bindings_text(b)
            if text != "" then
                sec = studio_sections.section_by_id(v.st, b.point)
                if sec != nothing then
                    off = studio_session._line_start(doc.content, sec.start_offset)
                    inserts = append(inserts, { offset: off, text: text })
                end if
            end if
        end for
        return { app: app, inserts: inserts, chain: chain }
    end function

    ' Which branch a run belongs to — the innermost selected one, or "" for the
    ' baseline. A result records it so siblings do not share one history.
    function active_branch(app)
        bi = studio_ui.branch_inserts(app)
        n = count(bi.chain)
        if n = 0 then
            return { app: bi.app, id: "", name: "" }
        end if
        b = bi.chain[n - 1]
        return { app: bi.app, id: b.id, name: b.name }
    end function

    ' ---- the inline selector's row model (§9.1) -----------------------------
    '
    ' Mutually-exclusive inline buttons at the branch point, exactly one selected,
    ' plus a "+" to make another. Derived ONCE like the browser's rows, and both
    ' the renderer and the click dispatcher consume the same array — a second,
    ' independently-derived list would drift the moment a branch was added
    ' between a render and a click.
    '
    ' The BASELINE is always first and always present: it is the document as
    ' written, with no bindings, and it is what a point falls back to. Without a
    ' row for it there would be no way back from a branch.
    function branch_rows(app)
        v = studio_ui.view_for(app)
        app = v.app
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, rows: [], point: "" }
        end if
        if v.sid = "" then
            return { app: app, rows: [], point: "" }
        end if
        tree = studio_ui.branch_tree(app)
        sel = studio_branches.selected_at(tree, v.sid)
        rows = []
        ov = studio_ui.overlays(app)
        rows = append(rows, { kind: "baseline", id: "", label: "Baseline",
                              selected: sel = "", stale: false,
                              overlay: 0, conflicts: 0 })
        for each b in studio_branches.at_point(tree, studio_ui.doc_key(doc), v.sid)
            ' STU-9: a code-overlay branch is VISIBLY MARKED experimental (§9.2),
            ' and its unresolved conflicts are marked beside it (§9.3). Both are
            ' counted from the edits themselves rather than stored, so a branch
            ' cannot claim a kind its contents do not have.
            edits = studio_overlays.for_branch(ov, b.id)
            rows = append(rows, { kind: "branch", id: b.id, label: b.name,
                                  selected: sel = b.id,
                                  stale: studio_branches.is_stale(tree, b, v.st),
                                  overlay: count(edits),
                                  conflicts: count(studio_overlays.conflicts(v.st, edits, -1)) })
        end for
        rows = append(rows, { kind: "add", id: "", label: "+", selected: false, stale: false,
                              overlay: 0, conflicts: 0 })
        return { app: app, rows: rows, point: v.sid }
    end function

    ' Click row `index` of what was rendered. `name` is the header field, which
    ' names a new branch the way it names a new file.
    function activate_branch_row(app, rows, index, name)
        if index < 0 then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        if index >= count(rows) then
            return { app: app, action: "out-of-range", detail: "" }
        end if
        br = studio_ui.branch_rows(app)
        app = br.app
        point = br.point
        if point = "" then
            return { app: app, action: "no-section", detail: "" }
        end if
        row = rows[index]
        tree = studio_ui.branch_tree(app)
        if row.kind = "baseline" then
            tree = studio_branches.clear_point(tree, point)
            return { app: studio_ui.set_branch_tree(app, tree), action: "baseline", detail: point }
        end if
        if row.kind = "add" then
            doc = studio_docs.active_doc(app.dm)
            v = studio_ui.view_for(app)
            app = v.app
            nm = trim(name)
            if nm = "" then
                nm = "Branch " + (count(studio_branches.at_point(tree, studio_ui.doc_key(doc), point)) + 1)
            end if
            ' A new branch nests under whatever is selected ABOVE this point, so
            ' making one inside a branch keeps it inside that branch.
            parent = ""
            chain = studio_branches.selected_chain(tree, studio_ui.doc_key(doc), v.st)
            for each c in chain
                if c.point != point then
                    parent = c.id
                end if
            end for
            a = studio_branches.add(tree, studio_ui.doc_key(doc), point, nm, parent, v.st)
            tree = studio_branches.select(a.tree, a.id).tree
            return { app: studio_ui.set_branch_tree(app, tree), action: "branched", detail: a.id + " " + nm }
        end if
        tree = studio_branches.select(tree, row.id).tree
        return { app: studio_ui.set_branch_tree(app, tree), action: "on-branch", detail: row.id }
    end function

    ' Bind the header field's `name = value` onto the selected branch. The field
    ' carries both because a binding IS a name and a value, and a second field
    ' would be a second thing to explain.
    function bind_selected(app, text)
        br = studio_ui.branch_rows(app)
        app = br.app
        if br.point = "" then
            return { app: app, action: "no-section", detail: "" }
        end if
        tree = studio_ui.branch_tree(app)
        id = studio_branches.selected_at(tree, br.point)
        if id = "" then
            return { app: app, action: "no-branch", detail: "" }
        end if
        eq = find(text, "=")
        if eq = nothing then
            return { app: app, action: "invalid", detail: "write it as name = value" }
        end if
        nm = trim(mid(text, 0, eq))
        val = trim(mid(text, eq + 1, len(text) - eq - 1))
        r = studio_branches.bind(tree, id, nm, val)
        if r.action != "bound" then
            return { app: app, action: r.action, detail: r.detail }
        end if
        return { app: studio_ui.set_branch_tree(app, r.tree), action: "bound", detail: nm + " = " + val }
    end function

    ' One line naming the selected branch, for the strip.
    ' The experimental marking, in one place so the selector, the run strip and
    ' the goldens cannot word it differently. A branch carrying code is not just
    ' another branch — it is running something that is not in your file, and the
    ' design requires that to be visible rather than inferable (§9.2).
    function overlay_mark(r)
        if r.overlay = 0 then
            return ""
        end if
        mark = " [experimental: " + r.overlay + " section(s)]"
        if r.conflicts > 0 then
            mark = mark + " [" + r.conflicts + " conflict(s)]"
        end if
        return mark
    end function

    function branch_label(app)
        br = studio_ui.branch_rows(app)
        app = br.app
        if br.point = "" then
            return "branch: (none)"
        end if
        for each r in br.rows
            if r.selected then
                if r.kind = "baseline" then
                    return "branch: baseline"
                end if
                line = "branch: " + r.label + studio_ui.overlay_mark(r)
                if r.stale then
                    line = line + " [ancestry changed]"
                end if
                return line
            end if
        end for
        return "branch: baseline"
    end function

    ' Start a run for the active document's section at (line0, column0).
    '
    ' The position arrives in the EDITOR's units — GtkSourceView counts lines and
    ' columns from 0, the section engine counts from 1 — and the conversion lives
    ' here rather than in the handler, so it is a tested line rather than a thing
    ' someone has to remember at the widget boundary.
    '
    ' Returns { app, action, detail, active }, action one of:
    '   "running"    — the child is up; the caller should start polling
    '   "refused"    — Studio declined (an ambiguous or unparseable section)
    '   "failed"     — materialize or launch failed
    '   "busy"       — a run is already in flight; stop it first
    '   "none"       — no document open
    '   "no-section" — the cursor is not inside anything runnable
    '   "no-parse"   — there are no sections because the file does not parse,
    '                  which is a different fact and a different fix
    '   "not-gbasic" — a supporting file (README, JSON, Makefile). Studio opens
    '                  these on purpose; it cannot run them
    function run_section(app, line0, column0)
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "none", detail: "", active: false }
        end if
        ex = app["exec"]
        if ex != unknown then
            if ex != nothing then
                busy = studio_session.is_active(ex.session)
                if busy then
                    return { app: app, action: "busy", detail: ex.session.state, active: false }
                end if
            end if
        end if

        ' The SAME section state the panes are showing, not a fresh derivation.
        ' Two derivations of one document can disagree about which section is
        ' which after an edit, and a run recorded against an id the pane does not
        ' use is a result nobody can find.
        vw = studio_ui.view_for(app)
        app = vw.app
        st = vw.st
        ' Before anything is derived from it: a supporting file has no sections
        ' to run, and saying so by its NAME is the difference between a refusal
        ' and a puzzle.
        gb = studio_ui.is_gbasic(doc.path)
        if not gb then
            return { app: app, action: "not-gbasic", detail: doc.path, active: false }
        end if
        sid = studio_ui.section_for(st, doc.content, line0 + 1, column0 + 1)
        if sid = "" then
            ' "the cursor is not inside a runnable section" is TRUE and useless
            ' when the reason there are no sections is that the file does not
            ' parse: the cursor is plainly inside a function, and it is the
            ' PARSER that could not find one. Blaming the cursor sends the user
            ' to move it, which cannot help.
            parsed = studio_ui.parses(st)
            if not parsed then
                return { app: app, action: "no-parse",
                         detail: studio_ui.first_diagnostic(st), active: false }
            end if
            return { app: app, action: "no-section", detail: "", active: false }
        end if

        sess = studio_session.create(doc.id, app.paths.home + "/scratch")
        ' A project may say which gBASIC it is meant to run under. That is the
        ' one thing `.gstudio.json` carries that CHANGES what a run does, and it
        ' is why the file travels: a project pinned to 0.1.0-rc3 runs under
        ' rc3 on whoever's machine, rather than under whatever their shell
        ' happened to export. Read here rather than at launch because the answer
        ' is per PROJECT and a window holds several.
        pin = studio_projfile.read_spec(studio_ui.project_path_for(app, doc))
        if pin.interpreter != "" then
            sess.interpreter = pin.interpreter
        end if
        if pin.gbasic_path != "" then
            ' REPLACES GBASIC_PATH rather than prepending to it. A pin that the
            ' ambient environment could still reach around is not a pin, and
            ' the child would otherwise inherit Studio's own `lib:` — this
            ' repository's libraries, on the search path of the user's program.
            sess.env = { GBASIC_PATH: pin.gbasic_path }
        end if
        ' The same test seam the headless session cases use: with the clock pinned,
        ' a result's timestamps are reproducible and a golden can hold them.
        fixed = app["clock_fixed"]
        if fixed != unknown then
            sess.clock_fixed = fixed
        end if
        ' STU-7: the selected chain's bindings go into the materialized prefix.
        bi = studio_ui.branch_inserts(app)
        app = bi.app
        sess.binds = bi.inserts
        ab0 = studio_ui.active_branch(app)
        app = ab0.app
        sess.branch = ab0.id
        ' STU-8: the recognition table the variable epilogue is compiled against.
        ' It is derived from the registry, so a run only pays for the deeper
        ' capture when some library actually registered a viewer.
        sess.detail_rules = studio_viewers.capture_rules(studio_ui.viewers_of(app))
        ' STU-8: if this run was asked for by a table fetch, it also writes that
        ' variable's rows out. Set on the app rather than passed in, because the
        ' run is started through the SAME function the Run button uses — one run
        ' path, so an export can never be taken by a run that differs from the
        ' one the user sees results from.
        tf = app["table_fetch"]
        if tf != unknown then
            if tf != nothing then
                sess.table = { name: tf.name, path: tf.path, cap: studio_table.export_cap(), chunk: studio_table.export_chunk(), stamp: tf.stamp }
            end if
        end if
        ' STU-9: an overlay branch runs its PROJECTION, not the file. The canonical
        ' document is never written and never re-read here — the projection is a
        ' value, and the only thing that reaches a disk is the temp materialization
        ' the run pipeline already writes for every run.
        bs = studio_ui.branch_sections(app)
        app = bs.app
        run_st = bs.st
        run_src = bs.src
        if bs.overlaid then
            if studio_sections.section_by_id(run_st, sid) = nothing then
                ' The section the caret is in does not survive this branch's
                ' overlay. Running "the nearest thing" would run different code
                ' under the id the results are filed against.
                return { app: app, action: "refused", detail: "this branch's overlay replaces the section at the cursor with something that is not a section any more", active: false }
            end if
        end if
        sess = studio_session.run(sess, run_st, run_src, sid)

        ab = studio_ui.active_branch(app)
        app = ab.app
        app.exec = { doc_id: doc.id, doc_path: doc.path, sid: sid, secs: run_st,
                     branch: ab.id, branch_name: ab.name,
                     src: run_src, session: sess,
                     store: studio_results.open(app.paths.home, doc.path) }
        act = sess.state
        detail = sid
        if sess.state = "refused" then
            detail = sess.message
        end if
        if sess.state = "failed" then
            detail = sess.message
        end if
        active = studio_session.is_active(sess)
        return { app: app, action: act, detail: detail, active: active }
    end function

    ' Advance an in-flight run one step. The caller polls this on a timer and stops
    ' when `active` comes back false.
    '
    ' The run becoming a durable RESULT happens here, on the one tick that sees it
    ' end — not in the handler, and not on a later redraw, because "the run
    ' finished" happens exactly once and recording it twice would be two rows in
    ' the history for one execution.
    function tick_run(app)
        ex = app["exec"]
        if ex = unknown then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        if ex = nothing then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        ex.session = studio_session.tick(ex.session)
        still = studio_session.is_active(ex.session)
        if still then
            app.exec = ex
            return { app: app, action: "running", detail: ex.sid, active: true }
        end if
        ex.session = studio_session.finalize(ex.session, ex.secs, ex.src)
        home = app.paths.home
        ex.store = studio_results.add_result(home, ex.store, studio_session.to_result(ex.session, ex.secs))
        save_result = studio_results.save(home, ex.store)
        app.exec = ex
        ' The panes read through app.view's cached store, and that store has just
        ' gained a result. Handing over the one we already have in memory beats
        ' re-reading the file we only just wrote.
        v = app["view"]
        if v != unknown then
            if v != nothing then
                if v.doc_path = ex.doc_path then
                    v.store = ex.store
                    app.view = v
                end if
            end if
        end if
        return { app: app, action: "ran", detail: ex.sid + " " + ex.session.state, active: false }
    end function

    ' Ask the child to stop (SIGTERM). It may not go; polling continues either way
    ' and `unresponsive` is a state the strip shows rather than hides.
    function stop_run(app)
        ex = app["exec"]
        if ex = unknown then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        if ex = nothing then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        running = studio_session.is_active(ex.session)
        if running = false then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        ex.session = studio_session.request_stop(ex.session)
        app.exec = ex
        return { app: app, action: "stopping", detail: ex.sid, active: studio_session.is_active(ex.session) }
    end function

    ' Stop it and do not take no for an answer.
    function force_stop_run(app)
        ex = app["exec"]
        if ex = unknown then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        if ex = nothing then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        running = studio_session.is_active(ex.session)
        if running = false then
            return { app: app, action: "idle", detail: "", active: false }
        end if
        ex.session = studio_session.force_stop(ex.session, studio_ui.force_grace())
        app.exec = ex
        return { app: app, action: "forced", detail: ex.sid, active: studio_session.is_active(ex.session) }
    end function

    ' ---- what the run strip and its panes show ------------------------------
    '
    ' These moved out of studio_shell, where they were pure functions the headless
    ' suite could not reach because the file loads GTK. They are the only feedback
    ' a run gives, so they belong where they can be asserted; studio_shell keeps
    ' the old names as one-line delegates, and the STU-4/5A display goldens do not
    ' move.

    ' One line of session state for the strip: what is happening, to which section,
    ' and — when Studio refused or the child is gone — why.
    function run_line(session)
        if session = nothing then
            return "run: (no session)"
        end if
        line = "run: " + session.state
        if session.section_id != "" then
            line = line + " [" + session.section_id + "]"
        end if
        if session.state = "refused" then
            return line + " — " + session.message
        end if
        if session.state = "failed" then
            return line + " — " + session.message
        end if
        if session.state = "finished" then
            if session.signal != 0 then
                return line + " — killed by signal " + session.signal
            end if
            return line + " — exit " + session.exit_code
        end if
        return line
    end function

    ' Prefix output is ALWAYS shown, never folded away: it is the only way a user
    ' can see that the replay re-issued the prefix's side effects.
    '
    ' While a run is in flight the split is not yet decided, so BOTH panes show the
    ' raw stream under the prefix heading rather than guessing at a boundary that
    ' may not have been printed yet.
    function prefix_text(session)
        if session = nothing then
            return "(none)"
        end if
        if session.split_out = "pending" then
            if session.out_raw = "" then
                return "(running — no output yet)"
            end if
            return session.out_raw
        end if
        if session.split_out = "combined" then
            if session.out_prefix = "" then
                return "(none — sections 1..N combined)"
            end if
            return session.out_prefix
        end if
        if session.out_prefix = "" then
            return "(none)"
        end if
        return session.out_prefix
    end function

    function target_text(session)
        if session = nothing then
            return "(none)"
        end if
        if session.split_out = "pending" then
            return "(running — not separated yet)"
        end if
        if session.split_out = "combined" then
            return "(not separable from the prefix in this run)"
        end if
        if session.out_target = "" then
            return "(none)"
        end if
        return session.out_target
    end function

    ' The session behind the strip, or nothing when nothing has run.
    function exec_session(app)
        ex = app["exec"]
        if ex = unknown then
            return nothing
        end if
        if ex = nothing then
            return nothing
        end if
        return ex.session
    end function

    ' ---- what the panes are looking at (STU-5A′) ----------------------------
    '
    ' Until now the results pane followed the section that last RAN, which is
    ' wrong in the ordinary case: you run something, read the result, move the
    ' caret to the next section — and the pane still describes the previous one.
    ' Section ids are stable across edits precisely so a pane can be keyed to
    ' where you ARE, so that is what it is keyed to now.
    '
    ' The cost is that the panes need a section model for the active document
    ' continuously, not just at Run. `app.view` is that, cached: re-deriving the
    ' outline is not free, and the cursor moves on every keystroke.
    '
    '   app.view = { doc_id, src, st, doc_path, store }
    '
    ' Invalidated by content (a new outline) and by path (a different results
    ' file) independently, because typing changes one and switching tabs the
    ' other.
    function view_for(app)
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, st: nothing, sid: "", store: nothing }
        end if
        v = app["view"]
        if v = unknown then
            v = { doc_id: "", src: "", st: nothing, doc_path: "", store: nothing }
        end if
        if v = nothing then
            v = { doc_id: "", src: "", st: nothing, doc_path: "", store: nothing }
        end if
        ' Both conditions, explicitly. Marking the cache stale by blanking `src`
        ' silently fails for an EMPTY document, whose content is already "" — and
        ' the pane then describes the file you were looking at before.
        stale = false
        if v.doc_id != doc.id then
            stale = true
        end if
        if v.src != doc.content then
            stale = true
        end if
        if v.st = nothing then
            stale = true
        end if
        if stale then
            ' REFRESH the existing state; do not build a new one. Section ids are
            ' stable across edits because `refresh` re-matches the old sections
            ' against the new outline — that is the whole of STU-3. Deriving from
            ' scratch each time would re-mint ids in file order, so inserting a
            ' section at the top would silently renumber every result recorded
            ' against the ones below it.
            '
            ' It also makes `revision` mean something: a state created fresh every
            ' call is forever at revision 1, and anything using it as a change
            ' signal (the editor's gutter marks) would never see a change.
            ws = app.model.workspace
            fresh = false
            if v.st = nothing then
                fresh = true
            end if
            if v.doc_id != doc.id then
                fresh = true
            end if
            if fresh then
                ' RESTORE rather than create. Ids are minted from a per-document
                ' counter that advances as sections are re-matched across edits,
                ' so a document edited in one session ends up with ids like sec-5
                ' — and a state built from scratch next time numbers its sections
                ' sec-1..N again. Every result recorded under the old ids would
                ' then belong to no section that exists, and a document's whole
                ' history would quietly disappear on restart.
                '
                ' STU-3 built the anchors to survive exactly this; nothing had
                ' been calling them.
                psr = studio_ui.project_state(app)
                app = psr.app
                v.st = studio_sections.restore_from(psr.state.sections, studio_ui.doc_key(doc))
            end if
            ' ONLY gBASIC is parsed. A supporting file has no outline to
            ' derive, and handing one to `source_outline` does not produce
            ' "nothing" — it produces a failed parse, which the strip, the
            ' errors pane and the gutter all then report as a broken program.
            ' Skipping the refresh leaves the state valid and empty, which is
            ' the truth: no sections, and no complaint about that.
            if studio_ui.is_gbasic(doc.path) then
                v.st = studio_sections.refresh(v.st, doc.content)
            end if
            v.src = doc.content
            v.doc_id = doc.id
            ' Fold the state back into the workspace as it changes, so whatever
            ' the shutdown pipeline writes already has it. Waiting until exit
            ' would mean only the last document looked at kept its ids.
            psw = studio_ui.project_state(app)
            app = psw.app
            pst = psw.state
            pst.sections = studio_sections.persist_into(pst.sections, v.st)
            app = studio_ui.set_project_state(app, pst)
        end if
        if v.doc_path != doc.path then
            v.store = studio_results.open(app.paths.home, doc.path)
            v.doc_path = doc.path
        end if
        cur = doc.cursor
        sid = studio_ui.section_for(v.st, doc.content, cur.line, cur.column)
        app.view = v
        return { app: app, st: v.st, sid: sid, store: v.store }
    end function

    ' Record where the caret is. The position arrives in the EDITOR's 0-based
    ' units and is stored 1-based, which is what the section engine and the
    ' persisted document both use — so this conversion happens once, here.
    '
    ' Storing it in the document is not incidental: the cursor is already part of
    ' what a workspace saves, so following the caret also means a reopened file
    ' comes back to the section you left it in.
    function sync_cursor(app, doc_id, line0, column0)
        doc = studio_docs.doc_by_id(app.dm, doc_id)
        if doc = nothing then
            return { app: app, action: "unknown", detail: doc_id, changed: false }
        end if
        ' What section the caret was in before, so the caller can tell a move
        ' WITHIN a section from a move between them. The history records the
        ' second and would drown in the first — this fires on every arrow key.
        was = studio_ui.view_for(app)
        app = was.app
        app.dm = studio_docs.set_cursor(app.dm, doc_id, line0 + 1, column0 + 1)
        v = studio_ui.view_for(app)
        return { app: v.app, action: "cursor", detail: v.sid, changed: v.sid != was.sid }
    end function

    ' The section the caret is in, for the strip — so it is visible WHICH section
    ' Run would run before you press it, rather than after.
    function section_label(app)
        v = studio_ui.view_for(app)
        if v.sid = "" then
            ' Three different facts, which the strip used to report as one.
            ' "(none)" over a screen full of functions reads as Studio having
            ' lost them; over a README it reads as a README being an empty
            ' program.
            doc = studio_docs.active_doc(app.dm)
            if doc != nothing then
                gb = studio_ui.is_gbasic(doc.path)
                if not gb then
                    return "section: (not a gBASIC file)"
                end if
            end if
            parsed = studio_ui.parses(v.st)
            if not parsed then
                return "section: (this file does not parse)"
            end if
            return "section: (none)"
        end if
        sec = studio_sections.section_by_id(v.st, v.sid)
        if sec = nothing then
            return "section: " + v.sid
        end if
        line = "section: " + v.sid + " " + sec.kind
        ' A statements section has no name at all, and `nothing` renders as the
        ' word "nothing" if it is concatenated.
        if sec.name != nothing then
            if sec.name != "" then
                line = line + " " + sec.name
            end if
        end if
        return line
    end function

    ' ---- what the editor should draw (STU-5) --------------------------------
    '
    ' Sections have been invisible in the source since STU-3 derived them: the
    ' strip names the one at the caret, and nothing in the code shows where it
    ' starts or ends. Both of these are decisions about WHICH lines, in editor
    ' units; the shell does the drawing.
    '
    ' `revision` comes back so the caller can tell whether the marks it drew are
    ' still the right ones. The outline changes on edits, not on caret moves, and
    ' re-marking a document sixteen times a second while someone types would be
    ' the same mistake as rebuilding the browser pane on every keystroke.
    function section_marks(app)
        v = studio_ui.view_for(app)
        app = v.app
        doc = studio_docs.active_doc(app.dm)
        id = ""
        if doc != nothing then
            id = doc.id
        end if
        lines = []
        rev = -1
        if v.st != nothing then
            rev = v.st.revision
            for each s in v.st.sections
                if s.status != "stale" then
                    lines = append(lines, s.start_line - 1)
                end if
            end for
        end if
        return { app: app, lines: lines, revision: rev, doc_id: id }
    end function

    ' The same idea, for the PARSER: where the syntax error is, in editor units.
    '
    ' Keyed by a SIGNATURE rather than by the outline's revision, which is what
    ' `section_marks` hands back. `studio_sections._apply` advances `revision`
    ' only on a SUCCESSFUL parse, so a revision-keyed cache would never redraw a
    ' mark that exists precisely BECAUSE the parse failed — the marks would
    ' appear once, at whatever revision was current, and then never move again
    ' however the error moved.
    function error_marks(app)
        v = studio_ui.view_for(app)
        app = v.app
        doc = studio_docs.active_doc(app.dm)
        id = ""
        if doc != nothing then
            id = doc.id
        end if
        lines = []
        parsed = studio_ui.parses(v.st)
        if not parsed then
            for each d in v.st.diagnostics
                ' The parser counts lines from 1; a text buffer counts from 0.
                ln = d.start_line - 1
                if ln >= 0 then
                    lines = append(lines, ln)
                end if
            end for
        end if
        return { app: app, lines: lines, doc_id: id,
                 signature: studio_ui.mark_signature(lines) }
    end function

    ' What has to change before the marks are redrawn. The LINES, not their
    ' count: two different one-line errors share a count, and the mark would sit
    ' on the line the user had just fixed while the real one went unmarked.
    function mark_signature(lines)
        out = []
        for each ln in lines
            out = append(out, string(ln))
        end for
        return join(out, ",")
    end function

    ' The 0-based line range of the section at the caret — what Run would run,
    ' shown as an extent in the code rather than only as an id in the strip.
    function current_range(app)
        v = studio_ui.view_for(app)
        app = v.app
        if v.sid = "" then
            return { app: app, ok: false, start0: 0, end0: 0 }
        end if
        sec = studio_sections.section_by_id(v.st, v.sid)
        if sec = nothing then
            return { app: app, ok: false, start0: 0, end0: 0 }
        end if
        return { app: app, ok: true, start0: sec.start_line - 1, end0: sec.end_line - 1 }
    end function

    ' ---- the output panes, per section (STU-5) ------------------------------
    '
    ' The output panes used to show the live session and only the live session,
    ' so they described whatever last ran no matter where the caret was — the
    ' same inconsistency the results pane had before STU-5A′. Output is per
    ' SECTION: move the caret and the panes swap with it.
    '
    ' A run in flight is the exception, and only for its own section: while the
    ' child is producing output there is no stored result yet, and the live stream
    ' is the only thing there is to show. Put the caret somewhere else during a
    ' run and you see that section's last result, which is correct — the run
    ' happening elsewhere is not what you are looking at.
    function output_source(app)
        v = studio_ui.view_for(app)
        sess = studio_ui.exec_session(app)
        if sess != nothing then
            if sess.section_id = v.sid then
                live = studio_session.is_active(sess)
                if live then
                    return { app: v.app, kind: "live", session: sess, result: nothing, store: v.store }
                end if
                ' A run that ENDED BEFORE IT BEGAN. `refused` and `failed` both
                ' return from `run_section` with `active` false, so `tick_run` is
                ' never polled and `add_result` is never reached — there is no
                ' stored result for these, and there should not be: nothing
                ' executed, so there is nothing to file under this section's
                ' history.
                '
                ' But that left their message with exactly ONE home, the run
                ' strip, which is a single row that ellipsizes. The pane whose
                ' whole job is to say what went wrong answered "(none)" about a
                ' run Studio had just declined — the same "a pane asserting there
                ' was no error" failure this pane's own comment was written
                ' against, arrived at from the other direction.
                if studio_ui.fault_text(sess) != "" then
                    return { app: v.app, kind: "fault", session: sess, result: nothing, store: v.store }
                end if
            end if
        end if
        if v.store = nothing then
            return { app: v.app, kind: "none", session: nothing, result: nothing, store: nothing }
        end if
        if v.sid = "" then
            return { app: v.app, kind: "none", session: nothing, result: nothing, store: nothing }
        end if
        ab = studio_ui.active_branch(v.app)
        latest = studio_results.latest_in(v.store, v.sid, ab.id)
        if latest = nothing then
            return { app: ab.app, kind: "none", session: nothing, result: nothing, store: v.store }
        end if
        return { app: ab.app, kind: "stored", session: nothing, result: latest, store: v.store }
    end function

    ' What a refused or failed run says, or "" for anything else. A closed set:
    ' these are the only two states that carry a message no result will ever
    ' hold, and `state` is named in the text because the strip that used to be
    ' the only place this appeared said it too.
    function fault_text(session)
        if session = nothing then
            return ""
        end if
        if session.message = "" then
            return ""
        end if
        if session.state = "refused" then
            return "refused: " + session.message
        end if
        if session.state = "failed" then
            return "failed: " + session.message
        end if
        return ""
    end function

    ' What the prefix pane shows for the section at the caret.
    function prefix_body(app)
        o = studio_ui.output_source(app)
        if o.kind = "live" then
            return studio_ui.prefix_text(o.session)
        end if
        if o.kind = "fault" then
            return "(the run did not start)"
        end if
        if o.kind = "none" then
            return "(this section has not run)"
        end if
        return studio_ui._capture_or(app, o, "out_prefix", "(none)")
    end function

    function target_body(app)
        o = studio_ui.output_source(app)
        if o.kind = "live" then
            return studio_ui.target_text(o.session)
        end if
        ' NOT the last stored run's output. A refusal produced none, and output
        ' from an earlier run displayed beside "refused:" reads as output of the
        ' run that was refused — which is the one thing these panes must never
        ' say. The result itself is still in the results pane, where it is dated.
        if o.kind = "fault" then
            return "(the run did not start)"
        end if
        if o.kind = "none" then
            return "(this section has not run)"
        end if
        return studio_ui._capture_or(app, o, "out_target", "(none)")
    end function

    ' Errors were never shown at all before STU-5: a section that failed printed
    ' its diagnosis to stderr and the window put it nowhere.
    ' What went wrong, for the section at the caret.
    '
    ' The ATTRIBUTED DIAGNOSTICS come first and are the reason this is not just
    ' the stderr capture. A gBASIC child reports an error as a structured JSON
    ' line, which studio_session parses OUT of stderr into `attribution` — so for
    ' the most common failure there is, the raw capture is empty and a pane that
    ' showed only stderr said "(none)" about a run that had just failed. That is
    ' worse than having no pane: it is a pane asserting there was no error.
    function error_body(app)
        o = studio_ui.output_source(app)
        if o.kind = "live" then
            return "(running)"
        end if
        lines = []
        ' The refusal first, because it is the answer to the click that was just
        ' made. The whole sentence, in a pane that wraps and that a user can
        ' select and copy out of — the strip says the same thing in one line, and
        ' this is where the line goes when it does not fit in one.
        if o.kind = "fault" then
            lines = append(lines, studio_ui.fault_text(o.session))
        end if
        ' Then the PARSER, whatever any run said. While the document does not
        ' parse, nothing in it can run and the position of the syntax error is
        ' the only actionable thing in the window — and until now it was the one
        ' thing Studio knew and never said. "the document does not parse; fix
        ' the errors first" is a refusal without an address.
        for each pl in studio_ui.parse_lines(app)
            lines = append(lines, pl)
        end for
        if o.kind = "stored" then
            for each a in o.result.attribution
                where = a.where
                sid = ""
                if a.section_id != nothing then
                    sid = " [" + a.section_id + "]"
                end if
                lines = append(lines, where + sid + " " + a.line + ":" + a.column + "  " + a.message)
            end for
            pre = studio_ui._capture_or(app, o, "err_prefix", "")
            tgt = studio_ui._capture_or(app, o, "err_target", "")
            raw = pre + tgt
            if raw != "" then
                lines = append(lines, raw)
            end if
        end if
        if count(lines) = 0 then
            return "(none)"
        end if
        return join(lines, "\n")
    end function

    ' ---- what the PARSER said -----------------------------------------------
    '
    ' `studio_sections.refresh` has recorded these since STU-3 and nothing ever
    ' displayed them. The cost was not cosmetic: a file that does not parse
    ' yields no sections, so the strip says "section: (none)", Run answers "the
    ' cursor is not inside a runnable section" — which is true, and useless,
    ' because the cursor is plainly inside a function — and the one fact the
    ' window actually held, the LINE AND COLUMN of the syntax error, was thrown
    ' away on every keystroke.

    ' Whether the section state describes the text on screen.
    '
    ' Asked rather than inferred from the section list being empty: on a failed
    ' parse `_apply` KEEPS the last-known-good sections (it must — deleting a
    ' user's sections because they are mid-keystroke would renumber every result
    ' filed against them), so a document can fail to parse and still have a full
    ' list of sections. `valid` is the only thing that says so.
    function parses(st)
        if st = nothing then
            return true
        end if
        return st.valid
    end function

    ' What the parser said about the document at the caret, formatted for the
    ' errors pane. Empty when it parses, which is the normal case.
    function parse_lines(app)
        v = studio_ui.view_for(app)
        return studio_ui.diagnostic_lines(v.st)
    end function

    function diagnostic_lines(st)
        out = []
        ok = studio_ui.parses(st)
        if ok then
            return out
        end if
        for each d in st.diagnostics
            out = append(out, studio_ui.diagnostic_line(d))
        end for
        return out
    end function

    ' One diagnostic, in the shape the run attributions already use in this pane:
    ' where it is, then what is wrong. The severity leads because `source_outline`
    ' reports warnings through the same channel and a warning that reads like an
    ' error is how a pane loses its authority.
    function diagnostic_line(d)
        return d.severity + " " + d.start_line + ":" + d.start_column + "  " + d.message
    end function

    ' The first thing the parser complained about, for a one-line status. "" when
    ' the document parses.
    function first_diagnostic(st)
        for each l in studio_ui.diagnostic_lines(st)
            return l
        end for
        return ""
    end function

    ' The heading over the errors pane, given what the pane is about to show.
    '
    ' The pane is the THIRD of three stacked in the console scroller, so on a
    ' short window it is the one below the fold — and a heading that reads the
    ' same whether a run failed or not gives the eye no reason to go looking for
    ' it. The count is in the text (a golden can hold it); `error_fault` is what
    ' the colour is keyed to.
    '
    ' Counted in NON-EMPTY lines, because a raw stderr capture ends in a newline
    ' and a blank trailing line is not an error.
    function error_heading(body)
        n = studio_ui.error_count(body)
        if n = 0 then
            return "Errors"
        end if
        return "Errors (" + n + ")"
    end function

    ' How many things the errors pane is reporting. Zero for the two placeholders
    ' that mean "nothing to report" — they are sentences the pane writes about
    ' itself, not errors.
    function error_count(body)
        if body = "(none)" then
            return 0
        end if
        if body = "(running)" then
            return 0
        end if
        n = 0
        for each ln in split(body, "\n")
            if ln != "" then
                n = n + 1
            end if
        end for
        return n
    end function

    function _capture_or(app, o, name, empty)
        if studio_results.capture_bytes(o.result, name) = 0 then
            return empty
        end if
        return studio_results.capture(app.paths.home, o.store, o.result.result_id, name)
    end function

    ' The library-registered viewers this app carries. An app record built before
    ' STU-8 — every headless fixture that predates it — has no `viewers` slot, and
    ' answers an empty registry rather than raising: a missing viewer must degrade
    ' to the structural preview, which is what Studio showed before viewers
    ' existed.
    function viewers_of(app)
        if not has(app, "viewers") then
            return studio_viewers.create()
        end if
        if app.viewers = nothing then
            return studio_viewers.create()
        end if
        return app.viewers
    end function

    ' The results pane's body: the history for the section AT THE CURSOR, judged
    ' against the sections as they are now — so a result recorded before an edit
    ' is marked as describing text that has since changed.
    function results_body(app)
        v = studio_ui.view_for(app)
        if v.store = nothing then
            return "(no document open)"
        end if
        if v.sid = "" then
            return "(no section at the cursor)"
        end if
        ab = studio_ui.active_branch(v.app)
        app = ab.app
        ' STU-9: judged against the sections THIS BRANCH sees, so an overlay
        ' branch's results are not all marked stale by the overlay itself.
        bs = studio_ui.branch_sections(app)
        app = bs.app
        return studio_results.view_with(app.paths.home, v.store, bs.st, v.sid, ab.id, studio_ui.viewers_of(app))
    end function

    ' ---- STU-11: git, and staying quiet about it ----------------------------
    '
    ' §18: git is optional and VISUALLY QUIET when not needed. So the whole
    ' surface is one function that answers "is there anything to say", and the
    ' shell shows a pane only when there is.
    '
    ' The repository is detected from the ACTIVE PROJECT's root, not from
    ' Studio's home or the process's working directory: a workspace can hold
    ' projects in different repositories, or in none, and asking about the wrong
    ' one would report someone else's changes as this project's.
    function git_root(app)
        ws = app.model.workspace
        if ws = nothing then
            return ""
        end if
        for each p in ws.projects
            if p.id = ws.active_project then
                return p.path
            end if
        end for
        return ""
    end function

    ' Cached on the app, because detection SPAWNS A PROCESS and the panes are
    ' redrawn on every caret move. Without this, moving the cursor would fork
    ' `git rev-parse` at typing rate.
    '
    ' The cache is keyed on the project path alone and is NOT invalidated by
    ' edits: whether a directory is a repository does not change while someone
    ' types. The status inside it does, which is why `git_lines` re-reads that and
    ' only that.
    function git_state(app)
        root = studio_ui.git_root(app)
        if root = "" then
            return { app: app, state: "none", root: "", branch: "" }
        end if
        cached = app["gitstate"]
        if cached != unknown then
            if cached != nothing then
                if cached.path = root then
                    return { app: app, state: cached.state, root: cached.root, branch: cached.branch }
                end if
            end if
        end if
        d = studio_git.detect(root)
        app["gitstate"] = { path: root, state: d.state, root: d.root, branch: d.branch }
        return { app: app, state: d.state, root: d.root, branch: d.branch }
    end function

    ' Whether the window should show a git pane at all. False when git is not
    ' installed AND false when this project is not a repository — two different
    ' reasons for the same quiet, which is the point of §18.
    function git_engaged(app)
        g = studio_ui.git_state(app)
        return { app: g.app, engaged: g.state = "repo" }
    end function

    ' What the pane says. Read fresh every redraw: the status is exactly the
    ' thing that changes while someone works.
    function git_lines(app)
        g = studio_ui.git_state(app)
        app = g.app
        if g.state != "repo" then
            return { app: app, lines: [] }
        end if
        return { app: app, lines: studio_git.summary(g.root) }
    end function

    ' One line for the status bar. Quiet means QUIET: outside a repository this
    ' is the empty string, and the status bar shows nothing rather than "git:
    ' none", which would be Studio mentioning git to someone who does not use it
    ' every time they clicked anything.
    function git_label(app)
        g = studio_ui.git_state(app)
        app = g.app
        if g.state != "repo" then
            return ""
        end if
        if g.branch = "" then
            return "git: no commits yet"
        end if
        return "git: " + g.branch
    end function

    ' ---- STU-9: the overlay interactions ------------------------------------
    '
    ' Five acts, each explicit (§9.2/§9.3): begin an overlay on the section at the
    ' caret, save what was typed into it, discard it, promote it into the file, or
    ' rebase it onto changed canonical text.

    ' Begin editing this branch's copy of the section at the caret. The overlay
    ' starts as the canonical text — an experiment starts from what is there, not
    ' from an empty buffer — and `base_fp` is stamped NOW, which is the whole
    ' basis of every conflict answer later.
    '
    ' The baseline cannot carry an overlay: the baseline IS the file, and an
    ' overlay on it would be an edit pretending not to be one.
    function begin_overlay(app)
        v = studio_ui.view_for(app)
        app = v.app
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "no-doc", detail: "", text: "" }
        end if
        if v.sid = "" then
            return { app: app, action: "no-section", detail: "", text: "" }
        end if
        ab = studio_ui.active_branch(app)
        app = ab.app
        if ab.id = "" then
            return { app: app, action: "refused", detail: "the baseline is the file itself — make a branch to experiment on", text: "" }
        end if
        pt = studio_branches.by_id(studio_ui.branch_tree(app), ab.id)
        if pt != nothing then
            sec = studio_sections.section_by_id(v.st, v.sid)
            if sec != nothing then
                point = studio_sections.section_by_id(v.st, pt.point)
                if point != nothing then
                    if sec.start_offset < point.end_offset then
                        return { app: app, action: "refused", detail: "an overlay changes only what is BELOW the branch point", text: "" }
                    end if
                end if
            end if
        end if
        text = studio_overlays.canonical_text(doc.content, v.st, v.sid)
        ov = studio_ui.overlays(app)
        existing = studio_overlays.edit_for(ov, ab.id, v.sid)
        if existing != nothing then
            return { app: app, action: "overlay-open", detail: v.sid, text: existing.text }
        end if
        ov = studio_overlays.put(ov, ab.id, v.sid, studio_overlays.base_fp(v.st, v.sid), text)
        app = studio_ui.set_overlays(app, ov)
        return { app: app, action: "overlay-began", detail: v.sid, text: text }
    end function

    ' Save typed text into this branch's overlay for the section at the caret.
    ' `base_fp` is NOT re-stamped: it records what the overlay was written
    ' against, and moving it here would quietly resolve a conflict the user has
    ' not been told about.
    function save_overlay(app, text)
        v = studio_ui.view_for(app)
        app = v.app
        if v.sid = "" then
            return { app: app, action: "no-section", detail: "" }
        end if
        ab = studio_ui.active_branch(app)
        app = ab.app
        if ab.id = "" then
            return { app: app, action: "refused", detail: "the baseline is the file itself" }
        end if
        ov = studio_ui.overlays(app)
        existing = studio_overlays.edit_for(ov, ab.id, v.sid)
        fp = studio_overlays.base_fp(v.st, v.sid)
        if existing != nothing then
            fp = existing.base_fp
        end if
        ov = studio_overlays.put(ov, ab.id, v.sid, fp, text)
        app = studio_ui.set_overlays(app, ov)
        return { app: app, action: "overlay-saved", detail: v.sid }
    end function

    function discard_overlay(app)
        v = studio_ui.view_for(app)
        app = v.app
        ab = studio_ui.active_branch(app)
        app = ab.app
        if ab.id = "" then
            return { app: app, action: "refused", detail: "the baseline has no overlay" }
        end if
        ov = studio_ui.overlays(app)
        if v.sid = "" then
            return { app: app, action: "no-section", detail: "" }
        end if
        if studio_overlays.edit_for(ov, ab.id, v.sid) = nothing then
            return { app: app, action: "refused", detail: "no overlay on this section" }
        end if
        ov = studio_overlays.drop(ov, ab.id, v.sid)
        app = studio_ui.set_overlays(app, ov)
        return { app: app, action: "overlay-discarded", detail: v.sid }
    end function

    ' Promote: write the overlay into the canonical document. From here on it is an
    ' ordinary working-tree edit — the thing Git can see (§18) — and the overlay is
    ' gone from metadata, because leaving it would leave a second copy of text that
    ' is now simply the file.
    '
    ' The document is marked DIRTY rather than written to disk. Promote is an edit,
    ' and Studio's rule for edits is that the user saves them; a promote that wrote
    ' through to the file would be the one action in the window that bypasses Save.
    function promote_overlay(app)
        v = studio_ui.view_for(app)
        app = v.app
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "no-doc", detail: "" }
        end if
        ab = studio_ui.active_branch(app)
        app = ab.app
        if ab.id = "" then
            return { app: app, action: "refused", detail: "the baseline has no overlay to promote" }
        end if
        ov = studio_ui.overlays(app)
        edits = studio_overlays.for_branch(ov, ab.id)
        r = studio_overlays.promote(doc.content, v.st, edits, -1)
        if not r.ok then
            if r.why = "empty" then
                return { app: app, action: "refused", detail: "this branch has no overlay" }
            end if
            return { app: app, action: "refused", detail: count(r.problems) + " conflict(s) — rebase or discard first" }
        end if
        app.dm = studio_docs.edit(app.dm, doc.id, r.text)
        ov = studio_overlays.drop_branch(ov, ab.id)
        app = studio_ui.set_overlays(app, ov)
        app["bview"] = nothing
        return { app: app, action: "overlay-promoted", detail: count(edits) + " section(s) — unsaved, as any edit is" }
    end function

    ' Rebase: re-stamp this branch's overlay onto the canonical text as it is now.
    ' Not a merge, and it does not claim to be — an overlay is a whole section, so
    ' accepting it SHADOWS the canonical change. The detail says how many, and
    ' `overlay_diff` shows what.
    function rebase_overlay(app)
        v = studio_ui.view_for(app)
        app = v.app
        ab = studio_ui.active_branch(app)
        app = ab.app
        if ab.id = "" then
            return { app: app, action: "refused", detail: "the baseline has no overlay" }
        end if
        r = studio_overlays.rebase(studio_ui.overlays(app), ab.id, v.st)
        app = studio_ui.set_overlays(app, r.ov)
        app["bview"] = nothing
        if count(r.unresolved) > 0 then
            return { app: app, action: "overlay-rebased", detail: count(r.rebased) + " re-anchored, " + count(r.unresolved) + " cannot be — discard those" }
        end if
        if count(r.rebased) = 0 then
            return { app: app, action: "refused", detail: "nothing to rebase — the overlay already sits on the current text" }
        end if
        return { app: app, action: "overlay-rebased", detail: count(r.rebased) + " section(s) now shadow the current text" }
    end function

    ' Canonical against overlay, for the whole selected branch. This is the
    ' "compare" of §9.2, and it is what makes rebase honest: after re-stamping,
    ' this is where the canonical change that got shadowed is still visible.
    function overlay_diff(app)
        v = studio_ui.view_for(app)
        app = v.app
        doc = studio_docs.active_doc(app.dm)
        out = []
        if doc = nothing then
            return { app: app, lines: out }
        end if
        ab = studio_ui.active_branch(app)
        app = ab.app
        if ab.id = "" then
            out = append(out, "(the baseline is the file itself)")
            return { app: app, lines: out }
        end if
        edits = studio_overlays.for_branch(studio_ui.overlays(app), ab.id)
        if count(edits) = 0 then
            out = append(out, "(no overlay on " + ab.name + ")")
            return { app: app, lines: out }
        end if
        out = append(out, ab.name + " against the file:")
        for each e in edits
            for each l in studio_overlays.diff_lines(doc.content, v.st, e)
                out = append(out, l)
            end for
        end for
        return { app: app, lines: out }
    end function

    ' ---- STU-8: the tabular tier -------------------------------------------
    '
    ' Design §7 has Studio OFFER a view rather than assume one. These are the
    ' offers, the opening, and the fetch — all over plain data, so the window's
    ' part stays "read a row index, call one of these, ask for a redraw".

    ' What the latest result for the section at the caret can be opened as. One
    ' row per variable that has any affordance at all; a section whose variables
    ' are all scalars produces none, and the pane shows nothing rather than an
    ' empty table button.
    function table_rows(app)
        o = studio_ui.output_source(app)
        app = o.app
        rows = []
        if o.kind != "stored" then
            return { app: app, rows: rows }
        end if
        for each v in studio_results.vars_of(app.paths.home, o.store, o.result)
            t = studio_table.tier(v)
            if t != "none" then
                rows = append(rows, { name: v.name, tier: t, count: studio_table.row_count(v),
                                      label: studio_table.offer_line(v), var: v })
            end if
        end for
        return { app: app, rows: rows }
    end function

    ' Open one. An EXPORT is preferred over the capture sample whenever one
    ' exists, and the two are not interchangeable: the sample is fifty rows the
    ' run happened to keep, the export is the table. `caption` says which is on
    ' screen, always — the failure this guards against is a grid captioned with a
    ' number it cannot actually show.
    ' The stamp the CURRENT view expects an export to carry: the fingerprint of
    ' the section the result describes, and the branch it ran on.
    function table_stamp(app, o)
        v = studio_ui.view_for(app)
        app = v.app
        sec = studio_sections.section_by_id(v.st, o.result.section_id)
        fp = o.result.section_fingerprint
        if sec != nothing then
            fp = studio_results.fingerprint_of(sec)
        end if
        ab = studio_ui.active_branch(app)
        return { app: ab.app, stamp: studio_table.stamp_for(fp, ab.id) }
    end function

    function open_table(app, rows, index)
        if index < 0 then
            return { app: app, action: "no-table", detail: "", src: studio_table._empty_source(), caption: "" }
        end if
        if index >= count(rows) then
            return { app: app, action: "no-table", detail: "", src: studio_table._empty_source(), caption: "" }
        end if
        row = rows[index]
        doc = studio_docs.active_doc(app.dm)
        src = studio_table._empty_source()
        if doc != nothing then
            o = studio_ui.output_source(app)
            app = o.app
            if o.kind = "stored" then
                ts = studio_ui.table_stamp(app, o)
                app = ts.app
                src = studio_table.matching_export(app.paths.home, doc.path, row.name, ts.stamp)
            end if
        end if
        if src.kind = "none" then
            src = studio_table.from_preview(row.var)
        end if
        cap = studio_table.caption(row.name, src)
        return { app: app, action: "table", detail: cap, src: src, caption: cap }
    end function

    ' Fetch the whole thing. This RUNS THE SECTION AGAIN, and says so: under the
    ' replay model there is no other way to get data out of a run that has ended,
    ' and a button that silently re-executed someone's code would be a worse
    ' surprise than a slow one.
    '
    ' It is an ordinary run in every other respect — same section, same source,
    ' same branch bindings — with one extra epilogue that writes the variable out.
    ' That matters for correctness, not tidiness: an export taken from a
    ' differently-configured run would be a table of numbers that never coexisted.
    function fetch_table(app, rows, index)
        if index < 0 then
            return { app: app, action: "no-table", detail: "", active: false }
        end if
        if index >= count(rows) then
            return { app: app, action: "no-table", detail: "", active: false }
        end if
        row = rows[index]
        doc = studio_docs.active_doc(app.dm)
        if doc = nothing then
            return { app: app, action: "no-doc", detail: "", active: false }
        end if
        persist.ensure_dir(studio_table.tables_dir(app.paths.home))
        path = studio_table.export_path(app.paths.home, doc.path, row.name)
        ' The stamp is taken from the section as it is NOW, which is the same
        ' fingerprint the result this run is about to record will carry. Taking it
        ' from the old result instead would stamp the new export with the identity
        ' of the code it replaced.
        o = studio_ui.output_source(app)
        app = o.app
        stamp = ""
        if o.kind = "stored" then
            ts = studio_ui.table_stamp(app, o)
            app = ts.app
            stamp = ts.stamp
        end if
        app["table_fetch"] = { name: row.name, path: path, stamp: stamp }
        r = studio_ui.run_section(app, doc.cursor.line, doc.cursor.column)
        app = r.app
        app["table_fetch"] = nothing
        ' Any outcome in which the run actually STARTED reports as a fetch. It
        ' would be wrong to key this on "running": whether the child is still
        ' alive by the time the call returns is a race with how fast the section
        ' is, and a button whose reported action depends on that would say two
        ' different things about the same click.
        if r.action = "refused" then
            return { app: app, action: r.action, detail: r.detail, active: r.active }
        end if
        if r.action = "no-doc" then
            return { app: app, action: r.action, detail: r.detail, active: r.active }
        end if
        if r.action = "no-section" then
            return { app: app, action: r.action, detail: r.detail, active: r.active }
        end if
        if r.action = "no-parse" then
            return { app: app, action: r.action, detail: r.detail, active: r.active }
        end if
        return { app: app, action: "fetching", detail: row.name + " -> " + row.count + " rows", active: r.active }
    end function

    ' ---- cold state (STU-5 §10.3) -------------------------------------------
    '
    ' Reopening a project restores the CHEAP layer instantly — which files were
    ' open, where the caret was, what has run before. It does not restore
    ' computed state, and it deliberately does not try: replaying a section's
    ' chain on open would run the user's code, with its side effects, before they
    ' had asked for anything.
    '
    ' So a section whose results were recorded in an earlier session is COLD: the
    ' result is real and readable, but nothing is loaded in any interpreter, and
    ' the way to get the state back is to run it again. Saying so is the whole
    ' feature — a result presented without that distinction implies a live state
    ' behind it that does not exist.
    function run_standing(app)
        v = studio_ui.view_for(app)
        app = v.app
        if v.sid = "" then
            return { app: app, standing: "none", detail: "" }
        end if
        sess = studio_ui.exec_session(app)
        if sess != nothing then
            if sess.section_id = v.sid then
                if studio_session.is_active(sess) then
                    return { app: app, standing: "running", detail: v.sid }
                end if
                ' Run in THIS session: the state it produced is as live as the
                ' replay model ever gets.
                return { app: app, standing: "warm", detail: v.sid }
            end if
        end if
        if v.store = nothing then
            return { app: app, standing: "none", detail: "" }
        end if
        latest = studio_results.latest_for(v.store, v.sid)
        if latest = nothing then
            return { app: app, standing: "never", detail: v.sid }
        end if
        return { app: app, standing: "cold", detail: latest.result_id }
    end function

    ' The one line the strip shows about it. `warm` says nothing: a section that
    ' just ran in front of you needs no explanation.
    function standing_line(app)
        r = studio_ui.run_standing(app)
        if r.standing = "cold" then
            return "cold — recorded in an earlier session; Run to rebuild the state"
        end if
        if r.standing = "never" then
            return "not run yet"
        end if
        if r.standing = "running" then
            return "running now"
        end if
        return ""
    end function

    ' A path-free, clock-free line for the headless goldens.
    function exec_summary(app)
        sess = studio_ui.exec_session(app)
        if sess = nothing then
            return "exec: (none)"
        end if
        return "exec: " + studio_ui.run_line(sess)
    end function

    ' ---- deterministic summary (headless tests / diagnostics) --------------

    ' A path-free snapshot of everything an interaction can move: the browser rows
    ' (by kind and label, never by path), the tabs, and which of each is current.
    function summary(app)
        lines = []
        rows = studio_ui.nav_rows(app)
        lines = append(lines, "nav rows=" + count(rows))
        for each r in rows
            lines = append(lines, "  [" + r.kind + "] " + r.label)
        end for
        ws = app.model.workspace
        sel = ""
        if ws != nothing then
            sel = studio_ui._leaf(ws.nav.selected_path)
        end if
        lines = append(lines, "selected=" + sel)
        tabs = studio_ui.tab_rows(app)
        lines = append(lines, "tabs=" + count(tabs))
        for each t in tabs
            active = " "
            if t.doc_id = app.dm.active then
                active = "*"
            end if
            lines = append(lines, "  " + active + " " + t.doc_id + " " + t.label)
        end for
        return join(lines, "\n")
    end function

    ' Last path segment only — the goldens must not carry a temp directory.
    function _leaf(path)
        if path = "" then
            return ""
        end if
        parts = split(path, "/")
        return parts[count(parts) - 1]
    end function

end library
