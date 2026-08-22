' Is the native GListModel adapter in this interpreter? It is behind gio-2.0, so
' a build without it must SKIP the virtualization tier rather than fail it.
program main(args)
  m = rowmodel.new(1)
  rowmodel.set_count(m, 3)
  print "rowmodel:" + rowmodel.count(m)
end program
