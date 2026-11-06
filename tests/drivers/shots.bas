' SPDX-License-Identifier: Apache-2.0
' Copyright 2026 Matthew C. Tedder. See LICENSE.

' The shot-script checker, headless: what `./studio shoot` refuses BEFORE it
' opens anything, and the small decisions under it. The window half is the
' `shoot_run` tier, which runs a real script offscreen.
'
' args: mode

function check(label, text)
  r = studio_shots.script_steps(text)
  print "-- " + label
  for each st in r.steps
    print "  step line " + string(st.line) + ": " + st.tool
  end for
  for each e in r.errors
    print "  refused " + e
  end for
  return r
end function

program main(args)
  load studio_tools
  load studio_ui
  load studio_shots

  nl = chr(10)

  r = check("a good script, with comments and blank lines",
    "# a figure" + nl + nl +
    "{\"tool\": \"frame\", \"args\": {\"width\": 900, \"theme\": \"system\", \"zoom\": 1.15}}" + nl +
    "{\"tool\": \"open_samples\"}" + nl +
    "{\"tool\": \"open_document\", \"args\": {\"path\": \"02_tables.bas\"}}" + nl +
    "{\"tool\": \"caret_to\", \"args\": {\"text\": \"sales = []\"}}" + nl +
    "{\"tool\": \"execute_section\"}" + nl +
    "{\"tool\": \"list_sections\"}" + nl +
    "   " + nl +
    "{\"tool\": \"capture\", \"args\": {\"part\": \"results\", \"file\": \"r.png\", \"scale\": 2}}")
  f = studio_shots.frame_of(r.steps)
  print "  frame: " + string(f.width) + "x" + string(f.height) + " " + f.theme + " zoom " + string(f.zoom) + " whitespace " + string(f.whitespace)

  r = check("no frame: the defaults",
    "{\"tool\": \"open_samples\"}")
  f = studio_shots.frame_of(r.steps)
  print "  frame: " + string(f.width) + "x" + string(f.height) + " " + f.theme + " zoom " + string(f.zoom) + " whitespace " + string(f.whitespace)

  r = check("every way a line is refused, all reported at once",
    "{\"tool\": \"open_samples\"}" + nl +
    "{\"tool\": \"frame\"}" + nl +
    "not json" + nl +
    "[1, 2]" + nl +
    "{\"args\": {}}" + nl +
    "{\"tool\": \"open_samples\", \"args\": 3}" + nl +
    "{\"tool\": \"open_samples\", \"wait\": 1}" + nl +
    "{\"tool\": \"launch_rockets\"}" + nl +
    "{\"tool\": \"save_document\"}" + nl +
    "{\"tool\": \"delete_path\"}" + nl +
    "{\"tool\": \"capture\", \"args\": {\"file\": \"r.png\", \"scal\": 2}}" + nl +
    "{\"tool\": \"capture\", \"args\": {}}" + nl +
    "{\"tool\": \"caret_to\", \"args\": {\"text\": \"\"}}" + nl +
    "{\"tool\": \"caret_to\", \"args\": {\"text\": \"x\", \"column\": 0}}" + nl +
    "{\"tool\": \"raise\", \"args\": {\"pane\": \"editor\"}}" + nl +
    "{\"tool\": \"open_window\", \"args\": {\"window\": \"main\"}}" + nl +
    "{\"tool\": \"open_window\", \"args\": {\"window\": \"snippet\", \"row\": 1}}" + nl +
    "{\"tool\": \"capture\", \"args\": {\"file\": \"r.png\", \"window\": \"side\"}}" + nl +
    "{\"tool\": \"capture\", \"args\": {\"file\": \"r.png\", \"scale\": 9}}" + nl +
    "{\"tool\": \"capture\", \"args\": {\"file\": \"r.png\", \"scale\": 0}}")

  print "-- a frame, one fault per script"
  for each fa in ["{\"width\": 100}", "{\"height\": \"tall\"}", "{\"width\": 5000}",
                  "{\"theme\": \"light\"}", "{\"zoom\": 1.2}", "{\"zoom\": \"big\"}",
                  "{\"whitespace\": \"yes\"}", "{\"size\": 2}"]
    r = studio_shots.script_steps("{\"tool\": \"frame\", \"args\": " + fa + "}")
    print "  " + fa + " -> " + join(r.errors, "; ")
  end for
  r = check("an empty script", "# nothing" + nl + nl)

  print "-- a figure's file is a plain .png name in the output directory"
  for each fn in ["ch01-rejects.png", "UP.PNG", "/etc/x.png", "~/x.png", "../x.png", "sub/x.png", ".hidden.png", "x.jpg", ""]
    why = studio_shots.file_problem(fn)
    if why = "" then
      why = "ok"
    end if
    print "  [" + fn + "] " + why
  end for

  print "-- a capture's part, by the name a caption uses"
  for each p in ["", "window", "files", "editor", "console", "toolbar", "results", "tables", "branch", "git", "agent", "run_btn"]
    print "  [" + p + "] -> [" + studio_shots.part_for(p) + "]"
  end for

  print "-- a caret placed by a line's TEXT, leading whitespace aside"
  t = "' a comment" + nl + "sales = []" + nl + "    for each s in sales" + nl + "sales = [1]"
  for each n in ["sales = []", "for each", "sales", "nothing like it"]
    print "  [" + n + "] -> line " + string(studio_shots.line_of(t, n))
  end for

  print "-- a path in a script is the SCRIPT'S"
  print "  " + studio_shots.dir_of("/books/v3/ch01/shots/rejects.shot")
  print "  " + studio_shots.dir_of("rejects.shot")
  print "  " + studio_shots.dir_of("/rejects.shot")
  print "  " + studio_shots.resolve("/books/v3/ch01/shots", "..")
  print "  " + studio_shots.resolve("/books/v3/ch01/shots", ".")
  print "  " + studio_shots.resolve("/books/v3/ch01/shots", "/srv/data")

  print "-- the policy a figure runs under"
  p = studio_shots.policy()
  print "  read " + p.read + ", local " + p.local + ", external " + p.external

  print "-- New Project's location, written from ~"
  print "  " + studio_ui.tilde_path("/home/r/.gbasic-studio/projects", "/home/r")
  print "  " + studio_ui.tilde_path("/home/r", "/home/r")
  print "  " + studio_ui.tilde_path("/home/rx/projects", "/home/r")
  print "  " + studio_ui.tilde_path("/srv/projects", "/home/r")
  print "  " + studio_ui.tilde_path("/srv/projects", "")
  print "  " + studio_ui.tilde_path("/srv/projects", "/")
  print "  " + studio_ui.expand_path(studio_ui.tilde_path("/home/r/p", "/home/r"), "/home/r", "")
end program
