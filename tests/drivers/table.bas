' STU-8 headless driver for the tabular tier (studio_table). What gets a table
' affordance, where its rows come from, and the two halves of the virtualization
' claim — measured, not asserted. No GTK and no display; the `model` mode uses
' the native GListModel adapter, which is Gio only.
'
' args: mode home

function cap(name, kindv, n, cols, rows)
  return { name: name, kind: kindv, type: kindv, category: "container",
           serializable: true, count: n,
           preview: { cols: cols, rows: rows, text: "", more: n - count(rows) } }
end function

function scalar_cap(name)
  return { name: name, kind: "number", type: "number", category: "scalar",
           serializable: true, count: 0,
           preview: { cols: [], rows: [], text: "42", more: 0 } }
end function

function sample_rows(n)
  out = []
  i = 0
  while i < n
    out = append(out, [string(i), "row " + i, string(i * 1.5)])
    i = i + 1
  end while
  return out
end function

function show(lines)
  for each l in lines
    print l
  end for
end function

function describe(v)
  offers = studio_table.offers(v)
  line = "  " + v.name + "  tier=" + studio_table.tier(v) + "  offers=[" + join(offers, "] [") + "]"
  if count(offers) = 0 then
    line = "  " + v.name + "  tier=" + studio_table.tier(v) + "  offers=(none)"
  end if
  print line
  ol = studio_table.offer_line(v)
  if ol != "" then
    print "    " + ol
  end if
end function

' Write an export the way the epilogue writes one: a header line, then one
' encoded row per line. Built here rather than by running a child, so the source
' logic is tested independently of the run that produces it.
function write_export(path, n, written)
  cols = ["id", "name", "score"]
  buf = ["{\"cols\":[\"id\",\"name\",\"score\"],\"n\":" + n + ",\"rows\":" + written + "}"]
  i = 0
  while i < written
    buf = append(buf, encode([string(i), "row " + i, string(i * 1.5)]))
    i = i + 1
  end while
  f{file} = path
  write(f, join(buf, "\n") + "\n")
  return path
end function

program main(args)
  load persist
  load studio_table

  mode = args[0]
  home = args[1]

  if mode = "tier" then
    print "-- Studio must not assume every large structure is a table (design §7)"
    describe(scalar_cap("total"))
    describe(cap("config", "record", 7, ["field", "value"], [["host", "localhost"]]))
    describe(cap("empty", "array", 0, [], []))
    describe(cap("names", "array", 12, ["value"], [["a"], ["b"]]))
    describe(cap("customers", "array", 48291, ["id", "name", "score"], sample_rows(3)))
    print ""
    print "-- the fork is on the count the CHILD saw, not on how many rows"
    print "   the capture kept: " + studio_table.modest_rows() + " rows is the line"
    describe(cap("just_under", "array", 500, ["id", "name", "score"], sample_rows(3)))
    describe(cap("just_over", "array", 501, ["id", "name", "score"], sample_rows(3)))
  end if

  if mode = "preview" then
    v = cap("customers", "array", 48291, ["id", "name", "score"], sample_rows(50))
    src = studio_table.from_preview(v)
    show(studio_table.summary(src))
    print ""
    print "caption: " + studio_table.caption(v.name, src)
    print ""
    print "-- the rows it does hold read correctly"
    r = studio_table.cell(src, 0, 1)
    print "  [0][1] = " + r.text
    r = studio_table.cell(r.src, 49, 2)
    print "  [49][2] = " + r.text
    print ""
    print "-- past what it holds is blank, not a raise"
    r = studio_table.cell(r.src, 4000, 0)
    print "  [4000][0] = \"" + r.text + "\""
    print ""
    print "-- a complete small table says nothing about sampling"
    small = studio_table.from_preview(cap("names", "array", 3, ["value"], [["a"], ["b"], ["c"]]))
    print "caption: " + studio_table.caption("names", small)
  end if

  if mode = "export" then
    persist.ensure_dir(home)
    path = write_export(home + "/rows.export", 1200, 1200)
    f{file} = path
    src = studio_table.from_export(read(f), path)
    show(studio_table.summary(src))
    print ""
    print "-- reading the file decoded NO rows: they are strings until asked for"
    r = studio_table.cell(src, 700, 1)
    print "  [700][1] = " + r.text + "   decoded: " + r.src.decodes
    r = studio_table.cell(r.src, 700, 2)
    print "  [700][2] = " + r.text + "   decoded: " + r.src.decodes + " (cached; the row was not decoded twice)"
    r = studio_table.cell(r.src, 3, 0)
    print "  [3][0] = " + r.text + "     decoded: " + r.src.decodes
    print ""
    print "-- a capped export knows it is capped"
    capped = studio_table.from_export(read(f), path)
    capped.n = 900000
    capped.sampled = true
    print "caption: " + studio_table.caption("customers", capped)
    print ""
    print "-- a corrupt line is a blank row, not a dead grid"
    bad{file} = home + "/bad.export"
    write(bad, "{\"cols\":[\"a\",\"b\"],\"n\":2,\"rows\":2}\n[\"ok\",\"fine\"]\nnot json\n")
    bsrc = studio_table.from_export(read(bad), home + "/bad.export")
    r = studio_table.cell(bsrc, 0, 0)
    print "  [0][0] = \"" + r.text + "\""
    r = studio_table.cell(r.src, 1, 0)
    print "  [1][0] = \"" + r.text + "\""
    print ""
    print "-- a file that is not an export at all yields an empty source"
    junk{file} = home + "/junk.export"
    write(junk, "hello\n")
    print "  kind: " + studio_table.from_export(read(junk), home + "/junk.export").kind
    print ""
    print "-- and a missing export is the normal state: nobody has fetched yet"
    print "  kind: " + studio_table.read_export(home, "/proj/a.bas", "customers").kind
    print "  path: " + replace(studio_table.export_path(home, "/proj/a.bas", "customers"), home + "/", "")
    print "  a name that is not an identifier cannot escape the directory:"
    print "  path: " + replace(studio_table.export_path(home, "/proj/a.bas", "../../etc/x"), home + "/", "")
  end if

  if mode = "model" then
    persist.ensure_dir(home)
    n = 50000
    path = write_export(home + "/big.export", n, n)
    f{file} = path
    src = studio_table.from_export(read(f), path)
    print "a " + src.n + "-row table, " + src.decodes + " rows decoded by opening it"
    print ""
    print "-- half one: the NATIVE model serves the count and hands out lazy row"
    print "   proxies. Row requests are bounded by what is asked for, not by the"
    print "   table's size."
    m = rowmodel.new(1)
    set_count_result = rowmodel.set_count(m, src.known)
    print "  model count: " + rowmodel.count(m)
    rowmodel.reset_requests(m)
    print ""
    print "-- half two: Studio decodes a row when a cell of it is asked for, and"
    print "   not before. 300 rows spread across the table:"
    k = 0
    total = 0
    while k < 300
      pos = k * 166
      row = rowmodel.get_item(m, pos)
      r = studio_table.cell(src, rowmodel.row_index(row), 0)
      total = total + number(r.text)
      src = r.src
      k = k + 1
    end while
    print "  row requests: " + rowmodel.item_requests(m)
    print "  rows decoded: " + src.decodes
    print "  id sum:       " + total
    print "  table size:   " + src.n + " rows, of which " + (src.n - src.decodes) + " were never touched"
    print ""
    print "-- scrolling back over the same rows costs nothing"
    k = 0
    while k < 300
      r = studio_table.cell(src, k * 166, 1)
      src = r.src
      k = k + 1
    end while
    print "  rows decoded after a second pass: " + src.decodes
  end if
end program
