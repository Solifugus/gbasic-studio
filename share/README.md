# share/ — the desktop files Studio ships

An application that draws a window is expected to have a name, an icon and a
desktop entry, and Studio had none of the three: `set_icon_name` was never
called, so every window carried the toolkit's fallback, and nothing in the
repository told a desktop environment what Studio was.

```
share/applications/org.gbasic.Studio.desktop   the desktop entry
share/icons/hicolor/<size>/apps/org.gbasic.Studio.png   the icon, 16 … 256
```

The name is the application id `app/studio.bas` already registers with GTK,
`org.gbasic.Studio`, so the entry, the icon and the window agree without anyone
having to keep three spellings in step.

The icon is the gBASIC mascot from `~/development/gbasic/docs/assets/mascot.png`,
squared to the beaver and resampled to each hicolor size. It is a raster and not
an SVG because the mascot is a raster; a real release should draw a vector
version, since 16px of a 1629px illustration is a smudge no downsampler can save.

**How the window finds it without a display-wide call.** Registering an extra
icon directory at run time needs `Gtk.IconTheme.get_for_display`, a class static
the `gi` bridge cannot resolve — the same limitation that keeps Studio's CSS
providers per-widget (see `lib/studio_style.bas`). So the path is supplied from
outside the process instead: `./studio` prepends this directory to
`XDG_DATA_DIRS`, which is where GTK looks for icon themes at startup. Installed
the ordinary way — these two trees copied into `/usr/local/share` or
`~/.local/share` — the same name resolves with nothing set at all.
