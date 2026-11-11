' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_lesson — a teaching lesson inside an ordinary gBASIC file (proposal
' §9, stage 4). Headless and toolkit-free.
'
' A lesson is the INSTRUCTOR'S file: prose, working code, exercises, their
' solutions, and the checks that say whether an exercise is done. Every
' marker is a comment, so the file still runs as plain gBASIC:
'
'   '' @exercise mean "The mean"      opens an exercise; its id and title
'   ' @solution  ...  ' @end          the instructor's answer
'   ' @starter   ...  ' @end          what the student gets in its place,
'                                     written as commented-out lines
'   ' @check     ...  ' @end          checks the student may see and run
'   ' @check private  ...  ' @end     checks only the instructor keeps
'   '' @hint ...  /  '' @tutor ...    one line each, kept with the exercise
'
' A CHECK LINE is `print <expression>`. Run as plain gBASIC it prints `true`;
' under Check Lesson the line is rewritten to report a pass or a fail, so an
' author writes the claim once and reads it both ways. Other lines in a check
' region (setting up a value to test) run as they are.
'
' THE STUDENT EDITION IS BUILT BY REMOVAL, not by hiding: the solutions and
' the private checks are not in its text at all, because a visibility flag in
' a file the student holds is not a boundary (§9). `leaks` then re-reads the
' edition for any line only a solution or a private check contained, so the
' claim is checked rather than trusted.
'
' The markers are found by LINE TEXT: a line whose first non-blank characters
' are `' @` or `'' @`. A line starting with `'` is a whole-line comment in
' gBASIC, so this is not a guess -- and it needs no parser, so it works on a
' gBASIC without `source_comments`.

library studio_lesson

    function region_tags()
        return ["solution", "starter", "check"]
    end function

    function line_tags()
        return ["exercise", "hint", "tutor"]
    end function

    ' What a check line is rewritten to call, and what it prints. Studio's own
    ' names carry the `__gbstudio` prefix, like the variable epilogue's.
    function check_fn()
        return "__gbstudio_check"
    end function

    function check_mark()
        return "@@gbstudio-check"
    end function

    ' The first line of a student edition, which is also how a later export
    ' knows the file is its own to write over.
    function edition_marker(leaf)
        return "' Student edition of " + leaf + ", made by gBASIC Studio."
    end function

    ' ---- reading the markers -------------------------------------------------

    ' `{ tag, arg }` for a marker line, or nothing. `arg` is the rest of the
    ' line after the tag, trimmed.
    function marker(raw_line)
        t = trim(raw_line)
        body = ""
        if starts_with(t, "'' @") then
            body = mid(t, 4, len(t) - 4)
        else
            if starts_with(t, "' @") then
                body = mid(t, 3, len(t) - 3)
            else
                return nothing
            end if
        end if
        tag = body
        arg = ""
        sp = find(body, " ")
        if sp != nothing then
            tag = left(body, sp)
            arg = trim(mid(body, sp, len(body) - sp))
        end if
        return { tag: lower(tag), arg: arg }
    end function

    ' `mean "The mean"` -> { id: "mean", title: "The mean" }. A title is
    ' optional; without one the id stands for it.
    function _exercise_head(arg)
        id = arg
        title = ""
        sp = find(arg, " ")
        if sp != nothing then
            id = left(arg, sp)
            title = trim(mid(arg, sp, len(arg) - sp))
        end if
        if starts_with(title, "\"") and len(title) >= 2 then
            if mid(title, len(title) - 1, 1) = "\"" then
                title = mid(title, 1, len(title) - 2)
            end if
        end if
        if title = "" then
            title = id
        end if
        return { id: id, title: title }
    end function

    function _id_ok(id)
        if id = "" then
            return false
        end if
        i = 0
        while i < len(id)
            c = mid(id, i, 1)
            if not (contains("abcdefghijklmnopqrstuvwxyz0123456789-_", c)) then
                return false
            end if
            i = i + 1
        end while
        return true
    end function

    ' Is there a `'` outside a string literal on this line? A check line
    ' cannot carry a trailing comment: it is rewritten into a call, and the
    ' comment would swallow the call's closing parenthesis.
    function _has_comment(code)
        inq = false
        i = 0
        while i < len(code)
            c = mid(code, i, 1)
            if c = "\"" then
                inq = not inq
            else
                if c = "'" and not inq then
                    return true
                end if
            end if
            i = i + 1
        end while
        return false
    end function

    ' The expression of a check line, or nothing when the line is not one.
    function check_expr(raw_line)
        t = trim(raw_line)
        if starts_with(lower(t), "print ") then
            return trim(mid(t, 6, len(t) - 6))
        end if
        return nothing
    end function

    function _problem(problems, line, message)
        return append(problems, { line: line, message: message })
    end function

    ' The lesson in a text:
    '   { problems: [{ line, message }],
    '     exercises: [{ id, title, line, solution, starter, checks, hints,
    '                   tutors, end_line }],
    '     has_solutions, is_lesson }
    ' Lines are 1-based. A region is `{ first, last }`, the lines of its two
    ' markers; `checks` carry `private` and `lines`, the check lines in them.
    ' `end_line` is where the exercise's last marker is -- where its result
    ' is shown.
    function parse(text)
        lines = split(text, "\n")
        problems = []
        exercises = []
        cur = -1
        opened = nothing
        has_solutions = false
        is_lesson = false
        n = 0
        for each raw in lines
            n = n + 1
            m = studio_lesson.marker(raw)
            if opened != nothing then
                if m != nothing then
                    if m.tag = "end" then
                        ex = exercises[cur]
                        reg = { first: opened.line, last: n }
                        if opened.tag = "solution" then
                            if ex.solution != nothing then
                                problems = studio_lesson._problem(problems, opened.line, "exercise " + ex.id + " has a second @solution")
                            end if
                            ex.solution = reg
                            has_solutions = true
                        end if
                        if opened.tag = "starter" then
                            if ex.starter != nothing then
                                problems = studio_lesson._problem(problems, opened.line, "exercise " + ex.id + " has a second @starter")
                            end if
                            ex.starter = reg
                        end if
                        if opened.tag = "check" then
                            reg.private = opened.private
                            reg.lines = opened.checks
                            if count(opened.checks) = 0 then
                                problems = studio_lesson._problem(problems, opened.line, "this @check has no `print <expression>` line to check")
                            end if
                            ex.checks = append(ex.checks, reg)
                            if opened.private then
                                has_solutions = true
                            end if
                        end if
                        ex.end_line = n
                        exercises[cur] = ex
                        opened = nothing
                    else
                        problems = studio_lesson._problem(problems, n, "@" + m.tag + " inside an open @" + opened.tag + " (line " + string(opened.line) + ") -- close it with ' @end first")
                    end if
                else
                    if opened.tag = "starter" then
                        lt = trim(raw)
                        if lt != "" and not starts_with(lt, "'") then
                            problems = studio_lesson._problem(problems, n, "a @starter line must be commented out (it is the student's code, not the instructor's)")
                        end if
                    end if
                    if opened.tag = "check" then
                        e = studio_lesson.check_expr(raw)
                        if e != nothing then
                            if e = "" then
                                problems = studio_lesson._problem(problems, n, "a check line prints nothing")
                            else
                                if studio_lesson._has_comment(e) then
                                    problems = studio_lesson._problem(problems, n, "a check line cannot end in a comment -- put the comment on its own line")
                                else
                                    opened.checks = append(opened.checks, n)
                                end if
                            end if
                        end if
                    end if
                end if
            else
                if m != nothing then
                    is_lesson = true
                    if m.tag = "exercise" then
                        h = studio_lesson._exercise_head(m.arg)
                        if not studio_lesson._id_ok(h.id) then
                            problems = studio_lesson._problem(problems, n, "an exercise id is lower-case letters, digits, - and _ (got \"" + h.id + "\")")
                        end if
                        for each x in exercises
                            if x.id = h.id then
                                problems = studio_lesson._problem(problems, n, "exercise " + h.id + " is already defined at line " + string(x.line))
                            end if
                        end for
                        exercises = append(exercises, { id: h.id, title: h.title, line: n,
                                                        solution: nothing, starter: nothing,
                                                        checks: [], hints: [], tutors: [],
                                                        end_line: n })
                        cur = count(exercises) - 1
                    else
                        if m.tag = "end" then
                            problems = studio_lesson._problem(problems, n, "@end with nothing open")
                        else
                            if contains(studio_lesson.region_tags(), m.tag) or m.tag = "hint" or m.tag = "tutor" then
                                if cur < 0 then
                                    problems = studio_lesson._problem(problems, n, "@" + m.tag + " before any @exercise")
                                else
                                    if m.tag = "hint" or m.tag = "tutor" then
                                        ex = exercises[cur]
                                        if m.tag = "hint" then
                                            ex.hints = append(ex.hints, m.arg)
                                        else
                                            ex.tutors = append(ex.tutors, m.arg)
                                        end if
                                        ex.end_line = n
                                        exercises[cur] = ex
                                    else
                                        priv = false
                                        if m.tag = "check" then
                                            if m.arg = "private" then
                                                priv = true
                                            else
                                                if m.arg != "" then
                                                    problems = studio_lesson._problem(problems, n, "@check takes nothing or `private` (got \"" + m.arg + "\")")
                                                end if
                                            end if
                                        end if
                                        opened = { tag: m.tag, line: n, private: priv, checks: [] }
                                    end if
                                end if
                            else
                                problems = studio_lesson._problem(problems, n, "@" + m.tag + " is not a lesson marker (exercise, solution, starter, check, end, hint, tutor)")
                            end if
                        end if
                    end if
                end if
            end if
        end for
        if opened != nothing then
            problems = studio_lesson._problem(problems, opened.line, "@" + opened.tag + " is never closed with ' @end")
        end if
        for each x in exercises
            if count(x.checks) = 0 then
                problems = studio_lesson._problem(problems, x.line, "exercise " + x.id + " has no @check, so nothing can say whether it is done")
            end if
            if x.starter != nothing and x.solution = nothing then
                problems = studio_lesson._problem(problems, x.starter.first, "exercise " + x.id + " has a @starter but no @solution for it to replace")
            end if
        end for
        return { problems: problems, exercises: exercises,
                 has_solutions: has_solutions, is_lesson: is_lesson }
    end function

    ' ---- the student edition ---------------------------------------------------

    ' A starter line, uncommented: the `'` and one space after it removed,
    ' with the indentation in front of the `'` kept.
    function _uncomment(raw)
        i = 0
        while i < len(raw)
            c = mid(raw, i, 1)
            if c != " " and c != "\t" then
                break
            end if
            i = i + 1
        end while
        lead = left(raw, i)
        rest = mid(raw, i, len(raw) - i)
        if starts_with(rest, "'") then
            rest = mid(rest, 1, len(rest) - 1)
            if starts_with(rest, " ") then
                rest = mid(rest, 1, len(rest) - 1)
            end if
        end if
        return lead + rest
    end function

    ' The edition's text: every solution REPLACED by its starter, uncommented
    ' (or by nothing), every starter removed from where it was written, every
    ' private check removed whole. Public checks stay, markers and all, so
    ' Check Lesson can find them in the student's copy.
    function student_text(text, lesson, leaf)
        lines = split(text, "\n")
        drop = {}
        put = {}
        for each x in lesson.exercises
            if x.solution != nothing then
                k = x.solution.first
                while k <= x.solution.last
                    drop[string(k)] = true
                    k = k + 1
                end while
                repl = []
                if x.starter != nothing then
                    k = x.starter.first + 1
                    while k < x.starter.last
                        repl = append(repl, studio_lesson._uncomment(lines[k - 1]))
                        k = k + 1
                    end while
                end if
                put[string(x.solution.first)] = repl
            end if
            if x.starter != nothing then
                k = x.starter.first
                while k <= x.starter.last
                    drop[string(k)] = true
                    k = k + 1
                end while
            end if
            for each c in x.checks
                if c.private then
                    k = c.first
                    while k <= c.last
                        drop[string(k)] = true
                        k = k + 1
                    end while
                end if
            end for
        end for
        out = [studio_lesson.edition_marker(leaf)]
        n = 0
        for each raw in lines
            n = n + 1
            r = put[string(n)]
            if not is_unknown(r) then
                for each l in r
                    out = append(out, l)
                end for
            end if
            if is_unknown(drop[string(n)]) then
                out = append(out, raw)
            end if
        end for
        return join(out, "\n")
    end function

    ' Every line that ONLY a solution or a private check contained and that
    ' the edition still holds -- which must be none. "Only": `end function`
    ' is in a solution and in the starter too, and is no secret. Blank and
    ' one-character lines are not counted either way.
    function leaks(text, lesson, edition)
        lines = split(text, "\n")
        secret = {}
        for each x in lesson.exercises
            regs = []
            if x.solution != nothing then
                regs = append(regs, x.solution)
            end if
            for each c in x.checks
                if c.private then
                    regs = append(regs, c)
                end if
            end for
            for each g in regs
                k = g.first + 1
                while k < g.last
                    secret[string(k)] = true
                    k = k + 1
                end while
            end for
        end for
        open_text = {}
        n = 0
        for each raw in lines
            n = n + 1
            if is_unknown(secret[string(n)]) then
                open_text[trim(raw)] = true
            end if
        end for
        for each x in lesson.exercises
            if x.starter != nothing then
                k = x.starter.first + 1
                while k < x.starter.last
                    open_text[trim(studio_lesson._uncomment(lines[k - 1]))] = true
                    k = k + 1
                end while
            end if
        end for
        have = {}
        for each raw in split(edition, "\n")
            have[trim(raw)] = true
        end for
        out = []
        n = 0
        for each raw in lines
            n = n + 1
            t = trim(raw)
            if not is_unknown(secret[string(n)]) and len(t) > 1 then
                if not is_unknown(have[t]) and is_unknown(open_text[t]) then
                    out = append(out, n)
                end if
            end if
        end for
        return out
    end function

    ' ---- the checks, run -------------------------------------------------------

    ' Prepended to the program, so the call resolves wherever the checks are.
    function prelude()
        f = studio_lesson.check_fn()
        mk = studio_lesson.check_mark()
        q = "\""
        l = ["function " + f + "(at, ok)",
             "    if is_boolean(ok) then",
             "        if ok then",
             "            print " + q + mk + " pass " + q + " + at",
             "            return nothing",
             "        end if",
             "    end if",
             "    print " + q + mk + " fail " + q + " + at",
             "end function"]
        return join(l, "\n") + "\n"
    end function

    function prelude_lines()
        return count(split(studio_lesson.prelude(), "\n")) - 1
    end function

    ' The program that checks ONE exercise: the whole text, with that
    ' exercise's check lines rewritten into calls and every OTHER check region
    ' blanked -- line for line, so a line number still means the same line.
    ' A private region is blanked too unless `private` is asked for.
    function check_program(text, lesson, ex_id, private)
        lines = split(text, "\n")
        f = studio_lesson.check_fn()
        for each x in lesson.exercises
            for each c in x.checks
                mine = (x.id = ex_id) and (private or not c.private)
                if mine then
                    for each k in c.lines
                        raw = lines[k - 1]
                        i = find(raw, "print")
                        lead = left(raw, i)
                        lines[k - 1] = lead + f + "(" + string(k) + ", " + studio_lesson.check_expr(raw) + ")"
                    end for
                else
                    k = c.first
                    while k <= c.last
                        lines[k - 1] = ""
                        k = k + 1
                    end while
                end if
            end for
        end for
        return studio_lesson.prelude() + join(lines, "\n")
    end function

    ' The check lines an exercise's run will report on.
    function expected(lesson, ex_id, private)
        out = []
        for each x in lesson.exercises
            if x.id = ex_id then
                for each c in x.checks
                    if private or not c.private then
                        for each k in c.lines
                            out = append(out, k)
                        end for
                    end if
                end for
            end if
        end for
        return out
    end function

    ' One exercise's run, read: `{ outcome, passed, failed, missing, message }`
    ' where outcome is pass | fail | error. `run` is `{ stdout, stderr,
    ' exit_code }`. A run that died part way is an ERROR whatever passed
    ' before it, and the message names the line in the LESSON (the prelude's
    ' lines taken off).
    function read_run(run, want)
        mk = studio_lesson.check_mark() + " "
        passed = []
        failed = []
        for each l in split(run.stdout, "\n")
            if starts_with(l, mk) then
                w = split(mid(l, len(mk), len(l) - len(mk)), " ")
                if w[0] = "pass" then
                    passed = append(passed, number(w[1]))
                else
                    failed = append(failed, number(w[1]))
                end if
            end if
        end for
        missing = []
        for each k in want
            if not contains(passed, k) and not contains(failed, k) then
                missing = append(missing, k)
            end if
        end for
        outcome = "pass"
        message = ""
        if count(failed) > 0 then
            outcome = "fail"
        end if
        if run.exit_code != 0 then
            outcome = "error"
            message = studio_lesson._message(run.stderr)
        else
            if count(missing) > 0 then
                outcome = "error"
                parts = []
                for each k in missing
                    parts = append(parts, string(k))
                end for
                message = "the check on line " + join(parts, ", ") + " never ran"
            end if
        end if
        return { outcome: outcome, passed: passed, failed: failed,
                 missing: missing, message: message }
    end function

    ' A diagnostic's first line, with the program's path dropped and its line
    ' number moved back onto the lesson: `runtime error at /x/y.bas:12:5: m`
    ' becomes `line 3: m` when the prelude was nine lines.
    function _message(stderr)
        first = ""
        for each l in split(stderr, "\n")
            if trim(l) != "" then
                first = trim(l)
                break
            end if
        end for
        if first = "" then
            return "the program stopped without saying why"
        end if
        at = find(first, ".bas:")
        if at = nothing then
            return first
        end if
        rest = mid(first, at + 5, len(first) - at - 5)
        parts = split(rest, ":")
        if count(parts) < 3 then
            return first
        end if
        ln = number(parts[0]) - studio_lesson.prelude_lines()
        msg = trim(join(studio_lesson._tail(parts, 2), ":"))
        return "line " + string(ln) + ": " + msg
    end function

    function _tail(a, from)
        out = []
        i = from
        while i < count(a)
            out = append(out, a[i])
            i = i + 1
        end while
        return out
    end function

    ' ---- in the prose view -----------------------------------------------------

    ' A `''` line's Markdown when it is a lesson marker, or nothing. The prose
    ' view would otherwise show `@exercise mean "The mean"` as a sentence.
    function prose_line(t)
        if not starts_with(t, "@") then
            return nothing
        end if
        m = studio_lesson.marker("'' " + t)
        if m = nothing then
            return nothing
        end if
        if m.tag = "exercise" then
            h = studio_lesson._exercise_head(m.arg)
            return "### Exercise: " + h.title
        end if
        if m.tag = "hint" then
            return "> **Hint:** " + m.arg
        end if
        if m.tag = "tutor" then
            return "> **For the tutor:** " + m.arg
        end if
        return nothing
    end function

end library
