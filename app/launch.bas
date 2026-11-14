' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' app/launch.bas — starts Studio, on any platform. `studio_launch` decides
' the plan; this carries it out and is the only part that touches the
' machine: whether the interpreter is there, making a figure's fresh home,
' asking fontconfig whether the font pin took.
'
'   gbasic app/launch.bas --plan-sh <args>   prints the plan as POSIX shell,
'                                            for `./studio` to exec
'   gbasic app/launch.bas --run <args>       runs it, the terminal passed
'                                            through (`studio.cmd`)
'
' Both stubs run this from Studio's own directory with `GBASIC_PATH=lib`, and
' set `GBASIC_STUDIO_CWD` to where the user was before they moved there.

load persist
load studio_paths
load studio_launch

' The environment the plan reads, as a record of the variables that are set.
function launch_env()
    e = {}
    for each n in ["GBASIC", "GBASIC_STDLIB", "HOME", "LOCALAPPDATA", "USERPROFILE",
                   "XDG_DATA_DIRS", "QT_QPA_PLATFORM", "GBASIC_SYNTAX_PATH"]
        v = env(n)
        if is_string(v) then
            e[n] = v
        end if
    end for
    return e
end function

' The first font fontconfig can see that Studio does not ship, or "". A
' fonts.conf fontconfig cannot parse is DROPPED with one line on stderr and
' the host's own config used instead -- the host's fonts in a figure, with
' nothing said -- so the pin's own claim is asked: EVERY font fontconfig
' sees is one Studio ships. No fc-list, nothing to ask.
function stray_font(p)
    w = process.which("fc-list")
    if not is_string(w) then
        return ""
    end if
    r = process.run({ command: w, args: ["-f", "%{file}\n"], env: p.env })
    mine = p.env.GBASIC_STUDIO_SHARE + "/fonts/"
    for each l in split(r.stdout, "\n")
        if l != "" and not starts_with(l, mine) then
            return l
        end if
    end for
    return ""
end function

' The plan, with every check the machine has to answer made, and a figure's
' home made if it needs one.
function prepared(user)
    os = studio_paths.os_name()
    root = studio_paths.from_os(string(real_path(".")))
    cwd = env("GBASIC_STUDIO_CWD")
    if not is_string(cwd) then
        cwd = root
    end if
    inp = { os: os, args: user, env: launch_env(), root: root, cwd: cwd }
    p = studio_launch.plan(inp)
    if p.refuse != "" then
        return p
    end if
    for each c in p.checks
        ref{file} = c.path
        if not exists(ref) then
            p.refuse = c.message
            p.status = 1
            return p
        end if
    end for
    if p.figure then
        conf = p.env.GBASIC_STUDIO_SHARE + "/fonts/fonts.conf"
        cf{file} = conf
        if not exists(cf) then
            p.refuse = "shoot: no pinned fonts at " + p.env.GBASIC_STUDIO_SHARE + "/fonts -- a figure would use this machine's"
            p.status = 2
            return p
        end if
        t = temp_dir({ prefix: "gbasic-studio-figure-" })
        p = studio_launch.with_figure(p, studio_paths.from_os(string(t)), inp)
        s = stray_font(p)
        if s != "" then
            z = remove_tree(t)
            p.refuse = "shoot: the pinned fonts did not take (fontconfig also sees " + s + "); is " + conf + " valid XML?"
            p.status = 2
            return p
        end if
    end if
    for each d in p.dirs
        persist.ensure_dir(d)
    end for
    return p
end function

' Run the plan as a child and leave with its status. A child that died of a
' signal leaves as a shell would report it, 128 + the signal.
function run_plan(p)
    if p.refuse != "" then
        for each l in split(p.refuse, "\n")
            print to error l
        end for
        exit(p.status)
    end if
    envr = p.env
    for each n in p.unset
        envr[n] = nothing
    end for
    on error goto next
    h = process.start({ command: p.command, args: p.args, env: envr,
                        stdout: "inherit", stderr: "inherit" })
    if error then
        print to error "launch: this gBASIC cannot pass the terminal to Studio (process.start's stdout: \"inherit\", 2026-11-09): " + error.message
        exit(1)
    end if
    on error stop
    s = process.wait(h)
    if p.cleanup then
        fr{dir} = p.figure_root
        z = remove_tree(fr)
    end if
    if s.signal != 0 then
        exit(128 + s.signal)
    end if
    exit(s.exit_code)
end function

program main(args)
    how = ""
    user = []
    i = 0
    for each a in args
        if i = 0 then
            how = a
        else
            user = append(user, a)
        end if
        i = i + 1
    end for
    p = prepared(user)
    if how = "--plan-sh" then
        print studio_launch.sh_text(p)
    else
        if how = "--run" then
            z = run_plan(p)
        else
            print to error "usage: gbasic app/launch.bas --plan-sh|--run [mode] [home] [folder]"
            exit(2)
        end if
    end if
end program
