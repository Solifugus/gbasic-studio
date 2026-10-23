' 06 — Overlays: experimenting with a function on a branch.
'
' An OVERLAY replaces one section's code on one branch only. The file still
' shows the original; the branch runs the experiment. An overlay can change
' only what comes AFTER the point the branch was made at.
'
' Try this:
'   1. Put the cursor on the `multiplier = 2` line. In the Branches tab, type
'      "Squared" in the name field at the top of the window and click "+":
'      the branch starts here, so everything below it is open to change.
'   2. Put the cursor inside `score` and press "Overlay". The overlay's own
'      editor opens with the function's text -- change `t * multiplier` to
'      `t * t`, then press "Save overlay".
'   3. Put the cursor on the `for each` line and press Run Section. The output
'      uses the overlay; the editor above still shows the file as it is.
'   4. "Compare" shows the difference. "Promote" writes the overlay into the
'      file (as an unsaved edit); "Discard" throws it away.

multiplier = 2

function score(t)
    return t * multiplier
end function

for each t in [1, 2, 3, 4]
    print string(t) + " scores " + score(t)
end for
