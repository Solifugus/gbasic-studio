' 05 — Branches: trying a different value without editing the file.
'
' A BRANCH is an alternate run of the same code with some values bound
' differently. The file never changes; each branch remembers its own results.
'
' Try this:
'   1. Put the cursor on the last line and press Run Section: it prints the
'      result with threshold 0.5.
'   2. In the Branches tab, type "Strict" into the name field at the top of
'      the window and click the "+" row: a branch called Strict.
'   3. Type "threshold = 0.9" into the name field and press "Bind name =
'      value". Run the last line again: same code, different answer.
'   4. Click "Baseline" to go back; the file was never touched.

threshold = 0.5
scores = [0.42, 0.67, 0.91, 0.55, 0.78]

function passing(list, cut)
    n = 0
    for each s in list
        if s >= cut then
            n += 1
        end if
    end for
    return n
end function

print string(passing(scores, threshold)) + " of " + count(scores) + " pass at " + threshold
