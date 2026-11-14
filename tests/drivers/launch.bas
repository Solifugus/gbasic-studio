' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' The launch plan, decided for Linux and for Windows from fixed inputs, so the
' Windows plan is asserted on a machine that is not Windows. `quote` prints
' shell that bash itself reads back; the runner pipes it through bash.

load studio_launch

function show(title, inp)
  print "== " + title
  p = studio_launch.plan(inp)
  if p.figure then
    p = studio_launch.with_figure(p, "/tmp/fig", inp)
  end if
  if inp.os = "windows" then
    if p.refuse != "" then
      print "  refused (" + p.status + "): " + p.refuse
      return nothing
    end if
    for each k in sort(keys(p.env))
      print "  " + k + "=" + p.env[k]
    end for
    print "  run: " + p.command + " " + join(p.args, " ")
    return nothing
  end if
  for each l in split(studio_launch.sh_text(p), "\n")
    if l != "" then
      print "  " + l
    end if
  end for
  print "  checks: " + p.checks[0].path + " (file), " + p.checks[1].path + " (dir); make: " + join(p.dirs, ", ")
  return nothing
end function

program main(args)
  mode = args[0]
  if mode = "plan" then
    lx = { HOME: "/home/u", XDG_DATA_DIRS: "/usr/share" }
    root = "/opt/studio"
    cwd = "/home/u/work"
    show("linux, no arguments: the window, in ~/.gbasic-studio", { os: "linux", args: [], env: lx, root: root, cwd: cwd })
    show("linux, a headless mode and a relative home", { os: "linux", args: ["startup", "h"], env: lx, root: root, cwd: cwd })
    show("linux, qt is gui, a relative folder, and more for the mode", { os: "linux", args: ["qt", "/h", "proj", "main.bas", "3"], env: { HOME: "/home/u", GBASIC: "/usr/local/bin/gbasic", GBASIC_STDLIB: "/usr/local/share/gbasic/stdlib" }, root: root, cwd: cwd })
    show("linux, shoot: a figure's world", { os: "linux", args: ["shoot", "s.shot", "out"], env: lx, root: root, cwd: cwd })
    show("linux, shoot without its arguments", { os: "linux", args: ["shoot"], env: lx, root: root, cwd: cwd })
    show("linux, mcp in a fresh home", { os: "linux", args: ["mcp", "-"], env: lx, root: root, cwd: cwd })
    show("linux, mcp in a named home, offscreen already chosen", { os: "linux", args: ["mcp", "h", "p"], env: { HOME: "/home/u", QT_QPA_PLATFORM: "xcb" }, root: root, cwd: cwd })
    wn = { LOCALAPPDATA: "C:\\Users\\u\\AppData\\Local", USERPROFILE: "C:\\Users\\u", GBASIC: "C:\\gb\\gbasic.exe", GBASIC_STDLIB: "C:\\gb\\stdlib" }
    wroot = "C:\\studio"
    wcwd = "D:\\work"
    show("windows, no arguments: the home beside gBASIC's own per-user state", { os: "windows", args: [], env: wn, root: wroot, cwd: wcwd })
    show("windows, a relative folder on another drive, and an absolute home", { os: "windows", args: ["gui", "E:\\homes\\h", "proj"], env: wn, root: wroot, cwd: wcwd })
    show("windows, no LOCALAPPDATA, no GBASIC", { os: "windows", args: ["startup"], env: { USERPROFILE: "C:\\Users\\u" }, root: wroot, cwd: wcwd })
    show("windows, shoot", { os: "windows", args: ["shoot", "s.shot", "out"], env: wn, root: wroot, cwd: wcwd })
    show("windows, mcp in a fresh home", { os: "windows", args: ["mcp"], env: wn, root: wroot, cwd: wcwd })
    show("windows, mcp in a named home", { os: "windows", args: ["mcp", "h"], env: wn, root: wroot, cwd: wcwd })
  end if
  if mode = "quote" then
    for each s in ["plain", "two words", "it's", "'", "''", "$HOME", "`date`", "a\\b", "*", "semi;colon", "new\nline", ""]
      print "printf '[%s]\\n' " + studio_launch.sh_quote(s)
    end for
  end if
end program
