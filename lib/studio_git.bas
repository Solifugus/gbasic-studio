' studio_git — STU-11 optional git, over the general process API (headless). §18.
'
' Git is OPTIONAL and quiet when absent (§2.3). Everything here runs `git` through
' `process.run` — the general capability — rather than a bespoke binding, which is
' the §20 platform rule: if a thing is not about Studio, Studio does not
' reimplement it.
'
' ---------------------------------------------------------------------------
' FINDING GIT WITHOUT RISKING A RAISE.
'
' `process.run` RAISES when the executable is missing, and gBASIC cannot catch a
' raise. So Studio cannot ask "is git installed?" by trying to run it — the
' question would be answered by crashing the window of every user who does not
' have it. The only safe way is to LOOK for the file without running it — which
' is what `process.which` (0.1.0-rc3) does, and why it exists: this module's
' hand-rolled PATH walk was its prototype and its motivation.
'
' That is not defensive coding, it is the whole reason git can be optional at all.
'
' ---------------------------------------------------------------------------
' A STUDIO BRANCH IS NOT A GIT BRANCH (§2.3, §9). Nothing here creates, switches
' or names a ref on behalf of an exploratory branch. The ONE crossover the design
' allows is that a PROMOTED code overlay (STU-9) becomes an ordinary working-tree
' edit, which git then sees like any other edit — and it sees it because it is
' one, not because Studio told it anything. `git_not_branches` greps for this.
library studio_git


    load studio_permissions

    function schema_version()
        return 1
    end function

    ' How long any single git invocation may take. A repository on a dead network
    ' mount can hang forever, and a window that hangs with it is worse than one
    ' that says git did not answer.
    function timeout_s()
        return 20
    end function

    ' ---- finding the executable --------------------------------------------

    ' `process.which` (gBASIC 0.1.0-rc3) rather than a hand-rolled PATH walk.
    ' This module used to carry its own walk, twice revised: `file_type` turned
    ' out to be newer than the then-released interpreter and crashed there, and
    ' the `exists` fallback could not tell a program from a directory. `which`
    ' mirrors execvp's own rules and demands a regular file with execute
    ' permission, so both defects go away — and every program with an optional
    ' external tool now gets the same answer from the same place instead of
    ' rediscovering the same holes.
    '
    ' THIS IS WHY STUDIO NOW REQUIRES gBASIC 0.1.0-rc3. The dependency cannot be
    ' probed around: an older interpreter also lacks `has_builtin`, so there is
    ' no way to ask "do I have process.which?" without crashing — you cannot
    ' probe for the prober. A hard floor stated in the README is honest; a
    ' fallback that silently kept the weaker walk on old builds would mean the
    ' fixed defects were still shipping, just only to some people.
    function exe()
        v = env("GBASIC_STUDIO_GIT")
        if is_string(v) then
            if v != "" then
                return v
            end if
        end if
        w = process.which("git")
        if is_unknown(w) then
            return ""
        end if
        return w
    end function

    function available()
        return studio_git.exe() != ""
    end function

    ' ---- running it ---------------------------------------------------------

    ' Every git call goes through here. Returns { ok, code, out, err, why } and
    ' never raises: a missing git, a nonzero exit and a timeout are three
    ' different values, and a caller has to be able to tell them apart to say
    ' anything useful.
    function run(root, args)
        g = studio_git.exe()
        if g = "" then
            return { ok: false, code: -1, out: "", err: "", why: "git is not installed" }
        end if
        if root = "" then
            return { ok: false, code: -1, out: "", err: "", why: "no directory to run git in" }
        end if
        rd(file) = root
        if not exists(rd) then
            return { ok: false, code: -1, out: "", err: "", why: root + " does not exist" }
        end if
        r = process.run({ command: g, args: args, cwd: root, timeout: studio_git.timeout_s() })
        if r.timed_out then
            return { ok: false, code: -1, out: r.stdout, err: r.stderr,
                     why: "git " + args[0] + " did not answer within " + studio_git.timeout_s() + "s" }
        end if
        if not r.success then
            return { ok: false, code: r.exit_code, out: r.stdout, err: r.stderr,
                     why: studio_git._first_line(r.stderr) }
        end if
        return { ok: true, code: 0, out: r.stdout, err: r.stderr, why: "" }
    end function

    function _first_line(text)
        if text = "" then
            return "git failed"
        end if
        parts = split(text, "\n")
        return trim(parts[0])
    end function

    ' ---- detection ----------------------------------------------------------

    ' The repository containing `path`, or "" if there is none. Asked with
    ' `rev-parse --show-toplevel` rather than by looking for a `.git` directory:
    ' a worktree, a submodule and a repository with an external git-dir all have
    ' no `.git` folder where a naive check would look for one.
    function root_of(path)
        r = studio_git.run(path, ["rev-parse", "--show-toplevel"])
        if not r.ok then
            return ""
        end if
        return trim(r.out)
    end function

    ' Everything the UI needs to decide whether to show anything at all.
    ' `state` is one word:
    '   absent   git is not installed
    '   none     git is installed, this is not a repository
    '   repo     this is a repository
    function detect(path)
        if not studio_git.available() then
            return { state: "absent", root: "", branch: "", why: "git is not installed" }
        end if
        root = studio_git.root_of(path)
        if root = "" then
            return { state: "none", root: "", branch: "", why: "not a git repository" }
        end if
        return { state: "repo", root: root, branch: studio_git.branch_of(root), why: "" }
    end function

    ' The current branch, or a short commit for a detached HEAD, or "" in a repo
    ' with no commits yet -- which is a real and common state (`git init`, nothing
    ' committed) and must not read as an error.
    function branch_of(root)
        r = studio_git.run(root, ["symbolic-ref", "--short", "-q", "HEAD"])
        if r.ok then
            return trim(r.out)
        end if
        d = studio_git.run(root, ["rev-parse", "--short", "HEAD"])
        if d.ok then
            return "detached at " + trim(d.out)
        end if
        return ""
    end function

    ' ---- status -------------------------------------------------------------

    ' `git status --porcelain` into rows.
    '
    ' NOT `-z`. The NUL form exists so paths containing newlines survive, and
    ' without it git QUOTES such a path instead -- which is exactly as safe for
    ' parsing (one entry per line, always) and leaves the quoting visible to the
    ' user rather than silently normalised away.
    '
    ' A row: { x, y, path, old_path, label }
    '   x  the index (staged) state, y the worktree state -- git's own two-column
    '      encoding, kept rather than flattened, because "staged AND modified
    '      since" is a real state and one letter cannot say it.
    function status(root)
        r = studio_git.run(root, ["status", "--porcelain"])
        if not r.ok then
            return { ok: false, why: r.why, rows: [] }
        end if
        rows = []
        for each line in split(r.out, "\n")
            if len(line) > 3 then
                x = mid(line, 0, 1)
                y = mid(line, 1, 1)
                rest = mid(line, 3, len(line) - 3)
                old_path = ""
                path = rest
                ' A rename is "R  old -> new".
                arrow = find(rest, " -> ")
                if arrow != nothing then
                    old_path = mid(rest, 0, arrow)
                    path = mid(rest, arrow + 4, len(rest) - arrow - 4)
                end if
                rows = append(rows, { x: x, y: y, path: path, old_path: old_path,
                                      label: studio_git.status_label(x, y) })
            end if
        end for
        return { ok: true, why: "", rows: rows }
    end function

    ' git's two letters in words. Written out rather than shown raw: "??" and "AM"
    ' are obvious to someone who already knows git and opaque to everyone else,
    ' and Studio is an IDE for a language, not a git tutorial.
    function status_label(x, y)
        if x = "?" then
            return "untracked"
        end if
        if x = "!" then
            return "ignored"
        end if
        parts = []
        if x != " " then
            parts = append(parts, studio_git._word(x) + " (staged)")
        end if
        if y != " " then
            parts = append(parts, studio_git._word(y))
        end if
        if count(parts) = 0 then
            return "unchanged"
        end if
        return join(parts, ", ")
    end function

    function _word(c)
        if c = "M" then
            return "modified"
        end if
        if c = "A" then
            return "added"
        end if
        if c = "D" then
            return "deleted"
        end if
        if c = "R" then
            return "renamed"
        end if
        if c = "C" then
            return "copied"
        end if
        if c = "U" then
            return "conflicted"
        end if
        return c
    end function

    ' ---- diff, history, branches -------------------------------------------

    ' The working-tree diff, whole repo or one path. Text as git produced it:
    ' Studio does not re-render a diff, because every developer already reads
    ' this format and a prettier one would be a different format to learn.
    function diff(root, path)
        args = ["diff"]
        if path != "" then
            args = append(args, "--")
            args = append(args, path)
        end if
        r = studio_git.run(root, args)
        if not r.ok then
            return { ok: false, why: r.why, text: "" }
        end if
        return { ok: true, why: "", text: r.out }
    end function

    ' The unit separator, 0x1f. Built with `from_bytes` because gBASIC has no
    ' `char()` and no numeric string escape — and it is worth the trouble: 0x1f
    ' cannot occur in a commit subject, which a comma, a tab or a pipe all can.
    function _sep()
        return from_bytes([31])
    end function

    ' Recent commits.
    function history(root, limit)
        us = studio_git._sep()
        fmt = "%H" + us + "%h" + us + "%an" + us + "%ar" + us + "%s"
        r = studio_git.run(root, ["log", "--max-count=" + limit, "--format=" + fmt])
        if not r.ok then
            ' A repository with no commits is not a failure; it is Tuesday.
            if find(r.err, "does not have any commits") != nothing then
                return { ok: true, why: "", rows: [] }
            end if
            return { ok: false, why: r.why, rows: [] }
        end if
        rows = []
        for each line in split(r.out, "\n")
            if line != "" then
                f = split(line, studio_git._sep())
                if count(f) = 5 then
                    rows = append(rows, { hash: f[0], short: f[1], author: f[2],
                                          when: f[3], subject: f[4] })
                end if
            end if
        end for
        return { ok: true, why: "", rows: rows }
    end function

    ' The repository's branches. Listed, and NEVER created or switched on behalf
    ' of a Studio exploratory branch (§2.3) -- the two are different things and
    ' the only crossover the design allows is a promoted overlay becoming an
    ' ordinary edit.
    function branches(root)
        r = studio_git.run(root, ["branch", "--format=%(refname:short)" + studio_git._sep() + "%(HEAD)"])
        if not r.ok then
            return { ok: false, why: r.why, rows: [] }
        end if
        rows = []
        for each line in split(r.out, "\n")
            if line != "" then
                f = split(line, studio_git._sep())
                if count(f) = 2 then
                    rows = append(rows, { name: f[0], current: trim(f[1]) = "*" })
                end if
            end if
        end for
        return { ok: true, why: "", rows: rows }
    end function

    ' ---- acts ---------------------------------------------------------------

    function init(path)
        return studio_git.run(path, ["init"])
    end function

    ' Stage paths and commit. An empty `paths` stages nothing new and commits what
    ' is already staged, which is the ordinary meaning of `git commit`.
    '
    ' A message is REQUIRED. `git commit` with no message opens an editor, and an
    ' editor Studio cannot see would hang the child until the timeout kills it --
    ' which the user would experience as a commit that silently did nothing.
    function commit(root, message, paths)
        if trim(message) = "" then
            return { ok: false, code: -1, out: "", err: "", why: "a commit needs a message" }
        end if
        for each p in paths
            a = studio_git.run(root, ["add", "--", p])
            if not a.ok then
                return a
            end if
        end for
        return studio_git.run(root, ["commit", "-m", message])
    end function

    ' ---- the tier each operation belongs in (STU-10 §17) --------------------
    '
    ' Reversibility again, and git makes the line sharp: everything that stays in
    ' this repository is recoverable by someone who knows git, and everything that
    ' reaches a REMOTE is not -- a push is visible to other people the moment it
    ' lands, and no local command takes that back.
    function tier_of(op)
        if contains(["detect", "status", "diff", "history", "branches"], op) then
            return "read"
        end if
        if contains(["init", "commit", "stage"], op) then
            return "local"
        end if
        return "external"
    end function

    ' ---- summaries ----------------------------------------------------------

    ' What the pane shows. QUIET when there is nothing to be loud about (§18):
    ' outside a repository this is one line, and with git absent it is one line
    ' that does not suggest anything is broken.
    function summary(path)
        d = studio_git.detect(path)
        out = []
        if d.state = "absent" then
            out = append(out, "git: not installed")
            return out
        end if
        if d.state = "none" then
            out = append(out, "git: not a repository")
            return out
        end if
        head = "git: " + d.branch
        if d.branch = "" then
            head = "git: no commits yet"
        end if
        st = studio_git.status(d.root)
        if not st.ok then
            out = append(out, head + " — " + st.why)
            return out
        end if
        if count(st.rows) = 0 then
            out = append(out, head + " — clean")
            return out
        end if
        out = append(out, head + " — " + count(st.rows) + " change(s)")
        for each row in st.rows
            line = "  " + row.label + ": " + row.path
            if row.old_path != "" then
                line = line + " (was " + row.old_path + ")"
            end if
            out = append(out, line)
        end for
        return out
    end function

end library
