' studio_docs.bas — the gBASIC Studio document manager (STU-2, headless).
'
' The authoritative store of OPEN DOCUMENTS. A document exists here with its content
' and saved-state independently of any editor widget: the editor (studio_shell) is a
' VIEW that mirrors a document and reports edits back. This library is pure gBASIC and
' has no GTK, so the whole open/edit/save/close/conflict/restore lifecycle is testable
' without a display.
'
' Ownership:   studio (app) -> studio_docs (manager) -> document models -> editor views
'
' A document manager is a value: { docs: [doc], active: "<id>", next_doc: N }. It is passed
' in and an updated copy returned (copy-on-write); the app holds the one live instance.
'
' A document model:
'   { id, project_id, path, display_name,
'     content,          ' the live buffer text (what the editor shows)
'     saved_content,    ' the last-persisted text; dirty := content != saved_content
'     missing,          ' file is not present on disk
'     external,         ' "none" | "changed" | "deleted": external filesystem state
'     fs_size, fs_mtime,' cheap file-state (bytes + epoch seconds) at last load/save
'     cursor: {line,column}, scroll }
'
' Identity: documents are addressed by stable id (doc-N). Two open requests for the
' same file are de-duplicated by CANONICAL PATH (lexical: resolves "." "//" ".." and a
' trailing "/"; it does NOT resolve symlinks or make a relative path absolute, so
' "a/b" and "/x/a/b" are distinct — a documented, testable policy).
'
' Saving source files uses IN-PLACE write, which preserves the file's permissions and
' symlink target (atomic_replace would reset perms to the umask default and replace a
' symlink with a regular file — verified). Studio's own metadata stores keep
' atomic_replace; user source files favor semantic preservation.
library studio_docs

    function create()
        return { docs: [], active: "", next_doc: 1 }
    end function

    ' ---- path helpers ------------------------------------------------------

    ' Lexical canonicalization for identity: drop "" and "." segments, resolve ".."
    ' against the accumulated stack, preserve a leading "/" for absolute paths.
    function _canonical(path)
        absolute = false
        first = mid(path, 0, 1)
        if first = "/" then
            absolute = true
        end if
        stack = []
        for each seg in split(path, "/")
            if seg = "" then
                skip = true
            else
                if seg = "." then
                    skip = true
                else
                    if seg = ".." then
                        n = count(stack)
                        if n > 0 then
                            top = stack[n - 1]
                            if top != ".." then
                                stack = remove(stack, n - 1)
                            else
                                stack = append(stack, seg)
                            end if
                        else
                            if not absolute then
                                stack = append(stack, seg)
                            end if
                        end if
                    else
                        stack = append(stack, seg)
                    end if
                end if
            end if
        end for
        joined = join(stack, "/")
        if absolute then
            return "/" + joined
        end if
        if joined = "" then
            return "."
        end if
        return joined
    end function

    function _basename(path)
        name = path
        for each seg in split(path, "/")
            if seg != "" then
                name = seg
            end if
        end for
        return name
    end function

    ' Parent directory of a path (lexical); "." when there is no separator.
    function _dirname(path)
        c = studio_docs._canonical(path)
        idx = 0 - 1
        i = 0
        n = len(c)
        while i < n
            ch = mid(c, i, 1)
            if ch = "/" then
                idx = i
            end if
            i = i + 1
        end while
        if idx < 0 then
            return "."
        end if
        if idx = 0 then
            return "/"
        end if
        return mid(c, 0, idx)
    end function

    ' ---- filesystem state (cheap, never raises on absence) -----------------

    ' Return { exists, is_dir, size, mtime } for a path. `mtime` is epoch seconds
    ' (a number, JSON-persistable — a datetime is not). A missing path is not an
    ' error here.
    function _state(path)
        ref(file) = path
        present = exists(ref)
        if not present then
            return { exists: false, is_dir: false, size: 0, mtime: 0 }
        end if
        ' Distinguish a directory: file_size raises on a directory, so probe via a
        ' directory listing instead (a real dir lists; a file yields nothing useful).
        isdir = studio_docs._is_dir(path)
        if isdir then
            return { exists: true, is_dir: true, size: 0, mtime: number(file_mtime(ref)) }
        end if
        return { exists: true, is_dir: false, size: file_size(ref), mtime: number(file_mtime(ref)) }
    end function

    ' Whether a path is a directory. There is no is_dir builtin, and file_size/read
    ' RAISE on a directory (an uncatchable error in gBASIC), so we must NOT probe the
    ' path directly. Instead we ask the PARENT directory for this entry's type — which
    ' correctly identifies even an empty directory (list-of-self can't). Assumes the
    ' path exists (callers check first).
    function _is_dir(path)
        parent = studio_docs._dirname(path)
        base = studio_docs._basename(path)
        d(dir) = parent
        for each e in list(d)
            if e.name = base then
                return e.type = "folder"
            end if
        end for
        return false
    end function

    ' ---- lookup ------------------------------------------------------------

    function _index(dm, id)
        i = 0
        for each d in dm.docs
            if d.id = id then
                return i
            end if
            i = i + 1
        end for
        return 0 - 1
    end function

    function doc_by_id(dm, id)
        idx = studio_docs._index(dm, id)
        if idx < 0 then
            return nothing
        end if
        return dm.docs[idx]
    end function

    ' Id of an already-open document with the same canonical path, or "".
    function find_open(dm, path)
        want = studio_docs._canonical(path)
        for each d in dm.docs
            dc = studio_docs._canonical(d.path)
            if dc = want then
                return d.id
            end if
        end for
        return ""
    end function

    function active_doc(dm)
        if dm.active = "" then
            return nothing
        end if
        return studio_docs.doc_by_id(dm, dm.active)
    end function

    function set_active(dm, id)
        idx = studio_docs._index(dm, id)
        if idx >= 0 then
            dm.active = id
        end if
        return dm
    end function

    ' ---- open --------------------------------------------------------------

    ' Open (or reuse) a document for `path` under `project_id` (project_id may be ""
    ' for a loose file). Returns { dm, id, status } where status is one of:
    '   "reused"       — an open document with the same canonical path was activated
    '   "opened"       — file read and a new document created
    '   "opened_missing" — no such file; an empty, missing-flagged document created
    '   "is_directory" — the path is a directory; nothing opened (id "")
    function open(dm, project_id, path)
        existing = studio_docs.find_open(dm, path)
        if existing != "" then
            dm = studio_docs.set_active(dm, existing)
            return { dm: dm, id: existing, status: "reused" }
        end if

        st = studio_docs._state(path)
        if st.is_dir then
            return { dm: dm, id: "", status: "is_directory" }
        end if

        id = "doc-" + dm.next_doc
        dm.next_doc = dm.next_doc + 1
        name = studio_docs._basename(path)

        if not st.exists then
            doc = studio_docs._make_doc(id, project_id, path, name, "", true, 0, 0)
            dm.docs = append(dm.docs, doc)
            dm.active = id
            return { dm: dm, id: id, status: "opened_missing" }
        end if

        ref(file) = path
        text = read(ref)
        doc = studio_docs._make_doc(id, project_id, path, name, text, false, st.size, st.mtime)
        dm.docs = append(dm.docs, doc)
        dm.active = id
        return { dm: dm, id: id, status: "opened" }
    end function

    function _make_doc(id, project_id, path, name, text, missing, size, mtime)
        return {
            id: id,
            project_id: project_id,
            path: path,
            display_name: name,
            content: text,
            saved_content: text,
            missing: missing,
            external: "none",
            fs_size: size,
            fs_mtime: mtime,
            cursor: { line: 0, column: 0 },
            scroll: 0
        }
    end function

    ' ---- dirty state -------------------------------------------------------

    ' Dirty is DERIVED from actual content, not a label: true iff the live content
    ' differs from the last-saved content. Returning to the saved text clears it.
    function is_dirty(doc)
        same = doc.content = doc.saved_content
        return not same
    end function

    ' ---- edit (the one mutation path from the editor view) -----------------

    function edit(dm, id, content)
        idx = studio_docs._index(dm, id)
        if idx < 0 then
            return dm
        end if
        doc = dm.docs[idx]
        doc.content = content
        dm.docs[idx] = doc
        return dm
    end function

    function set_cursor(dm, id, line, column)
        idx = studio_docs._index(dm, id)
        if idx < 0 then
            return dm
        end if
        doc = dm.docs[idx]
        doc.cursor = { line: line, column: column }
        dm.docs[idx] = doc
        return dm
    end function

    function set_scroll(dm, id, line)
        idx = studio_docs._index(dm, id)
        if idx < 0 then
            return dm
        end if
        doc = dm.docs[idx]
        doc.scroll = line
        dm.docs[idx] = doc
        return dm
    end function

    ' ---- save --------------------------------------------------------------

    ' Persist a document to disk with an IN-PLACE write (preserves permissions and
    ' symlink target). Pre-validates that the parent directory exists so a missing
    ' target is a clean "error" status rather than an uncatchable raise. On success
    ' the document becomes clean (saved_content := content) and its file-state is
    ' refreshed. On failure the buffer and dirty state are preserved.
    ' Returns { dm, status }: "saved" | "error" | "unknown".
    function save(dm, id)
        idx = studio_docs._index(dm, id)
        if idx < 0 then
            return { dm: dm, status: "unknown" }
        end if
        doc = dm.docs[idx]
        parent = studio_docs._dirname(doc.path)
        pref(file) = parent
        parent_ok = exists(pref)
        if not parent_ok then
            return { dm: dm, status: "error" }
        end if
        target(file) = doc.path
        write(target, doc.content)
        doc.saved_content = doc.content
        doc.missing = false
        doc.external = "none"
        fresh = studio_docs._state(doc.path)
        doc.fs_size = fresh.size
        doc.fs_mtime = fresh.mtime
        dm.docs[idx] = doc
        return { dm: dm, status: "saved" }
    end function

    ' Save every dirty document. Returns { dm, saved: [ids], failed: [ids] }.
    function save_all(dm)
        saved = []
        failed = []
        for each d in dm.docs
            if studio_docs.is_dirty(d) then
                res = studio_docs.save(dm, d.id)
                dm = res.dm
                if res.status = "saved" then
                    saved = append(saved, d.id)
                else
                    failed = append(failed, d.id)
                end if
            end if
        end for
        return { dm: dm, saved: saved, failed: failed }
    end function

    ' ---- close -------------------------------------------------------------

    ' Close a document under an explicit decision (so the choice is testable without
    ' a modal). A clean document always closes. A dirty document:
    '   "save"    -> save; close only if the save succeeded
    '   "discard" -> close, losing unsaved edits
    '   "cancel"  -> keep it open
    ' Returns { dm, status }: "closed" | "cancelled" | "save_failed" | "unknown".
    function close(dm, id, decision)
        idx = studio_docs._index(dm, id)
        if idx < 0 then
            return { dm: dm, status: "unknown" }
        end if
        doc = dm.docs[idx]
        dirty = studio_docs.is_dirty(doc)
        if dirty then
            if decision = "cancel" then
                return { dm: dm, status: "cancelled" }
            end if
            if decision = "save" then
                res = studio_docs.save(dm, id)
                dm = res.dm
                if res.status != "saved" then
                    return { dm: dm, status: "save_failed" }
                end if
            end if
        end if
        dm = studio_docs._remove(dm, id)
        return { dm: dm, status: "closed" }
    end function

    function _remove(dm, id)
        kept = []
        for each d in dm.docs
            if d.id != id then
                kept = append(kept, d)
            end if
        end for
        dm.docs = kept
        if dm.active = id then
            newactive = ""
            if count(kept) > 0 then
                first = kept[0]
                newactive = first.id
            end if
            dm.active = newactive
        end if
        return dm
    end function

    ' ---- external change detection + checkpoint ----------------------------

    ' Re-stat one document and classify the filesystem relative to what we last saw:
    ' sets doc.external = "deleted" | "changed" | "none" and doc.missing. Returns
    ' { dm, state }.
    function detect_external(dm, id)
        idx = studio_docs._index(dm, id)
        if idx < 0 then
            return { dm: dm, state: "none" }
        end if
        doc = dm.docs[idx]
        st = studio_docs._state(doc.path)
        state = "none"
        if not st.exists then
            doc.missing = true
            doc.external = "deleted"
            state = "deleted"
        else
            doc.missing = false
            changed = false
            if st.size != doc.fs_size then
                changed = true
            end if
            if st.mtime != doc.fs_mtime then
                changed = true
            end if
            if changed then
                doc.external = "changed"
                state = "changed"
            else
                doc.external = "none"
                state = "none"
            end if
        end if
        dm.docs[idx] = doc
        return { dm: dm, state: state }
    end function

    ' Re-read a document from disk, adopting the on-disk content as the new saved
    ' baseline (clears dirty and external). Caller must only invoke this when it is
    ' safe to discard the buffer (e.g. a clean external change). Returns { dm, status }.
    function reload(dm, id)
        idx = studio_docs._index(dm, id)
        if idx < 0 then
            return { dm: dm, status: "unknown" }
        end if
        doc = dm.docs[idx]
        st = studio_docs._state(doc.path)
        if not st.exists then
            doc.missing = true
            doc.external = "deleted"
            dm.docs[idx] = doc
            return { dm: dm, status: "missing" }
        end if
        ref(file) = doc.path
        text = read(ref)
        doc.content = text
        doc.saved_content = text
        doc.missing = false
        doc.external = "none"
        doc.fs_size = st.size
        doc.fs_mtime = st.mtime
        dm.docs[idx] = doc
        return { dm: dm, status: "reloaded" }
    end function

    ' Scan every open document for external changes and apply the safe policy:
    '   clean + changed on disk -> auto-reload (no local edits to lose)
    '   dirty  + changed on disk -> CONFLICT: keep the buffer, flag external=changed
    '   deleted on disk          -> flag missing/deleted, keep the buffer
    ' Never silently overwrites the buffer when there are unsaved edits. Returns
    ' { dm, conflicts: [ids], reloaded: [ids], deleted: [ids] }.
    function checkpoint(dm)
        conflicts = []
        reloaded = []
        deleted = []
        for each d in dm.docs
            res = studio_docs.detect_external(dm, d.id)
            dm = res.dm
            if res.state = "deleted" then
                deleted = append(deleted, d.id)
            else
                if res.state = "changed" then
                    dirty = studio_docs.is_dirty(studio_docs.doc_by_id(dm, d.id))
                    if dirty then
                        conflicts = append(conflicts, d.id)
                    else
                        rr = studio_docs.reload(dm, d.id)
                        dm = rr.dm
                        reloaded = append(reloaded, d.id)
                    end if
                end if
            end if
        end for
        return { dm: dm, conflicts: conflicts, reloaded: reloaded, deleted: deleted }
    end function

    ' ---- persistence (metadata only; content is re-read from disk on restore) ---

    ' Strip live content and produce the persistable open-document metadata.
    function to_meta(dm)
        open_meta = []
        for each d in dm.docs
            open_meta = append(open_meta, {
                id: d.id,
                project_id: d.project_id,
                path: d.path,
                display_name: d.display_name,
                cursor: d.cursor,
                scroll: d.scroll,
                fs_size: d.fs_size,
                fs_mtime: d.fs_mtime
            })
        end for
        return { open: open_meta, active: dm.active, next_doc: dm.next_doc }
    end function

    ' Rebuild a live document manager from persisted metadata, re-reading each file
    ' from disk (buffers of saved files are NOT persisted). A file that has since
    ' disappeared restores as a missing-flagged, empty document rather than failing.
    ' Cursor/scroll are restored. Returns the live dm.
    function from_meta(meta)
        dm = studio_docs.create()
        dm.active = meta.active
        dm.next_doc = meta.next_doc
        docs = []
        for each m in meta.open
            st = studio_docs._state(m.path)
            if st.is_dir then
                skip = true
            else
                if not st.exists then
                    doc = studio_docs._make_doc(m.id, m.project_id, m.path, m.display_name, "", true, 0, 0)
                else
                    ref(file) = m.path
                    text = read(ref)
                    doc = studio_docs._make_doc(m.id, m.project_id, m.path, m.display_name, text, false, st.size, st.mtime)
                end if
                doc.cursor = m.cursor
                doc.scroll = m.scroll
                docs = append(docs, doc)
            end if
        end for
        dm.docs = docs
        ' If the active id was dropped (e.g. it was a directory), fall back cleanly.
        chk = studio_docs._index(dm, dm.active)
        if chk < 0 then
            if count(docs) > 0 then
                d0 = docs[0]
                dm.active = d0.id
            else
                dm.active = ""
            end if
        end if
        return dm
    end function

    ' ---- deterministic summary (headless tests / diagnostics) --------------

    ' Path-free per-document status line, in tab order. Fields: id, name, active
    ' flag, dirty flag, missing flag, external state, cursor.
    function summary(dm)
        lines = []
        lines = append(lines, "active=" + dm.active)
        for each d in dm.docs
            act = "-"
            if d.id = dm.active then
                act = "*"
            end if
            dirty = "clean"
            if studio_docs.is_dirty(d) then
                dirty = "dirty"
            end if
            miss = ""
            if d.missing then
                miss = " missing"
            end if
            ext = ""
            if d.external != "none" then
                ext = " ext:" + d.external
            end if
            cur = " cur=" + d.cursor.line + ":" + d.cursor.column
            lines = append(lines, act + " " + d.id + " " + d.display_name + " " + dirty + miss + ext + cur)
        end for
        return join(lines, "\n")
    end function

end library
