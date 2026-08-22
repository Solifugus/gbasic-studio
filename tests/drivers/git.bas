' STU-11 headless driver for optional git (studio_git). Detection, status, diff,
' history, branches and commit — over a fixture repository built by `git init` in
' a temp directory. No network, no display.
'
' args: mode home repodir
'
' The repo is prepared by the SHELL (the suite), not here: building it with
' process.run from inside the driver would make every case depend on the thing it
' is testing.

function show(lines)
  for each l in lines
    print l
  end for
end function

function scrub(text, root)
  return replace(text, root + "/", "")
end function

program main(args)
  load studio_git

  mode = args[0]
  repo = args[2]

  if mode = "quiet" then
    ' §18: git stays QUIET when there is nothing to be loud about.
    print "-- outside a repository, the pane is one line"
    show(studio_git.summary(args[1]))
    print ""
    print "  detect: " + studio_git.detect(args[1]).state
    print ""
    print "-- and a directory that does not exist is refused, not raised"
    r = studio_git.run(args[1] + "/nowhere", ["status"])
    print "  ok=" + string(r.ok) + " — " + replace(r.why, args[1] + "/", "")
    print ""
    print "-- git is found by LOOKING for it, never by trying to run it:"
    print "   process.run raises when the executable is missing, and gBASIC"
    print "   cannot catch a raise, so asking the question by running git would"
    print "   crash the window of every user who does not have it."
    print "  available: " + string(studio_git.available())
  end if

  if mode = "detect" then
    d = studio_git.detect(repo)
    print "state:  " + d.state
    print "root:   " + string(d.root = repo)
    print "branch: " + d.branch
    print ""
    print "-- a subdirectory resolves to the same root"
    d2 = studio_git.detect(repo + "/sub")
    print "  state: " + d2.state + "  same root: " + string(d2.root = repo)
    print ""
    print "-- the root is asked of git, not guessed from a .git folder: a"
    print "   worktree, a submodule and an external git-dir all have none where"
    print "   a naive check would look."
  end if

  if mode = "status" then
    st = studio_git.status(repo)
    print "ok=" + string(st.ok) + " changes=" + count(st.rows)
    for each row in st.rows
      line = "  [" + row.x + row.y + "] " + row.label + ": " + row.path
      if row.old_path != "" then
        line = line + " (was " + row.old_path + ")"
      end if
      print line
    end for
    print ""
    print "-- git's two columns are KEPT, not flattened: 'staged AND modified"
    print "   since' is a real state and one letter cannot say it."
  end if

  if mode = "history" then
    h = studio_git.history(repo, 5)
    print "ok=" + string(h.ok) + " commits=" + count(h.rows)
    ' NOT the hash, and not the relative date: both change on every run, so a
    ' golden holding either would be a golden about when the fixture was built.
    ' What is asserted is that the fields parsed and that the shape is right.
    for each c in h.rows
      print "  " + c.author + "  " + c.subject + "  (hash " + len(c.hash) + " chars, short " + len(c.short) + ")"
    end for
    print ""
    b = studio_git.branches(repo)
    print "branches=" + count(b.rows)
    for each br in b.rows
      mark = "  "
      if br.current then
        mark = "* "
      end if
      print "  " + mark + br.name
    end for
    print ""
    print "-- these are GIT branches. Studio's exploratory branches are a"
    print "   different thing entirely (§2.3) and nothing here creates, switches"
    print "   or names a ref on their behalf."
  end if

  if mode = "diff" then
    d = studio_git.diff(repo, "")
    print "ok=" + string(d.ok)
    ' The header lines only: the body carries an index hash that changes with
    ' the fixture's content and timestamps.
    for each l in split(d.text, "\n")
      if len(l) > 0 then
        c = mid(l, 0, 1)
        if c = "+" or c = "-" or c = "@" then
          print "  " + l
        end if
      end if
    end for
    print ""
    print "-- the diff is git's own text. Studio does not re-render it: every"
    print "   developer already reads this format, and a prettier one would be"
    print "   a different format to learn."
  end if

  if mode = "commit" then
    print "-- a commit with no message is refused BEFORE git is invoked"
    r = studio_git.commit(repo, "   ", [])
    print "  ok=" + string(r.ok) + " — " + r.why
    print "  (git commit with no -m opens an editor; an editor Studio cannot see"
    print "   would hang the child until the timeout killed it, which the user"
    print "   would experience as a commit that silently did nothing)"
    print ""
    print "-- committing the working tree"
    r2 = studio_git.commit(repo, "a commit from the test", ["tracked.bas"])
    print "  ok=" + string(r2.ok)
    st = studio_git.status(repo)
    print "  changes now: " + count(st.rows)
    h = studio_git.history(repo, 1)
    print "  newest commit: " + h.rows[0].subject
  end if

  if mode = "tiers" then
    print "which permission tier each operation belongs in (STU-10 §17)."
    print "git makes the line sharp: everything that stays in this repository is"
    print "recoverable by someone who knows git; everything that reaches a REMOTE"
    print "is visible to other people the moment it lands."
    print ""
    for each op in ["detect", "status", "diff", "history", "branches", "init", "stage", "commit", "push", "pull"]
      print "  " + studio_git.tier_of(op) + "  " + op
    end for
  end if
end program
