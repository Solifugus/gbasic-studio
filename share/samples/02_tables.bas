' 02 — Tables: looking at data in a grid.
'
' When a run leaves behind something that looks like a table -- a list of
' records with the same fields -- the Tables pane on the right offers it.
'
' Try this:
'   1. Put the cursor anywhere in this file and press Run Section.
'   2. Open the Tables tab. It offers `sales` and `summary`.
'   3. Click `sales`. A window opens with the first 50 rows: the run kept a
'      SAMPLE, and the caption says so. Sort by any column with the controls
'      at the top.
'   4. Press "Fetch all rows" in the Tables pane. That runs the section again
'      and keeps every row; click `sales` again to see all 1,200.

sales = []
for n = 0 to 1199
    region = "North"
    if mod(n, 4) = 1 then
        region = "South"
    end if
    if mod(n, 4) = 2 then
        region = "East"
    end if
    if mod(n, 4) = 3 then
        region = "West"
    end if
    product = "Widget"
    if mod(n, 3) = 1 then
        product = "Gadget"
    end if
    if mod(n, 3) = 2 then
        product = "Gizmo"
    end if
    sales = append(sales, { order: n + 1, region: region, product: product,
                            units: mod(n * 7, 50) + 1, price: 9.5 + mod(n, 5) })
end for

summary = []
for each r in ["North", "South", "East", "West"]
    total = 0
    for each s in sales
        if s.region = r then
            total += s.units
        end if
    end for
    summary = append(summary, { region: r, units: total })
end for

print "built " + count(sales) + " sales across " + count(summary) + " regions"
