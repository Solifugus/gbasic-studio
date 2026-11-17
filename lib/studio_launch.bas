' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' studio_launch — how Studio is started, decided once for every platform
' (headless).
'
' `./studio` was 198 lines of bash: where the interpreter and stdlib are,
' which entry point a mode belongs to, the environment Studio expects, and a
' figure's sealed world for `shoot` and a fresh `mcp`. None of that is about
' bash, and Windows has no bash, so it lives here as ONE function from the
' launch's inputs to a PLAN -- `{ refuse, env, unset, command, args, dirs,
' figure, cleanup }` -- and `app/launch.bas` carries it out.
'
' WHY A PLAN AND NOT A CHILD, on POSIX: gBASIC has no `exec`, and a child
' started by `process.start` is put in a process group of its own. Measured:
' a Ctrl+C to the terminal's foreground group ends the launcher and leaves
' the window running, an orphan. So on POSIX the plan is printed as shell
' (`sh_text`) and the stub `exec`s it, exactly as the bash launcher did; on
' Windows the launcher runs the child itself. An `exec` in gBASIC would make
' the shell step unnecessary (`docs/gbasic_asks.md`).
'
' Everything that TOUCHES the machine -- whether a file exists, making the
' fresh home, asking fontconfig -- is the adapter's. This decides only, so
' `launch_plan` can assert a Windows plan on Linux.

library studio_launch
    load studio_paths

    ' The modes that are headless and load no toolkit: app/studio_cli.bas.
    function headless(mode)
        if contains(["startup", "build", "roundtrip", "stress", "cycles"], mode) then
            return true
        end if
        return starts_with(mode, "stu1_") or starts_with(mode, "stu2_")
    end function

    function _get(env, name)
        v = env[name]
        if is_unknown(v) then
            return ""
        end if
        if not is_string(v) then
            return ""
        end if
        return v
    end function

    ' `p` made absolute against `base`, both in Studio's `/` form.
    function _against(p, base, os)
        q = studio_paths.from_os_on(p, os)
        if q = "" or studio_paths.is_absolute_on(q, os) then
            return q
        end if
        return studio_paths.from_os_on(base, os) + "/" + q
    end function

    function _dir_of(p)
        i = len(p) - 1
        while i >= 0
            if mid(p, i, 1) = "/" then
                if i = 0 then
                    return "/"
                end if
                return left(p, i)
            end if
            i = i - 1
        end while
        return "."
    end function

    ' Where Studio keeps its home when none is named. POSIX: `~/.gbasic-studio`.
    ' Windows sets no HOME in PowerShell or cmd, so it is beside gBASIC's own
    ' per-user state, `%LOCALAPPDATA%` (gBASIC's `windows_port_status.md`),
    ' and the profile directory only when that is missing.
    function default_home(env, os)
        if os = "windows" then
            la = studio_launch._get(env, "LOCALAPPDATA")
            if la != "" then
                return studio_paths.from_os_on(la, os) + "/gbasic-studio"
            end if
            up = studio_launch._get(env, "USERPROFILE")
            if up != "" then
                return studio_paths.from_os_on(up, os) + "/.gbasic-studio"
            end if
        end if
        return studio_launch._get(env, "HOME") + "/.gbasic-studio"
    end function

    ' The plan. `inp` is `{ os, args, env, root, cwd }`: the platform, the
    ' user's arguments, the environment as it is, Studio's own directory
    ' (where the stub put us) and the directory the user ran it from.
    function plan(inp)
        os = inp.os
        env = inp.env
        exe = ".exe"
        if os != "windows" then
            exe = ""
        end if
        gb = studio_launch._get(env, "GBASIC")
        if gb = "" then
            gb = "../gbasic/gbasic" + exe
        end if
        gb = studio_paths.from_os_on(gb, os)
        stdlib = studio_launch._get(env, "GBASIC_STDLIB")
        if stdlib = "" then
            stdlib = "../gbasic/stdlib"
        end if
        stdlib = studio_paths.from_os_on(stdlib, os)
        root = studio_paths.from_os_on(inp.root, os)
        cwd = studio_paths.from_os_on(inp.cwd, os)
        a = inp.args
        mode = "gui"
        if count(a) > 0 then
            if a[0] != "" then
                mode = a[0]
            end if
        end if
        p = { refuse: "", status: 0, env: {}, unset: [], command: gb, args: [],
              dirs: [], figure: false, cleanup: false, wait: false,
              checks: [{ path: gb, kind: "file",
                         message: "no gbasic interpreter at " + gb + "\nset GBASIC=/path/to/gbasic (and GBASIC_STDLIB=/path/to/stdlib)" },
                       { path: stdlib, kind: "dir",
                         message: "no gBASIC stdlib at " + stdlib + "\nStudio needs persist and filetree from it (the window itself is the qt module)" }] }

        ' THE ENVIRONMENT, as `./studio` has always set it. A list separator is
        ' the platform's, and on Windows `GBASIC_PATH` holds only the RELATIVE
        ' `lib`: gBASIC splits that variable at `:`, which an absolute Windows
        ' path contains (`docs/gbasic_asks.md`). gBASIC finds its own stdlib.
        sep = ":"
        if os = "windows" then
            sep = ";"
        end if
        p.env.GBASIC = gb
        p.env.GBASIC_STUDIO_CWD = cwd
        if os = "windows" then
            p.env.GBASIC_PATH = "lib"
        else
            p.env.GBASIC_PATH = "lib:" + stdlib
        end if
        xdg = studio_launch._get(env, "XDG_DATA_DIRS")
        if xdg = "" then
            xdg = "/usr/local/share:/usr/share"
            if os = "windows" then
                xdg = ""
            end if
        end if
        p.env.XDG_DATA_DIRS = root + "/share"
        if xdg != "" then
            p.env.XDG_DATA_DIRS = p.env.XDG_DATA_DIRS + sep + xdg
        end if
        p.env.GBASIC_STDLIB = stdlib
        p.env.GBASIC_STUDIO_VIEWERS = root + "/viewers"
        p.env.GBASIC_STUDIO_SHARE = root + "/share"

        entry = "app/studio.bas"
        if studio_launch.headless(mode) then
            entry = "app/studio_cli.bas"
        else
            if mode = "qt" then
                mode = "gui"
            end if
            syn = studio_launch._get(env, "GBASIC_SYNTAX_PATH")
            if syn = "" then
                syn = studio_launch._dir_of(stdlib) + "/editors/kate"
            end if
            p.env.GBASIC_SYNTAX_PATH = studio_paths.from_os_on(syn, os)
        end if

        ' `./studio shoot <script> <out-dir>`: a figure, in a fresh home.
        if mode = "shoot" then
            if count(a) < 3 then
                p.refuse = "usage: ./studio shoot <script> <out-dir>"
                p.status = 2
                return p
            end if
            if os = "windows" then
                p.refuse = "shoot: figures are drawn on Linux -- their fonts are pinned through fontconfig, which Qt on Windows does not use"
                p.status = 2
                return p
            end if
            out = studio_launch._against(a[2], cwd, os)
            p.dirs = [out]
            p.figure = true
            p.cleanup = true
            p.wait = true
            p.args = [entry, "shoot", "{figure_home}", studio_launch._against(a[1], cwd, os), out]
            return p
        end if

        ' `./studio mcp [home|-] [folder]`: stdout IS the protocol, so
        ' `--line-buffered`; no home, or `-`, is a fresh one, made like a
        ' figure's (offscreen) and removed after.
        folder = ""
        if count(a) > 2 then
            folder = studio_launch._against(a[2], cwd, os)
        end if
        ' A named home's window is VISIBLE (the platform's own), so a person
        ' can watch an assistant work in it; a fresh home is a figure's world
        ' and stays offscreen (`with_figure`). QT_QPA_PLATFORM wins either way.
        if mode = "mcp" then
            h = ""
            if count(a) > 1 then
                h = a[1]
            end if
            if h = "" or h = "-" then
                if os = "windows" then
                    p.refuse = "mcp: a fresh home is a figure's world, which is drawn on Linux -- name a home instead"
                    p.status = 2
                    return p
                end if
                p.figure = true
                p.cleanup = true
                p.env.GBASIC_STUDIO_MCP_FRESH = "1"
                h = "{figure_home}"
            else
                h = studio_launch._against(h, cwd, os)
                p.dirs = [h]
            end if
            p.wait = true
            p.args = ["--line-buffered", entry, "mcp", h, folder]
            return p
        end if

        ' Everything else: `<mode> <home> [folder [more...]]`. A RELATIVE home
        ' is the user's, like the folder -- the bash launcher resolved it
        ' against Studio's own directory, which was never what anyone meant.
        home = studio_launch.default_home(env, os)
        if count(a) > 1 then
            if a[1] != "" then
                home = studio_launch._against(a[1], cwd, os)
            end if
        end if
        p.args = [entry, mode, home]
        ' Only pass a third argument when there is one: several modes read
        ' args[2] as their own parameter, and an empty string is not nothing.
        if count(a) > 3 then
            p.args = append(p.args, folder)
            i = 3
            while i < count(a)
                p.args = append(p.args, a[i])
                i = i + 1
            end while
        else
            if folder != "" then
                p.args = append(p.args, folder)
            end if
        end if
        return p
    end function

    ' A figure's world, added to a plan once the adapter has made the fresh
    ' directory `froot`: a home that is HOME too, git and the login kept out,
    ' offscreen, UTC, the per-user XDG places inside it, and the pinned fonts.
    function with_figure(p, froot, inp)
        p.env.HOME = froot
        p.env.GIT_CONFIG_GLOBAL = "/dev/null"
        p.env.GIT_CONFIG_NOSYSTEM = "1"
        p.unset = ["USER", "LOGNAME"]
        if studio_launch._get(inp.env, "QT_QPA_PLATFORM") = "" then
            p.env.QT_QPA_PLATFORM = "offscreen"
        end if
        p.env.TZ = "UTC"
        p.env.XDG_CONFIG_HOME = froot + "/.config"
        p.env.XDG_DATA_HOME = froot + "/.local/share"
        p.env.XDG_CACHE_HOME = froot + "/.cache"
        p.env.FONTCONFIG_FILE = p.env.GBASIC_STUDIO_SHARE + "/fonts/fonts.conf"
        fh = froot + "/.gbasic-studio"
        p.dirs = append(p.dirs, fh)
        out = []
        for each x in p.args
            out = append(out, replace(x, "{figure_home}", fh))
        end for
        p.args = out
        p.figure_root = froot
        return p
    end function

    ' ---- the plan as POSIX shell, for the stub to `exec` -----------------------

    ' One shell word: single-quoted, a `'` written as `'\''`. Nothing inside
    ' single quotes is expanded, so this is the whole of the quoting.
    function sh_quote(s)
        return "'" + replace(s, "'", "'\\''") + "'"
    end function

    function sh_text(p)
        out = []
        if p.refuse != "" then
            for each l in split(p.refuse, "\n")
                out = append(out, "printf '%s\\n' " + studio_launch.sh_quote(l) + " >&2")
            end for
            out = append(out, "exit " + string(p.status))
            return join(out, "\n") + "\n"
        end if
        names = keys(p.env)
        names = sort(names)
        for each k in names
            out = append(out, "export " + k + "=" + studio_launch.sh_quote(p.env[k]))
        end for
        if count(p.unset) > 0 then
            out = append(out, "unset " + join(p.unset, " "))
        end if
        words = [studio_launch.sh_quote(p.command)]
        for each x in p.args
            words = append(words, studio_launch.sh_quote(x))
        end for
        if p.cleanup then
            ' Not `exec`: the fresh home is removed after, which an exec'd
            ' shell never reaches.
            out = append(out, "trap " + studio_launch.sh_quote("rm -rf " + studio_launch.sh_quote(p.figure_root)) + " EXIT")
            out = append(out, join(words, " "))
            out = append(out, "exit $?")
        else
            out = append(out, "exec " + join(words, " "))
        end if
        return join(out, "\n") + "\n"
    end function

end library
