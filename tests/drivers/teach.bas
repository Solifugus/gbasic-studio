' STU-10 headless driver for the teaching model (studio_teaching). Which widgets
' an agent may point at, which gestures each can perform, the refusals, and the
' range parsing. Plain data throughout; no GTK and no display.
'
' args: mode

function say(c)
  print "  " + studio_teaching.describe(c)
end function

program main(args)
  load studio_teaching
  mode = args[0]

  if mode = "widgets" then
    for each l in studio_teaching.summary()
      print l
    end for
  end if

  if mode = "cues" then
    print "-- pointing at things, the way §13 describes"
    say(studio_teaching.cue("gutter", "pulse", ""))
    say(studio_teaching.cue("run_button", "highlight", ""))
    say(studio_teaching.cue("name_field", "focus", ""))
    say(studio_teaching.cue("results", "reveal", ""))
    say(studio_teaching.cue("editor", "annotate", "12-18"))
    say(studio_teaching.cue("editor", "annotate", "7"))
    print ""
    print "-- a bad widget name LISTS the real ones, so a model can correct itself"
    say(studio_teaching.cue("run_panel", "highlight", ""))
    print ""
    print "-- so does a bad gesture"
    say(studio_teaching.cue("editor", "wiggle", ""))
    print ""
    print "-- and a gesture a widget cannot perform says what it can"
    say(studio_teaching.cue("browser", "annotate", "3"))
    say(studio_teaching.cue("results", "focus", ""))
    print ""
    print "-- focus and highlight are not interchangeable: one takes the keyboard"
    print "   away from someone mid-sentence, which is why a pane cannot focus."
  end if

  if mode = "ranges" then
    print "an annotation names a range, and a malformed one is REFUSED —"
    print "defaulting to line 0 would point confidently at the wrong place."
    for each t in ["12", "12-18", "0-0", " 5 ", "", "x", "12-", "-4", "18-12", "1-2-3", "1.5"]
      r = studio_teaching.range_of(t)
      if r.ok then
        print "  " + quote(t) + " -> lines " + r.first + ".." + r.last
      else
        print "  " + quote(t) + " -> " + r.why
      end if
    end for
  end if

  if mode = "css" then
    print "the classes the shell toggles, defined in one place so a stylesheet"
    print "and a renderer cannot disagree about their names:"
    print "  highlight -> " + studio_teaching.css_class("highlight")
    print "  pulse     -> " + studio_teaching.css_class("pulse")
    print "  focus     -> " + quote(studio_teaching.css_class("focus")) + " (no class; focus is grab_focus)"
    print ""
    print studio_teaching.css()
    print "annotation tint: " + studio_teaching.annotate_colour()
    print "pulse duration: " + studio_teaching.pulse_ms() + "ms"
  end if
end program
