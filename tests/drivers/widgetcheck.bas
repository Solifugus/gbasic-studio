' The set of widgets an agent is TOLD it may point at, and the set the window can
' actually resolve, must be the same set. They live in two files — a registry the
' agent reads and a lookup the shell performs — and nothing but this keeps them
' together. A widget in the registry that the shell cannot find is a teaching
' request that reports success and draws nothing, which is the failure mode
' teaching can least afford.
program main(args)
  load studio_teaching
  load studio_shell
  bad = 0
  for each name in studio_teaching.names()
    if not contains(studio_shell.teachable(), name) then
      print "the agent is offered " + name + ", but the shell cannot resolve it"
      bad = bad + 1
    end if
  end for
  for each name in studio_shell.teachable()
    if not contains(studio_teaching.names(), name) then
      print "the shell can resolve " + name + ", but no agent is told about it"
      bad = bad + 1
    end if
  end for
  if bad > 0 then
    print "FAIL " + bad
    exit(1)
  end if
end program
