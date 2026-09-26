' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_projects.bas — what Studio knows about ONE project, in a file of its own.
'
' Section anchors, the branch tree and the code overlays all used to live in the
' workspace record, which meant one file held every project's intellectual state
' at once. That is the wrong unit twice over: the file grows with every project
' you have ever opened and never shrinks, and the state that is obviously ABOUT
' one project cannot be found, inspected or deleted without editing a blob that
' also describes four others.
'
' A project's state is now `<home>/state/<key>.json`, and the key comes from the
' project's IDENTITY: its own id out of `.gstudio.json` when it has one, and its
' PATH when it has not. Either way through `studio_model.path_key`, the same
' function `studio_results` keys a document with, so the two stores cannot drift
' into different filenames for one input.
'
' It is deliberately NOT in the project directory. This is derived, personal and
' sometimes large: anchors that only mean anything beside this home's results,
' a branch tree that is an experiment in progress. The project directory gets
' nothing it did not ask for (see `.gstudio.json`, which is the opposite case:
' small, hand-editable, and meant to travel).
library studio_projects

    ' Dependencies, declared rather than assumed.
    load persist
    load studio_model

    function schema_version()
        return 1
    end function

    function state_dir(home)
        return home + "/state"
    end function

    ' The key a project's state is filed under — its IDENTITY, reduced to
    ' something a filename can hold.
    '
    ' `stable_id` is the project's own id out of `.gstudio.json` when it has
    ' one, and "" when it has not. With an id the state survives the project
    ' being MOVED or RENAMED, which is the whole reason that file exists. It is
    ' still run through `path_key` rather than used raw: the id is hand-editable
    ' text and a `/` or a space in it would otherwise choose the filename.
    '
    ' Without one the key falls back to the PATH. A project id (`proj-N`) would
    ' be the obvious third option and is the wrong one: it is minted from a
    ' per-workspace counter, so closing a project and reopening it mints a
    ' different one and the state is orphaned — the same defect that keying
    ' section anchors by `doc-N` produced. A path at least survives that.
    '
    ' Adding a project file therefore CHANGES a project's key, which is why
    ' `studio_ui.add_project_file` re-files the state under the new one instead
    ' of letting the anchors fall off a directory that has not moved.
    function key_for(project_path, stable_id)
        if is_string(stable_id) then
            if stable_id != "" then
                return studio_model.path_key(stable_id)
            end if
        end if
        if project_path = "" then
            return ""
        end if
        return studio_model.path_key(project_path)
    end function

    ' Everything below takes the KEY, not the path. Identity is resolved once,
    ' by the one caller that holds both the path and the project file
    ' (`studio_ui.project_state`), and this library never learns what a
    ' directory is.
    function state_path(home, key)
        return studio_projects.state_dir(home) + "/" + key + ".json"
    end function

    ' `branches` and `overlays` are stored as whatever studio_branches and
    ' studio_overlays persist; this library does not interpret either, so their
    ' schemas stay theirs. `nothing` is what their `from_persist` reads as
    ' "nothing stored yet", which is exactly the empty case.
    function empty(key)
        return {
            schema_version: studio_projects.schema_version(),
            key: key,
            sections: [],
            branches: nothing,
            overlays: nothing
        }
    end function

    ' Read a project's state. Missing, corrupt or written by a newer Studio all
    ' recover to empty with no diagnostic of their own — the caller records one
    ' if it cares. Never raises: losing an outline is a smaller problem than a
    ' window that will not open.
    function open(home, key)
        if key = "" then
            return studio_projects.empty("")
        end if
        st = persist.read_status(studio_projects.state_path(home, key))
        if st.status != "loaded" then
            return studio_projects.empty(key)
        end if
        raw = st.value
        if not is_record(raw) then
            return studio_projects.empty(key)
        end if
        v = 0
        if has(raw, "schema_version") then
            v = raw.schema_version
        end if
        if v > studio_projects.schema_version() then
            return studio_projects.empty(key)
        end if
        out = studio_projects.empty(key)
        if has(raw, "sections") then
            if is_array(raw.sections) then
                out.sections = raw.sections
            end if
        end if
        if has(raw, "branches") then
            out.branches = raw.branches
        end if
        if has(raw, "overlays") then
            out.overlays = raw.overlays
        end if
        return out
    end function

    ' Write it back. A project with no key (a document open under no project at
    ' all) has nowhere to go and is skipped rather than invented a home for.
    function save(home, key, state)
        if key = "" then
            return false
        end if
        persist.ensure_dir(studio_projects.state_dir(home))
        state.schema_version = studio_projects.schema_version()
        state.key = key
        persist.write_atomic(studio_projects.state_path(home, key), state)
        return true
    end function

    ' A deterministic, path-free line for the goldens.
    function summary(state)
        nb = 0
        if state.branches != nothing then
            if has(state.branches, "branches") then
                nb = count(state.branches.branches)
            end if
        end if
        no = 0
        if state.overlays != nothing then
            if has(state.overlays, "edits") then
                no = count(state.overlays.edits)
            end if
        end if
        return "docs=" + count(state.sections) + " branches=" + nb + " overlays=" + no
    end function

end library
