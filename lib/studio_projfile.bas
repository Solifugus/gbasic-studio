' studio_projfile.bas — the project's OWN file, `.gstudio.json`.
'
' The opposite case from `studio_projects`, and the two are easy to confuse, so
' the distinction is the first thing here:
'
'   studio_projects   <home>/state/<key>.json   DERIVED, personal, sometimes
'                     large. Section anchors, a branch tree, overlays. It means
'                     nothing beside another home's results and belongs to this
'                     machine's user, not to the project.
'   studio_projfile   <project>/.gstudio.json   DECLARED, small, hand-edited,
'                     committed. What this project IS, in terms that travel: a
'                     stable identity, what the browser should not show, and
'                     which gBASIC it is meant to run under.
'
' The two pin fields are named after the two things `./studio` itself sets, so
' there is nothing to translate: `interpreter` is the gBASIC binary and
' `gbasic_path` is GBASIC_PATH for the child. Calling the second one `stdlib`
' would have been a small lie — a project with its own `lib/` needs both
' entries, and that is the more useful thing to be able to say.
'
' **Studio never creates this file on its own.** Not on Open Folder, not on New
' Project unless the box is ticked, not on first run, not on save. The whole
' objection to an IDE's metadata is that it appears uninvited and then has
' opinions about your directory; a file that only exists because somebody asked
' for it cannot do that. `create` is reached from exactly one action.
'
' It is also the only dotfile the browser shows (`studio_ui.hidden_entry`), for
' the same reason: a file you were asked to consent to should be visible
' afterwards.
library studio_projfile

    ' Dependencies, declared rather than assumed.
    load persist
    load studio_model

    function filename()
        return ".gstudio.json"
    end function

    function schema_version()
        return 1
    end function

    ' "" for a project that has no path — a document opened with nothing
    ' adopted. There is no directory to hold a project file, and inventing one
    ' is how metadata ends up somewhere nobody looked.
    function path_for(project_path)
        if project_path = "" then
            return ""
        end if
        return project_path + "/" + studio_projfile.filename()
    end function

    ' The shape every caller gets, present or not, so nothing has to test for
    ' `nothing` before reading a field.
    '
    ' `present` is about the FILE being there; `status` is about whether Studio
    ' could use it. The two differ on purpose: a corrupt or future-version file
    ' is present (so "add one" must still refuse) and unusable (so nothing is
    ' read out of it).
    function empty()
        return {
            schema_version: studio_projfile.schema_version(),
            present: false,
            status: "absent",
            id: "",
            name: "",
            ignore: [],
            interpreter: "",
            gbasic_path: "",
            templates: "",
            databases: {}
        }
    end function

    ' Read a project's file. Never raises: an unreadable `.gstudio.json` must
    ' not be able to stop a project opening, and it is the user's own file —
    ' half-typed is a normal state for it to be in.
    '
    ' status: "absent" | "ok" | "unreadable" | "newer"
    '
    ' `read_spec` and not `read`: gBASIC has a `read` builtin, and a library
    ' function that shadows one earns a note on STDERR at every load. Several
    ' golden tiers capture stderr, so a name collision here is not a style
    ' question — it is eleven failing tests, which is how the last one was
    ' found.
    function read_spec(project_path)
        out = studio_projfile.empty()
        p = studio_projfile.path_for(project_path)
        if p = "" then
            return out
        end if
        probe{file} = p
        if not exists(probe) then
            return out
        end if
        ' There, therefore present, whatever comes of reading it.
        out.present = true
        out.status = "unreadable"
        st = persist.read_status(p)
        ' "loaded", not "ok" — the same status value that cost an afternoon in
        ' studio_projects.
        if st.status != "loaded" then
            return out
        end if
        raw = st.value
        if not is_record(raw) then
            return out
        end if
        v = 0
        if has(raw, "schema_version") then
            if is_number(raw.schema_version) then
                v = raw.schema_version
            end if
        end if
        if v > studio_projfile.schema_version() then
            ' Written by a newer Studio. Read NOTHING out of it rather than the
            ' fields we happen to recognise: a file that means something else
            ' now would be half-honoured, which is worse than not honoured. The
            ' state store takes the same line.
            out.status = "newer"
            return out
        end if
        out.status = "ok"
        out.id = studio_projfile._string(raw, "id")
        out.name = studio_projfile._string(raw, "name")
        out.interpreter = studio_projfile._string(raw, "interpreter")
        out.gbasic_path = studio_projfile._string(raw, "gbasic_path")
        ' A DIRECTORY of `.templates` files this project ships, named rather
        ' than conventional. Studio reading a directory of your project because
        ' of its NAME is the uninvited-metadata complaint arriving from the
        ' other side -- and a declared path also lets a team keep templates
        ' where their repository already keeps such things.
        out.templates = studio_projfile._string(raw, "templates")
        out.ignore = studio_projfile._strings(raw, "ignore")
        ' The connections this project knows, BY NAME. No passwords here: this
        ' file is committed, and a credential that travels with the project is
        ' a credential in everybody's clone. Those go in `studio_secrets`,
        ' which is keyed by the same name.
        if has(raw, "databases") then
            if is_record(raw.databases) then
                out.databases = raw.databases
            end if
        end if
        return out
    end function

    ' A field that has to be a string, or is treated as absent. This file is
    ' hand-edited, so "ignore": "build" (a string where an array belongs) is a
    ' thing that will happen, and it must not raise inside a redraw.
    function _string(raw, key)
        if not has(raw, key) then
            return ""
        end if
        v = raw[key]
        if is_string(v) then
            return v
        end if
        return ""
    end function

    function _strings(raw, key)
        out = []
        if not has(raw, key) then
            return out
        end if
        v = raw[key]
        if not is_array(v) then
            return out
        end if
        for each e in v
            if is_string(e) then
                if e != "" then
                    out = append(out, e)
                end if
            end if
        end for
        return out
    end function

    ' ---- identity -----------------------------------------------------------

    ' A project's stable id, minted ONCE — when the file is written — and never
    ' derived again afterwards.
    '
    ' Two numbers: a hash of where the project was, and the second it was minted
    ' in. That pair is unique in practice (`create` refuses to overwrite, so the
    ' same path cannot mint twice in one second) and it is OPAQUE — deliberately
    ' not the path itself, because an id you can read as a path invites the
    ' reading that it goes stale when the project moves, which is the exact
    ' thing it exists not to do.
    '
    ' `stamp` is a parameter rather than an `epoch()` call so a test can pin it,
    ' the same seam `studio_session.clock_fixed` is.
    function mint_id(project_path, stamp)
        return "gsp-" + studio_model.text_hash(project_path) + "-" + stamp
    end function

    ' ---- writing ------------------------------------------------------------

    ' Write the file, once, on request.
    '
    ' Returns { ok, reason, path, id }, reason one of "created", "exists",
    ' "project-no-folder". REFUSES over an existing file rather than merging into it:
    ' this is a hand-edited file and Studio does not know what else is in it,
    ' and a rewrite that dropped somebody's comment-by-convention key would be
    ' the uninvited-metadata complaint arriving by the back door.
    '
    ' What it writes is MINIMAL on purpose. The id, because that is the point;
    ' the name and an empty ignore list, because a file whose only content is an
    ' opaque identifier teaches a reader nothing about what else may go in it.
    ' `interpreter` and `gbasic_path` are OMITTED rather than written empty —
    ' an empty string in an interpreter field reads as a claim ("no
    ' interpreter") rather than as an absence.
    function create(project_path, opts)
        p = studio_projfile.path_for(project_path)
        if p = "" then
            ' "no-folder", not "no-project": there IS a project, it just has
            ' no directory to put a file in. Answering `no-project` made the
            ' status line say "open a project first" about a project that was
            ' plainly open -- a refusal whose wording contradicts what the user
            ' can see is indistinguishable from the button doing nothing.
            return { ok: false, reason: "project-no-folder", path: "", id: "" }
        end if
        probe{file} = p
        if exists(probe) then
            return { ok: false, reason: "exists", path: p, id: "" }
        end if
        rec = {
            schema_version: studio_projfile.schema_version(),
            id: opts.id,
            name: opts.name,
            ignore: []
        }
        persist.write_atomic(p, rec)
        return { ok: true, reason: "created", path: p, id: opts.id }
    end function

    ' ---- the ignore list ----------------------------------------------------

    ' Whether the browser hides an entry on this project's say-so.
    '
    ' Matches a NAME, at any depth: `build` hides every directory called build,
    ' not only one beside the project file. That is what a bare name already
    ' means in a .gitignore, and it is also what falls out honestly — the
    ' browser filters `filetree.flatten` rows by name, so a path-anchored rule
    ' would have to be a second mechanism pretending to be the same one.
    '
    ' Two forms and no more: an exact name, and a `*` prefix matching a suffix
    ' (`*.o`). No full globbing. A pattern language nobody can predict the
    ' behaviour of is worse than one that plainly does two things, and every
    ' character that is not a leading `*` is matched literally — so a name
    ' containing `[` or `?` is hidden by writing it out.
    function ignored(spec, name)
        if spec = nothing then
            return false
        end if
        for each pat in spec.ignore
            if pat = name then
                return true
            end if
            if left(pat, 1) = "*" then
                tail = right(pat, len(pat) - 1)
                if tail != "" then
                    if ends_with(name, tail) then
                        return true
                    end if
                end if
            end if
        end for
        return false
    end function

    ' ---- reporting ----------------------------------------------------------

    ' A deterministic, path-free line for the goldens and the summaries.
    ' The pin is reported as a boolean: both halves of it are absolute paths
    ' into somebody's machine, and a golden cannot hold one.
    function summary(spec)
        line = "status=" + spec.status + " present=" + spec.present
        line = line + " id=" + studio_projfile._shape(spec.id)
        line = line + " name=" + spec.name
        line = line + " ignore=" + count(spec.ignore)
        line = line + " pinned=" + studio_projfile.pinned(spec)
        line = line + " databases=" + count(keys(spec.databases))
        return line
    end function

    ' Whether this project pins what it runs under. Either half counts: a
    ' pinned library path with the ambient interpreter is a real configuration,
    ' and so is the reverse.
    function pinned(spec)
        if spec.interpreter != "" then
            return true
        end if
        return spec.gbasic_path != ""
    end function

    ' An id's SHAPE rather than its value, because half of it is a clock. A
    ' golden asserting "gsp-<n>-<n>" says the thing worth asserting — that an id
    ' was minted and has the form — without pinning the second it happened in.
    function _shape(id)
        if id = "" then
            return "(none)"
        end if
        out = ""
        rundigit = false
        i = 0
        n = byte_count(id)
        while i < n
            b = byte_at(id, i)
            digit = false
            if b >= 48 then
                if b <= 57 then
                    digit = true
                end if
            end if
            if digit then
                if not rundigit then
                    out = out + "#"
                end if
            else
                out = out + chr(b)
            end if
            rundigit = digit
            i = i + 1
        end while
        return out
    end function

end library
