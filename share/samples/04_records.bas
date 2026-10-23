' 04 — Records: what a run leaves behind.
'
' After a run, the Results pane lists the VARIABLES the section left, with a
' short look at each -- a record's fields, a list's first items.
'
' Try this:
'   1. Run this section (cursor anywhere, Run Section).
'   2. Open the Results tab: `book` shows its fields, `shelf` its size and
'      first few entries, `oldest` the record the loop found.
'   3. Add a fourth book to the shelf and run again; the result above it is
'      marked as belonging to an older version of the section.

book = { title: "Structure and Interpretation", year: 1985, pages: 657 }

shelf = [
    book,
    { title: "The Art of Computer Programming", year: 1968, pages: 672 },
    { title: "Compilers", year: 1986, pages: 796 }
]

oldest = shelf[0]
for each b in shelf
    if b.year < oldest.year then
        oldest = b
    end if
end for

print "the oldest is " + oldest.title + " (" + oldest.year + ")"
