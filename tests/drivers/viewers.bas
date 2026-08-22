' STU-8 headless driver for library-registered rich viewers (studio_viewers).
' Discovery from sidecars, validation, descriptor matching, specificity, the
' capture rules the epilogue is compiled from, and rendering. No GTK, no child
' process, no display.
'
' args: mode home

' A captured variable as the STU-5 epilogue reports one: a shallow descriptor
' plus a stringified preview. This is exactly what Studio holds after a run — the
' values are gone with the child — so matching is tested against it and nothing
' richer.
function model_capture()
  fields = ["coefficients", "std_errors", "t_values", "p_values", "r_squared", "adj_r_squared", "cov", "fitted", "residuals", "n", "df"]
  rows = []
  for each f in fields
    rows = append(rows, [f, "..."])
  end for
  return {
    name: "m",
    kind: "record",
    type: "record",
    category: "container",
    serializable: true,
    count: count(fields),
    preview: { cols: ["field", "value"], rows: rows, text: "", more: 0 }
  }
end function

function with_detail(v, d)
  v.detail = d
  return v
end function

function model_detail()
  return {
    coefficients: [1.2031044, 0.4871902, -0.0093115],
    std_errors: [0.1140233, 0.0310887, 0.0044021],
    t_values: [10.55142, 15.67099, -2.11524],
    p_values: [0.0000001, 0.0000000, 0.0371882],
    r_squared: 0.84213377,
    adj_r_squared: 0.84051119,
    n: 100,
    df: 97
  }
end function

' A record of the same KIND that is not a model: the matcher must not claim it.
function plain_capture()
  rows = [["host", "localhost"], ["port", "5432"]]
  return {
    name: "config",
    kind: "record",
    type: "record",
    category: "container",
    serializable: true,
    count: 2,
    preview: { cols: ["field", "value"], rows: rows, text: "", more: 0 }
  }
end function

function ci_capture()
  fields = ["mean", "lower", "upper", "se", "margin", "df", "level"]
  rows = []
  for each f in fields
    rows = append(rows, [f, "..."])
  end for
  return {
    name: "ci",
    kind: "record",
    type: "record",
    category: "container",
    serializable: true,
    count: count(fields),
    preview: { cols: ["field", "value"], rows: rows, text: "", more: 0 }
  }
end function

function show(lines)
  for each l in lines
    print l
  end for
end function

' Problem messages name the file they came from, which is right in the window and
' unstable in a golden: the tests run under a temp home. Print the tail only.
function scrub(lines, home)
  out = []
  for each l in lines
    out = append(out, replace(l, home + "/", ""))
  end for
  return out
end function

function name_of(spec)
  if spec = nothing then
    return "(none)"
  end if
  return spec.name
end function

program main(args)
  load persist
  load studio_viewers

  mode = args[0]

  if mode = "registry" then
    reg = studio_viewers.load_path(["viewers"])
    show(studio_viewers.summary(reg))
    print ""
    print "-- the capture rules the epilogue is compiled from (most specific first)"
    for each r in studio_viewers.capture_rules(reg)
      print "  " + r.name + ": needs " + count(r.fields) + ", fetches " + join(r.detail, ", ")
    end for
  end if

  if mode = "match" then
    reg = studio_viewers.load_path(["viewers"])
    print "regression model  -> " + name_of(studio_viewers.best_for(reg, model_capture()))
    print "confidence interval -> " + name_of(studio_viewers.best_for(reg, ci_capture()))
    print "a plain record    -> " + name_of(studio_viewers.best_for(reg, plain_capture()))
    print ""
    print "-- fields read off the descriptor, not off a value"
    print "  " + join(studio_viewers.descriptor_fields(model_capture()), " ")
    print "  " + join(studio_viewers.descriptor_fields(plain_capture()), " ")
    print ""
    print "-- a variable with no preview at all can match nothing"
    print "  " + name_of(studio_viewers.best_for(reg, { name: "m", kind: "record", type: "record", count: 11 }))
  end if

  if mode = "render" then
    reg = studio_viewers.load_path(["viewers"])
    v = with_detail(model_capture(), model_detail())
    spec = studio_viewers.best_for(reg, v)
    show(studio_viewers.render(spec, v, "  "))
    print ""
    print "-- matched on shape, but the result predates the viewer: no detail"
    out = studio_viewers.render(spec, model_capture(), "  ")
    print "  lines: " + count(out) + " (falls back to the structural preview)"
    print ""
    print "-- a column the detail does not carry drops the whole table, not a row"
    full = model_detail()
    partial = { coefficients: full.coefficients, std_errors: full.std_errors, p_values: full.p_values, r_squared: full.r_squared, adj_r_squared: full.adj_r_squared, n: full.n, df: full.df }
    show(studio_viewers.render(spec, with_detail(model_capture(), partial), "  "))
    print ""
    print "-- unequal columns are shown to the shortest, and say so"
    ragged = model_detail()
    ragged.p_values = [0.0000001, 0.0000000]
    show(studio_viewers.render(spec, with_detail(model_capture(), ragged), "  "))
  end if

  if mode = "problems" then
    home = args[1]
    persist.ensure_dir(home)
    bad(file) = home + "/broken.viewers"
    write(bad, "{ not json")
    empty(file) = home + "/empty.viewers"
    write(empty, "{ \"schema\": 1 }")
    mixed(file) = home + "/mixed.viewers"
    write(mixed, join([
      "{ \"library\": \"mixed\", \"viewers\": [",
      "  { \"name\": \"ok\", \"match\": { \"fields\": [\"a\"] } },",
      "  { \"match\": { \"fields\": [\"a\"] } },",
      "  { \"name\": \"nofields\", \"match\": {} },",
      "  { \"name\": \"badblock\", \"match\": { \"fields\": [\"a\"] }, \"layout\": [ { \"block\": \"chart\" } ] } ] }"
    ], "\n"))
    ignored(file) = home + "/notes.txt"
    write(ignored, "not addressed to the registry")
    reg = studio_viewers.load_path([home])
    show(scrub(studio_viewers.summary(reg), home))
    print ""
    print "-- one library's broken sidecar does not stop another's from loading"
    reg2 = studio_viewers.load_path([home, "viewers"])
    print "  viewers: " + count(reg2.viewers) + "  problems: " + count(reg2.problems)
  end if

  if mode = "precedence" then
    home = args[1]
    persist.ensure_dir(home)
    ' A library ships its own sidecar for a type Studio also bundles one for.
    own(file) = home + "/stats.viewers"
    write(own, join([
      "{ \"library\": \"stats\", \"viewers\": [",
      "  { \"name\": \"regression\",",
      "    \"title\": \"OLS regression (shipped by the library)\",",
      "    \"match\": { \"kind\": \"record\", \"fields\": [\"coefficients\", \"std_errors\", \"t_values\", \"p_values\", \"r_squared\", \"n\"] },",
      "    \"layout\": [ { \"block\": \"fields\", \"items\": [ { \"label\": \"n\", \"field\": \"n\" } ] } ] } ] }"
    ], "\n"))
    reg = studio_viewers.load_path([home, "viewers"])
    v = with_detail(model_capture(), model_detail())
    spec = studio_viewers.best_for(reg, v)
    print "winner: " + spec.name + " -- " + spec.title
    print "  (six required fields beats the bundled five)"
    show(studio_viewers.render(spec, v, "  "))
  end if
end program
