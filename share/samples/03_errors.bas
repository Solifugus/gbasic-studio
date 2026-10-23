' 03 — Errors: where a mistake is, and where it is NOT.
'
' This file has two mistakes in it on purpose.
'
' Try this:
'   1. Put the cursor on the last line and press Run Section. It stops with a
'      runtime error, and the Errors pane (at the bottom) names the line and
'      column IN THIS FILE -- even though Studio ran a generated copy of it.
'   2. Fix it: change `count_of(names)` to `count(names)`, and run again.
'   3. Now break the SYNTAX instead: delete the `then` on the `if` line. A
'      syntax error is found before anything runs, so the margin marks the
'      line straight away -- and Run Section refuses until it is fixed.

names = ["ada", "grace", "edsger"]

function describe(list)
    if count(list) > 2 then
        return "a crowd"
    end if
    return "a few"
end function

print describe(names) + " of " + count_of(names)
