' studio_drafts — unsaved buffers survive closing the window (headless).
'
' Until this existed, closing Studio threw away every unsaved edit. It said so on
' stderr as it went, which is to say it said so to nobody: a GUI user never sees
' that stream. An IDE that discards your typing when you close it is not one you
' can leave running while you think, and "it warned you" is not a defence when
' the warning went somewhere you cannot look.
'
' WHAT A DRAFT IS. The buffer text of a document whose content differs from the
' file on disk, written beside the workspace on the way out and read back on the
' way in. It is not a backup and not a version — there is exactly one per
' document path, it is replaced wholesale, and saving or closing the document
' cleanly deletes it.
'
' WHAT IT IS NOT. A draft never silently becomes the file. It restores as an
' UNSAVED buffer, exactly as the user left it, so the next Save is still theirs
' to make. Restoring by writing to disk would be a program editing a user's
' source without being asked.
'
' THE CASE THAT MATTERS. The file can change on disk while a draft is sitting
' there — someone else's edit, a git checkout, another editor. Restoring the
' draft over that silently would hide the change; discarding the draft would lose
' the typing. So a fingerprint of the file AS IT WAS when the draft was written
' is stored with it, and a mismatch restores the draft and reports a CONFLICT,
' leaving both facts visible and the decision with the user.
'
' The fingerprint is a HASH OF THE TEXT, not size and mtime. gBASIC's file mtime
' has second resolution, so a rewrite in the same second at the same length is
' invisible to a size+mtime pair — and that is not an exotic case: it is what an
' editor doing save-then-save-again, or a script, produces. The first version of
' this used size+mtime and its own test walked straight through the hole.
library studio_drafts


    ' Dependencies, declared rather than assumed.
    load persist
    load studio_docs

    function schema_version()
        return 1
    end function

    function dir(home)
        return home + "/drafts"
    end function

    function index_path(home)
        return studio_drafts.dir(home) + "/index.json"
    end function

    ' A filesystem-safe, collision-resistant name for a document path — the same
    ' scheme studio_results uses, and for the same reason: two files sharing a
    ' basename in different directories must not share a draft.
    function _key(doc_path)
        m = 1000000007
        h = 0
        i = 0
        n = byte_count(doc_path)
        while i < n
            h = h - floor(h / m) * m
            h = h * 131 + byte_at(doc_path, i) + 1
            i = i + 1
        end while
        h = h - floor(h / m) * m
        safe = ""
        parts = split(doc_path, "/")
        leaf = parts[count(parts) - 1]
        j = 0
        while j < len(leaf)
            ch = lower(mid(leaf, j, 1))
            keep = "-"
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
            safe = safe + keep
            j = j + 1
        end while
        return safe + "-" + h
    end function

    ' A rolling hash of a document's text, for telling "the file is as the draft
    ' left it" from "something else wrote it".
    function _hash(text)
        m = 1000000007
        h = 0
        i = 0
        n = byte_count(text)
        while i < n
            h = h - floor(h / m) * m
            h = h * 131 + byte_at(text, i) + 1
            i = i + 1
        end while
        return h - floor(h / m) * m
    end function

    function text_path(home, doc_path)
        return studio_drafts.dir(home) + "/" + studio_drafts._key(doc_path) + ".txt"
    end function

    ' ---- writing -----------------------------------------------------------

    ' Write a draft for every DIRTY document and remove the drafts of documents
    ' that are no longer dirty (saved, reverted, or closed). Returns the index,
    ' which names what was written so a reader never has to scan the directory.
    function capture(home, dm)
        persist.ensure_dir(studio_drafts.dir(home))
        entries = []
        for each d in dm.docs
            dirty = studio_docs.is_dirty(d)
            if dirty then
                persist.write_text_atomic(studio_drafts.text_path(home, d.path), d.content)
                entries = append(entries, {
                    path: d.path,
                    key: studio_drafts._key(d.path),
                    bytes: byte_count(d.content),
                    ' The file as it was when this draft was taken — the text the
                    ' buffer was based on. A later mismatch is the whole conflict
                    ' signal.
                    base: studio_drafts._hash(d.saved_content)
                })
            end if
        end for
        index = { schema_version: studio_drafts.schema_version(), drafts: entries }
        persist.write_atomic(studio_drafts.index_path(home), index)
        studio_drafts._sweep(home, index)
        return index
    end function

    ' Delete draft texts the index no longer names. A draft whose document was
    ' saved must not survive to be restored over the saved file next time.
    function _sweep(home, index)
        keep = []
        for each e in index.drafts
            keep = append(keep, e.key + ".txt")
        end for
        d{dir} = studio_drafts.dir(home)
        for each entry in list(d)
            if entry.type != "folder" then
                if entry.name != "index.json" then
                    if not contains(keep, entry.name) then
                        f{file} = studio_drafts.dir(home) + "/" + entry.name
                        delete(f)
                    end if
                end if
            end if
        end for
        return nothing
    end function

    ' ---- reading -----------------------------------------------------------

    function open_index(home)
        st = persist.read_status(studio_drafts.index_path(home))
        if st.status != "loaded" then
            return { schema_version: studio_drafts.schema_version(), drafts: [] }
        end if
        raw = st.value
        v = 0
        if has(raw, "schema_version") then
            v = raw.schema_version
        end if
        if v > studio_drafts.schema_version() then
            return { schema_version: studio_drafts.schema_version(), drafts: [] }
        end if
        if not has(raw, "drafts") then
            return { schema_version: studio_drafts.schema_version(), drafts: [] }
        end if
        return { schema_version: v, drafts: raw.drafts }
    end function

    function _entry_for(index, doc_path)
        for each e in index.drafts
            if e.path = doc_path then
                return e
            end if
        end for
        return nothing
    end function

    ' Put the drafts back. Returns { dm, restored, conflicts } — the two lists
    ' name document ids, so the caller can say what happened without re-deriving
    ' it.
    '
    ' A document whose file has changed since the draft was taken still gets its
    ' draft back; what changes is that it is reported as a conflict. Both the
    ' typing and the fact that the file moved underneath stay visible, which is
    ' the same policy `checkpoint_documents` applies to an external change during
    ' a session.
    function restore(home, dm)
        index = studio_drafts.open_index(home)
        if count(index.drafts) = 0 then
            return { dm: dm, restored: [], conflicts: [] }
        end if
        restored = []
        conflicts = []
        out = []
        for each d in dm.docs
            e = studio_drafts._entry_for(index, d.path)
            if e = nothing then
                out = append(out, d)
            else
                f{file} = studio_drafts.text_path(home, d.path)
                if not exists(f) then
                    ' The index named a draft whose text is gone. Nothing to
                    ' restore and nothing to report — a missing draft is not a
                    ' conflict, it is an absence.
                    out = append(out, d)
                else
                    ' `d.saved_content` is what from_meta just read off disk, so
                    ' hashing it compares the file NOW against the file the draft
                    ' was taken from.
                    now = studio_drafts._hash(d.saved_content)
                    d.content = read(f)
                    moved = e.base != now
                    if moved then
                        ' The documented vocabulary is none|changed|deleted
                        ' (studio_docs). A fourth value here would be a second
                        ' way of saying the same thing that every reader of
                        ' `external` would have to learn.
                        d.external = "changed"
                        conflicts = append(conflicts, d.id)
                    else
                        restored = append(restored, d.id)
                    end if
                    out = append(out, d)
                end if
            end if
        end for
        dm.docs = out
        return { dm: dm, restored: restored, conflicts: conflicts }
    end function

    ' A deterministic, path-free rendering for the goldens.
    function summary(index)
        lines = []
        lines = append(lines, "drafts: " + count(index.drafts))
        for each e in index.drafts
            parts = split(e.path, "/")
            lines = append(lines, "  " + parts[count(parts) - 1] + " " + e.bytes + " bytes")
        end for
        return join(lines, "\n")
    end function

end library
