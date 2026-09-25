' studio_templates — DECLARED text with holes in it (STU-15)
'
' A template is a named piece of text carrying `{{placeholder}}` holes, read
' from a `.templates` file and NEVER EVALUATED. That last word is the whole
' design. This registry reads JSON and runs nothing: no expressions, no
' conditionals, no loops, no shelling out. If it ever grew a way to execute
' what a file ships, a template dropped into a directory would be arbitrary
' code with Studio's privileges — which is the same line `studio_viewers` holds
' for the same reason, and `templates_declarative` greps for it.
'
' What that costs is real and is accepted: a template cannot say "include this
' line only if a licence was chosen". Choosing WHICH template to render is the
' caller's job, in gBASIC, where it is testable — `studio_ui.project_plan`
' decides which files a New Project gets, exactly as it did before, and asks
' here only for their text.
'
' Substitution is ONE PASS. A value that itself contains `{{other}}` is left
' alone, because the parts are scanned once and each value is appended to the
' output rather than put back into the input. Repeated `replace()` calls would
' not have that property: the second call would reach into the first call's
' output, so a project named `{{holder}}` would start picking up somebody's
' name. It is the kind of defect that never shows up until the one day it does.
'
' The registry mirrors `studio_viewers` on purpose — same `.suffix` idea, same
' problems-not-raises rule, same load-and-validate order — because a second
' shape for "read declarative sidecars off a search path" would be a second set
' of edge cases to get right.
library studio_templates
    load persist

    function schema_version()
        return 1
    end function

    ' The extension a template file carries. Deliberately not `.json`: a
    ' directory may hold unrelated JSON, and a registry that swept all of it
    ' would report parse failures for files never addressed to it.
    function suffix()
        return ".templates"
    end function

    ' ---- the registry -------------------------------------------------------

    function create()
        return { schema_version: studio_templates.schema_version(),
                 templates: [], sources: [], problems: [] }
    end function

    ' Search directories, in precedence order — the FIRST one holding an id
    ' wins, and the ones after it are recorded as shadowed rather than dropped
    ' silently.
    '
    ' Ordered by how specific the context is, which is the only ordering that
    ' can be explained in one sentence: the project you are in beats the
    ' machine you are on, which beats a library you loaded, which beats what
    ' Studio shipped.
    '
    '   1  the project's own, DECLARED in `.gstudio.json` as `templates`. A
    '      path and not a convention: Studio reading a directory in your
    '      project because of its name is the uninvited-metadata complaint
    '      arriving from the other side, and a declared path also lets a team
    '      keep templates where their repository already keeps such things.
    '   2  `<home>/templates` — the user's own, in Studio's own directory,
    '      where nothing of theirs is at stake.
    '   3  `$GBASIC_STDLIB` — a library is the authority on its own snippets,
    '      the same argument the viewer registry makes about its own types.
    '   4  `$GBASIC_STUDIO_SHARE/templates` — what Studio ships, which exists
    '      only so a stock install has something before anyone else ships one.
    function search_path(project_dir, home, stdlib, share)
        dirs = []
        if project_dir != "" then
            dirs = append(dirs, project_dir)
        end if
        if home != "" then
            dirs = append(dirs, home + "/templates")
        end if
        if stdlib != "" then
            dirs = append(dirs, stdlib)
        end if
        if share != "" then
            dirs = append(dirs, share + "/templates")
        end if
        return dirs
    end function

    ' The path a running Studio uses. `GBASIC_STUDIO_SHARE` is exported by
    ' `./studio` and by the test runner, like the licence texts it sits beside;
    ' an installed copy keeps `share/` somewhere else and Studio's own working
    ' directory is never the answer.
    function default_path(home, project_dir)
        return studio_templates.search_path(project_dir, home,
                                            studio_templates._env("GBASIC_STDLIB"),
                                            studio_templates._env("GBASIC_STUDIO_SHARE"))
    end function

    ' `env` answers `unknown` for an unset variable and comparing one to a
    ' string raises, so every read of one goes through here.
    function _env(name)
        v = env(name)
        if is_string(v) then
            return v
        end if
        return ""
    end function

    ' Read every template file on the path into one registry. A missing
    ' directory, an unreadable file and malformed JSON are all PROBLEMS rather
    ' than raises: one library shipping a broken file must not stop New Project
    ' from opening, and a template that silently did not load is the kind of
    ' fault that gets diagnosed as "the button is wrong" for a week.
    function load_path(dirs)
        reg = studio_templates.create()
        for each dir in dirs
            reg = studio_templates.load_dir(reg, dir)
        end for
        return reg
    end function

    function load_dir(reg, dir)
        names = []
        d{dir} = dir
        probe{file} = dir
        if not exists(probe) then
            ' Not a problem. Three of the four layers are normally absent —
            ' most projects declare no template directory and most users have
            ' never made one — and a registry reporting that as a fault would
            ' bury the faults that matter.
            return reg
        end if
        for each e in list(d)
            if e.type = "file" then
                if studio_templates._is_file(e.name) then
                    names = append(names, e.name)
                end if
            end if
        end for
        ' Sorted, so two files in one directory load in an order that does not
        ' depend on the filesystem — otherwise which of two colliding ids wins
        ' would vary by machine.
        names = sort(names)
        for each n in names
            reg = studio_templates.load_file(reg, dir + "/" + n)
        end for
        return reg
    end function

    function _is_file(name)
        s = studio_templates.suffix()
        if len(name) <= len(s) then
            return false
        end if
        return right(name, len(s)) = s
    end function

    ' One file. Every template is validated BEFORE it enters the registry, and
    ' a rejected one names itself and the reason — an invalid entry that loaded
    ' anyway would fail later, in the renderer, where the message would be
    ' about a missing value rather than about a malformed declaration.
    function load_file(reg, path)
        f{file} = path
        if not exists(f) then
            reg.problems = append(reg.problems, path + ": missing")
            return reg
        end if
        r = try_decode(read(f))
        if not r.ok then
            reg.problems = append(reg.problems, path + ": not valid JSON")
            return reg
        end if
        doc = r.value
        if not is_record(doc) then
            reg.problems = append(reg.problems, path + ": not an object")
            return reg
        end if
        v = 0
        if has(doc, "schema_version") then
            if is_number(doc.schema_version) then
                v = doc.schema_version
            end if
        end if
        if v > studio_templates.schema_version() then
            ' Written by a newer Studio: read NOTHING out of it rather than the
            ' fields we happen to recognise. Half-honouring a file that means
            ' something else now is worse than not honouring it — the same line
            ' `.gstudio.json` and the state store take.
            reg.problems = append(reg.problems, path + ": schema_version " + v + " is newer than this Studio reads")
            return reg
        end if
        if not has(doc, "templates") then
            reg.problems = append(reg.problems, path + ": no templates")
            return reg
        end if
        if not is_array(doc.templates) then
            reg.problems = append(reg.problems, path + ": templates is not a list")
            return reg
        end if
        dir = studio_templates._dir_of(path)
        added = 0
        for each t in doc.templates
            one = studio_templates._read_one(t, dir)
            if one.why != "" then
                reg.problems = append(reg.problems, path + ": " + one.why)
            else
                held = studio_templates.by_id(reg, one.tpl.id)
                if held != nothing then
                    ' Shadowed, not dropped in silence. The first directory on
                    ' the path wins — that is the rule — but somebody who
                    ' overrode a template without meaning to has no other way
                    ' to find out.
                    reg.problems = append(reg.problems, path + ": " + quote(one.tpl.id) + " is already defined by " + held.source + "; this one is ignored")
                else
                    one.tpl.source = path
                    reg.templates = append(reg.templates, one.tpl)
                    added = added + 1
                end if
            end if
        end for
        reg.sources = append(reg.sources, { path: path, templates: added })
        return reg
    end function

    ' The directory a template file sits in, lexically -- `from` resolves
    ' against it. Written out rather than reaching for `studio_docs._dirname`:
    ' that one canonicalizes, which is right for a document's identity and
    ' unnecessary here, and it would make this library depend on the document
    ' manager to find a sibling file.
    function _dir_of(path)
        idx = 0 - 1
        i = 0
        n = len(path)
        while i < n
            if mid(path, i, 1) = "/" then
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
        return left(path, idx)
    end function

    ' ---- one declaration ----------------------------------------------------

    ' Validate and normalize, in one function, so the validator and the thing
    ' it validates cannot drift apart. Returns { tpl, why } and `why` is "" on
    ' success.
    function _read_one(t, dir)
        bad = studio_templates._no
        if not is_record(t) then
            return bad("a template is not an object")
        end if
        if not has(t, "id") then
            return bad("a template has no id")
        end if
        if not is_string(t.id) then
            return bad("a template id is not a string")
        end if
        id = trim(t.id)
        if id = "" then
            return bad("a template has an empty id")
        end if
        has_text = studio_templates._str(t, "text") != ""
        from = studio_templates._str(t, "from")
        if has_text then
            if from != "" then
                ' Both, which is a file whose author meant one of them. Refused
                ' rather than resolved by a precedence rule nobody would guess.
                return bad(quote(id) + " declares both text and from")
            end if
        end if
        text = studio_templates._str(t, "text")
        if from != "" then
            ' A path BESIDE the file that declared it, and never an absolute
            ' one or a climb: a template file is a thing you can be sent, and
            ' `"from": "/etc/shadow"` would make sending one a way to read
            ' somebody's disk into a new project's README.
            if not studio_templates._safe_from(from) then
                return bad(quote(id) + ": from must be a plain relative path beside the template file")
            end if
            pf{file} = dir + "/" + from
            if not exists(pf) then
                return bad(quote(id) + ": from names " + quote(from) + ", which is not there")
            end if
            text = read(pf)
        end if
        if text = "" then
            if from = "" then
                return bad(quote(id) + " has neither text nor from")
            end if
        end if
        fr = studio_templates._read_fields(t, id)
        if fr.why != "" then
            return bad(fr.why)
        end if
        ' Every hole has to be declared. A `{{athor}}` nobody declared would
        ' otherwise survive substitution and land, verbatim, in the file the
        ' user asked for — which is exactly the silent-plausible-wrong-answer
        ' this codebase keeps meeting.
        for each part in studio_templates._parts(text)
            if part.hole then
                if part.name = "" then
                    return bad(quote(id) + " has an empty {{}} placeholder")
                end if
                if not studio_templates._declares(fr.fields, part.name) then
                    return bad(quote(id) + " uses {{" + part.name + "}}, which it does not declare")
                end if
            end if
        end for
        return { tpl: { id: id,
                        name: studio_templates._str(t, "name"),
                        description: studio_templates._str(t, "description"),
                        fields: fr.fields,
                        text: text,
                        source: "" },
                 why: "" }
    end function

    function _no(why)
        return { tpl: nothing, why: why }
    end function

    function _safe_from(from)
        if left(from, 1) = "/" then
            return false
        end if
        if left(from, 1) = "~" then
            return false
        end if
        return find(from, "..") = nothing
    end function

    function _read_fields(t, id)
        out = []
        if not has(t, "fields") then
            return { fields: out, why: "" }
        end if
        if not is_array(t.fields) then
            return { fields: [], why: quote(id) + ": fields is not a list" }
        end if
        for each f in t.fields
            if not is_record(f) then
                return { fields: [], why: quote(id) + ": a field is not an object" }
            end if
            nm = studio_templates._str(f, "name")
            if nm = "" then
                return { fields: [], why: quote(id) + ": a field has no name" }
            end if
            req = false
            if has(f, "required") then
                if f.required = true then
                    req = true
                end if
            end if
            out = append(out, { name: nm,
                                label: studio_templates._str(f, "label"),
                                required: req,
                                default: studio_templates._str(f, "default") })
        end for
        return { fields: out, why: "" }
    end function

    function _declares(fields, name)
        for each f in fields
            if f.name = name then
                return true
            end if
        end for
        return false
    end function

    function _str(r, k)
        if not has(r, k) then
            return ""
        end if
        v = r[k]
        if is_string(v) then
            return v
        end if
        return ""
    end function

    ' ---- the holes ----------------------------------------------------------

    ' Split text into the alternating literal / placeholder parts, ONCE.
    '
    ' Both `placeholders` and `render` read this, so what the validator checks
    ' and what the renderer fills are the same list by construction rather than
    ' by two scanners agreeing. Each part is { lit, name, hole }.
    '
    ' `hole` is carried separately from `name` because an EMPTY hole -- `{{}}`
    ' -- and a part that is only literal both have no name, and the first is a
    ' template bug while the second is every other part of every template. A
    ' boolean is what tells them apart; inferring it from `name != ""` is what
    ' let `{{}}` into the registry the first time this ran.
    '
    ' `{{ name }}` and `{{name}}` are the same hole: the name is trimmed, so a
    ' template author cannot be defeated by a space. A `{{` with no `}}` after
    ' it is literal text — it is far likelier to be somebody's actual braces
    ' than an unclosed placeholder, and a template that refused to load over a
    ' brace in a comment would be worse than useless.
    function _parts(text)
        out = []
        chunks = split(text, "{{")
        if count(chunks) = 1 then
            return append(out, { lit: text, name: "", hole: false })
        end if
        out = append(out, { lit: chunks[0], name: "", hole: false })
        i = 1
        while i < count(chunks)
            c = chunks[i]
            at = find(c, "}}")
            if at = nothing then
                out = append(out, { lit: "{{" + c, name: "", hole: false })
            else
                nm = trim(byte_slice(c, 0, at))
                rest = byte_slice(c, at + 2, byte_count(c))
                out = append(out, { lit: rest, name: nm, hole: true })
            end if
            i = i + 1
        end while
        return out
    end function

    ' The names a text asks for, in order, without repeats. An empty hole has
    ' no name to report; `_read_one` catches that one over `_parts` directly.
    function placeholders(text)
        seen = []
        for each p in studio_templates._parts(text)
            if p.hole then
                if p.name != "" then
                    if not contains(seen, p.name) then
                        seen = append(seen, p.name)
                    end if
                end if
            end if
        end for
        return seen
    end function

    ' ---- rendering ----------------------------------------------------------

    ' Fill a template's holes from `values`, a record of name -> string.
    '
    ' Returns { ok, text, why }. A required field with no value REFUSES rather
    ' than substituting empty, for the reason the licence refusal already gives:
    ' a file that is not the thing it claims to be is worse than no file. An
    ' optional field with no value takes its declared default, which is "" when
    ' it declared none — that IS the meaning of optional.
    '
    ' The substitution is one pass over `_parts`, so a value containing
    ' `{{other}}` is output verbatim and never looked at again.
    function render(tpl, values)
        for each f in tpl.fields
            if f.required then
                if studio_templates._value(values, f.name, "") = "" then
                    return { ok: false, text: "",
                             why: quote(tpl.id) + " needs a value for " + quote(f.name) }
                end if
            end if
        end for
        out = ""
        for each p in studio_templates._parts(tpl.text)
            if p.hole then
                out = out + studio_templates._value(values, p.name, studio_templates._default(tpl, p.name))
            end if
            out = out + p.lit
        end for
        return { ok: true, text: out, why: "" }
    end function

    function _value(values, name, fallback)
        if not is_record(values) then
            return fallback
        end if
        if not has(values, name) then
            return fallback
        end if
        v = values[name]
        if is_string(v) then
            return v
        end if
        if is_number(v) then
            return string(v)
        end if
        return fallback
    end function

    function _default(tpl, name)
        for each f in tpl.fields
            if f.name = name then
                return f.default
            end if
        end for
        return ""
    end function

    ' ---- looking things up --------------------------------------------------

    function by_id(reg, id)
        for each t in reg.templates
            if t.id = id then
                return t
            end if
        end for
        return nothing
    end function

    function ids(reg)
        out = []
        for each t in reg.templates
            out = append(out, t.id)
        end for
        return out
    end function

    ' Render by id in one call, which is what every caller actually wants.
    ' A missing id is its own refusal (`no-template`) and never an empty
    ' string: a caller that wrote "" to a file would have produced a file that
    ' is not the template, silently.
    function render_id(reg, id, values)
        t = studio_templates.by_id(reg, id)
        if t = nothing then
            return { ok: false, text: "", why: "no template called " + quote(id) }
        end if
        return studio_templates.render(t, values)
    end function

    function summary(reg)
        lines = []
        lines = append(lines, "templates: " + count(reg.templates) + " from " + count(reg.sources) + " file(s)")
        for each t in reg.templates
            fs = []
            for each f in t.fields
                mark = f.name
                if f.required then
                    mark = mark + "*"
                end if
                fs = append(fs, mark)
            end for
            line = "  " + t.id
            if count(fs) > 0 then
                line = line + " {" + join(fs, ", ") + "}"
            end if
            lines = append(lines, line)
        end for
        for each p in reg.problems
            lines = append(lines, "  ! " + p)
        end for
        return join(lines, "\n")
    end function
end library
