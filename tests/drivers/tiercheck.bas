' Every act tool must declare a permission tier, and it must be a real one.
' A tool with no tier is a tool nothing gates: `tier_of` answers "read" for it,
' which for something that writes is the worst available default.
program main(args)
  load studio_tools
  load studio_permissions
  bad = 0
  for each t in studio_tools.act_registry()
    if not has(t, "tier") then
      print "no tier: " + t.name
      bad = bad + 1
    else
      if not studio_permissions.is_tier(t.tier) then
        print "not a tier: " + t.name + " -> " + t.tier
        bad = bad + 1
      end if
      if t.tier = "read" then
        print "an act tool cannot be read-tier: " + t.name
        bad = bad + 1
      end if
    end if
  end for
  if bad > 0 then
    print "FAIL " + bad
    exit(1)
  end if
end program
