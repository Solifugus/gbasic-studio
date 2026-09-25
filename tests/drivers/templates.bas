' STU-15 the template registry: declared text with holes in it.
'
' Everything here is over plain data and a temp directory. What a template
' MEANS is one function over a record, so the whole mechanism is asserted with
' no window, no project and no process.

function show(reg, root)
  ' Path-free: the golden must hold what the registry SAYS, not where a
  ' temp directory happened to land.
  print replace(studio_templates.summary(reg), root, "<t>")
end function

function fill(reg, id, values)
  r = studio_templates.render_id(reg, id, values)
  if not r.ok then
    print "  " + id + " -> refused: " + r.why
  else
    print "  " + id + " -> <" + replace(r.text, "\n", "\\n") + ">"
  end if
end function

function writef(path, text)
  f{file} = path
  write(f, text)
end function

program main(args)
  load persist
  load studio_templates

  mode = args[0]
  root = args[1]
  persist.ensure_dir(root)

  ' ---- load: what gets in, and what is turned away ------------------------
  if mode = "load" then
    a = root + "/a"
    persist.ensure_dir(a)

    print "== a good file =="
    writef(a + "/good.templates", "{\"schema_version\":1,\"templates\":[" +
      "{\"id\":\"greet\",\"name\":\"Greeting\",\"fields\":[{\"name\":\"who\",\"required\":true}],\"text\":\"hello {{who}}\"}," +
      "{\"id\":\"plain\",\"text\":\"nothing to fill\"}]}")
    reg = studio_templates.load_path([a])
    show(reg, root)

    ' Every way a declaration can be wrong is a PROBLEM naming itself, never a
    ' raise: one broken file must not stop the rest of the registry loading,
    ' and a template that silently did not load gets diagnosed as "the button
    ' is wrong" for a week.
    print ""
    print "== and every way one can be wrong =="
    b = root + "/b"
    persist.ensure_dir(b)
    writef(b + "/bad.templates", "{\"templates\":[" +
      "{\"text\":\"no id\"}," +
      "{\"id\":42,\"text\":\"id is not a string\"}," +
      "{\"id\":\"  \",\"text\":\"id is blank\"}," +
      "{\"id\":\"both\",\"text\":\"x\",\"from\":\"y.txt\"}," +
      "{\"id\":\"neither\"}," +
      "{\"id\":\"undeclared\",\"text\":\"hi {{athor}}\"}," +
      "{\"id\":\"empty-hole\",\"text\":\"hi {{}}\"}," +
      "{\"id\":\"badfields\",\"fields\":\"who\",\"text\":\"x\"}," +
      "{\"id\":\"nofieldname\",\"fields\":[{\"label\":\"Who\"}],\"text\":\"x\"}," +
      "\"not an object\"]}")
    reg = studio_templates.load_path([b])
    show(reg, root)

    print ""
    print "== a file that is not one =="
    c = root + "/c"
    persist.ensure_dir(c)
    writef(c + "/broken.templates", "{ not json")
    writef(c + "/notalist.templates", "{\"templates\":\"one\"}")
    writef(c + "/nolist.templates", "{}")
    writef(c + "/future.templates", "{\"schema_version\":99,\"templates\":[{\"id\":\"x\",\"text\":\"y\"}]}")
    writef(c + "/ignored.json", "{\"templates\":[{\"id\":\"swept\",\"text\":\"y\"}]}")
    reg = studio_templates.load_path([c])
    show(reg, root)

    ' A directory that is not there is NOT a problem. Three of the four layers
    ' are normally absent -- most projects declare no template directory and
    ' most users have never made one -- and reporting that would bury the
    ' faults that matter.
    print ""
    print "== a search path whose directories mostly do not exist =="
    reg = studio_templates.load_path([root + "/nope", a, root + "/also-nope"])
    show(reg, root)
  end if

  ' ---- from: text held in a file beside the declaration --------------------
  if mode = "from" then
    d = root + "/d"
    persist.ensure_dir(d)
    writef(d + "/body.txt", "line one for {{who}}\nline two\n")
    writef(d + "/f.templates", "{\"templates\":[" +
      "{\"id\":\"filed\",\"fields\":[{\"name\":\"who\"}],\"from\":\"body.txt\"}," +
      "{\"id\":\"absent\",\"from\":\"nope.txt\"}," +
      "{\"id\":\"absolute\",\"from\":\"/etc/hostname\"}," +
      "{\"id\":\"climbing\",\"from\":\"../../etc/hostname\"}," +
      "{\"id\":\"tilde\",\"from\":\"~/.bashrc\"}]}")
    reg = studio_templates.load_path([d])
    show(reg, root)
    print ""
    ' A `from` is a path beside the file that declared it and nothing else. A
    ' template file is a thing you can be SENT, and an absolute path or a climb
    ' would make sending one a way to read somebody's disk into a new project's
    ' README.
    print "== and the text came out of the file =="
    fill(reg, "filed", { who: "Ada" })
  end if

  ' ---- render: the holes, and the one pass over them -----------------------
  if mode = "render" then
    e = root + "/e"
    persist.ensure_dir(e)
    writef(e + "/r.templates", "{\"templates\":[" +
      "{\"id\":\"greet\",\"fields\":[{\"name\":\"who\",\"required\":true}],\"text\":\"hello {{who}}!\"}," +
      "{\"id\":\"spaced\",\"fields\":[{\"name\":\"who\"}],\"text\":\"hello {{ who }}\"}," +
      "{\"id\":\"twice\",\"fields\":[{\"name\":\"who\"}],\"text\":\"{{who}} and {{who}}\"}," +
      "{\"id\":\"optional\",\"fields\":[{\"name\":\"note\",\"default\":\"(none)\"}],\"text\":\"note: {{note}}\"}," +
      "{\"id\":\"braces\",\"text\":\"a {{ with no closer after it\"}," +
      "{\"id\":\"spanning\",\"text\":\"a {{ and, much later, a }} do make a hole\"}," +
      "{\"id\":\"two\",\"fields\":[{\"name\":\"a\"},{\"name\":\"b\"}],\"text\":\"[{{a}}][{{b}}]\"}]}")
    reg = studio_templates.load_path([e])
    show(reg, root)

    print ""
    print "== filling them =="
    fill(reg, "greet", { who: "Ada" })
    fill(reg, "spaced", { who: "Ada" })
    fill(reg, "twice", { who: "Ada" })
    fill(reg, "optional", {})
    fill(reg, "optional", { note: "hi" })
    fill(reg, "braces", {})
    fill(reg, "nosuch", {})

    ' A `{{` with nothing after it is literal -- far likelier to be somebody's
    ' actual braces than an unclosed placeholder, and a registry that refused
    ' to load over a brace in a comment would be worse than useless. But a
    ' `{{` and a `}}` ANYWHERE after it are a hole, however much prose is
    ' between them, and `spanning` above is refused at LOAD naming exactly what
    ' it read as the name. Loud and early beats a file delivered with a
    ' sentence missing out of it.

    ' A required field with no value REFUSES rather than substituting empty,
    ' for the reason the licence refusal already gives: a file that is not the
    ' thing it claims to be is worse than no file.
    print ""
    print "== a required hole with nothing to put in it =="
    fill(reg, "greet", {})
    fill(reg, "greet", { who: "" })

    ' ONE PASS. A value carrying `{{b}}` is output verbatim and never looked at
    ' again -- which repeated `replace()` calls would not do, because the
    ' second call would reach into the first call's output. That is the defect
    ' that never shows up until the day somebody's project is called
    ' `{{holder}}`.
    print ""
    print "== a value that looks like a placeholder is not one =="
    fill(reg, "two", { a: "{{b}}", b: "SECRET" })

    print ""
    print "== what a text asks for =="
    for each t in ["plain text", "{{a}} and {{b}} and {{a}}", "{{ spaced }}", "an unclosed {{ brace", "}} alone"]
      print "  <" + t + "> -> " + string(studio_templates.placeholders(t))
    end for
  end if

  ' ---- path: which directory wins -----------------------------------------
  if mode = "path" then
    ' Ordered by how specific the context is: the project you are in beats the
    ' machine you are on, which beats a library you loaded, which beats what
    ' Studio shipped. The FIRST one holding an id wins, and the ones after it
    ' say so rather than vanishing.
    print "== the search path, in precedence order =="
    for each d in studio_templates.search_path("/p/tpl", "/home/me/.gbasic-studio", "/usr/share/gbasic/stdlib", "/usr/share/gbasic-studio")
      print "  " + d
    end for
    print "  with no project and no stdlib:"
    for each d in studio_templates.search_path("", "/home/me/.gbasic-studio", "", "/usr/share/gbasic-studio")
      print "    " + d
    end for

    print ""
    print "== and an id declared twice =="
    p1 = root + "/near"
    p2 = root + "/far"
    persist.ensure_dir(p1)
    persist.ensure_dir(p2)
    writef(p1 + "/x.templates", "{\"templates\":[{\"id\":\"greet\",\"text\":\"near\"}]}")
    writef(p2 + "/x.templates", "{\"templates\":[{\"id\":\"greet\",\"text\":\"far\"},{\"id\":\"only-far\",\"text\":\"far only\"}]}")
    reg = studio_templates.load_path([p1, p2])
    show(reg, root)
    print ""
    fill(reg, "greet", {})
    fill(reg, "only-far", {})
  end if

  ' ---- ship: the templates Studio actually installs ------------------------
  if mode = "ship" then
    ' Asserted byte-for-byte, because these are what New Project writes into
    ' somebody's directory. A registry with no consumer would be speculative;
    ' this is the consumer's data.
    share = env("GBASIC_STUDIO_SHARE")
    reg = studio_templates.load_path([share + "/templates"])
    show(reg, root)
    print ""
    print "== what New Project writes =="
    fill(reg, "project.main", { project: "My Thing" })
    fill(reg, "project.readme", { project: "My Thing" })
    fill(reg, "project.readme_licensed", { project: "My Thing", license: "MIT" })
    fill(reg, "project.gitignore", {})
  end if
end program
