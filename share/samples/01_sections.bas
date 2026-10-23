' 01 — Sections: how Studio runs a file a piece at a time.
'
' Studio splits a gBASIC file into SECTIONS: each function is one, and the
' statements between functions are another. The strip at the bottom names the
' section the cursor is in, and Run Section runs that one.
'
' Try this:
'   1. Put the cursor on the "greeting =" line. The strip says sec-1.
'      Press Run Section. The output pane shows the greeting.
'   2. Put the cursor on the last line and press Run Section again. Studio
'      replays everything above it first (so `greeting` and `shout` exist),
'      then runs that section -- the "prefix" pane shows what the replay
'      printed, the "target" pane what the section itself printed.
'   3. Open the Results tab on the right. It keeps every run of the section
'      the cursor is in; edit the section and the old result is marked
'      "section edited since this run".

greeting = "hello from section one"
print greeting

function shout(text)
    return upper(text) + "!"
end function

print shout(greeting)
