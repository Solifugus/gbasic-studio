' The one decision behind the editor's colours: which GtkSourceView STYLE SCHEME
' to paint with, given what the toolkit says.
'
' It lives in studio_style, not in the shell, for the reason every other decision
' does — a signal handler is an adapter — and for one more: none of the toolkit's
' answers are reachable from a headless test, while all four inputs to the
' decision are plain values. So the reading is untestable and the deciding is
' fully tested, which is the split the interaction rule asks for.
'
' args: none. Output is a fixed table.

function scheme(label, theme, name, prefer, envv)
  print label + ": " + studio_style.scheme_for(theme, name, prefer, envv)
  return nothing
end function

program main(args)
  load studio_style

  print "== Studio's own setting wins over the toolkit =="
  ' `settings.theme` has been persisted since STU-0 with nothing reading it.
  ' Someone who has said which one they want is not asking to be guessed at.
  scheme("dark over a light desktop ", "dark", "Adwaita", false, "")
  scheme("light over a dark desktop ", "light", "Adwaita-dark", true, "Adwaita:dark")

  print ""
  print "== \"system\" asks the toolkit, and no ONE signal is enough =="
  ' Each of these was measured on a real window; the comments in studio_style
  ' say which of them this machine actually answered with.
  scheme("prefer-dark set         ", "system", "Adwaita", true, "")
  scheme("theme NAME carries it   ", "system", "Breeze-Dark", false, "")
  scheme("only GTK_THEME does     ", "system", "Breeze", false, "Adwaita:dark")
  scheme("nothing says dark       ", "system", "Breeze", false, "")

  print ""
  print "== the three spellings of the same word =="
  print "Adwaita-dark: " + studio_style.toolkit_is_dark("Adwaita-dark", false, "")
  print "Breeze-Dark:  " + studio_style.toolkit_is_dark("Breeze-Dark", false, "")
  print "Adwaita:dark: " + studio_style.toolkit_is_dark("Adwaita:dark", false, "")
  print "Breeze:       " + studio_style.toolkit_is_dark("Breeze", false, "")

  print ""
  print "== an UNSET environment variable is not a string =="
  ' `env` answers `unknown` for a variable that is not set, and `lower` on an
  ' unknown raises. A theme probe that crashes the window of everyone who has
  ' not set GTK_THEME would be a poor trade for a colour.
  unset = env("GBASIC_STUDIO_NO_SUCH_VAR")
  print "is_string=" + is_string(unset)
  print "dark=" + studio_style.toolkit_is_dark("Breeze", false, unset)

  print ""
  print "== the section tint follows the same decision =="
  ' Not CSS: a GtkTextTag background cannot be an `@theme` reference, so it is
  ' two literals and one boolean.
  print "light: " + studio_style.section_tint(false)
  print "dark:  " + studio_style.section_tint(true)
end program
