# share/ — the desktop files Studio ships

An application that draws a window is expected to have a name, an icon and a
desktop entry, and Studio had none of the three: `set_icon_name` was never
called, so every window carried the toolkit's fallback, and nothing in the
repository told a desktop environment what Studio was.

```
share/applications/org.gbasic.Studio.desktop   the desktop entry
share/icons/hicolor/<size>/apps/org.gbasic.Studio.png   the icon, 16 … 256
share/icons/hicolor/<size>/status/gbasic-studio-error.png   the gutter's error mark, 16/24/32
share/icons/toolbar/*.png                      the Qt toolbar's icons for the DARK theme
share/icons/toolbar/make_icons.py              the script that authored them
share/licenses/<spdx-id>.txt                   the licence texts New Project can write
share/templates/project.templates              the boilerplate New Project renders
share/templates/sql.templates                  the statements the SQL builders write
```

Not everything here is a desktop file. `licenses/` and `templates/` are DATA
the application reads: Studio does not author a licence, it copies one of these
and fills in the year and the author. Its own README records where each text came from, so
a reader can check the provenance rather than take it on trust. The directory
is found through `GBASIC_STUDIO_SHARE`, which `./studio` exports for the same
reason it exports `GBASIC_STUDIO_VIEWERS` — an installed copy keeps `share/`
somewhere else, and Studio's own working directory is never the answer.

`templates/` is the same idea one step further: the `main.bas`, `README.md`
and `.gitignore` New Project writes are DECLARED here rather than written out
in gBASIC, with `{{project}}` holes that `studio_templates` fills. They are
read and never run — there are no expressions, no conditionals and no loops in
a template, because a file somebody can drop into a templates directory must
not be able to execute anything. That is the same line `viewers/` holds, and
`templates_declarative` greps for it.

The licence texts keep their own `[year]` / `[fullname]` markers and are NOT
converted to `{{...}}`. Those markers are upstream's convention — it is how
choosealicense.com ships them — and `licenses/README.md` exists to say that
each text is verbatim. Reformatting them would be editing the provenance to
suit our placeholder syntax.

The name is the application id `app/studio.bas` already registers with GTK,
`org.gbasic.Studio`, so the entry, the icon and the window agree without anyone
having to keep three spellings in step.

**Why the gutter mark is here and not a stock name.** The editor marks the line
a parse failed on, and a `GtkSource.MarkAttributes` draws that mark from an icon
NAME. `dialog-error` and `dialog-error-symbolic` are both standard freedesktop
names and neither one resolved: this machine's Breeze ships the first and not
the second, its Adwaita ships the second and not the first, and what the gutter
actually drew was GTK's missing-icon fallback — a grey disc wide enough to sit
on top of the code. A marker that lands on the wrong icon is worse than no
marker, so the name is Studio's own and the file ships here, in `hicolor`, which
every icon theme inherits.

(`MarkAttributes.set_background` would have avoided icons altogether, but it
takes a `Gdk.RGBA` and `gi.new` refuses that type: "not an instantiable object
type". Same class of gap as the class statics below.)

The application icon is the gBASIC mascot from `~/development/gbasic/docs/assets/mascot.png`,
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

## The Qt toolbar's dark icons

`icons/toolbar/` holds five PNGs — `save`, `reload`, `open-folder`,
`new-file`, `new-folder` — drawn in a light stroke for Studio's dark theme,
plus the script that authored them.

**They exist because a stylesheet cannot recolour a style's own icon.** The
toolbar's declared icons are `SP_` standard pixmaps, Qt's own 81, which are
the only source that works on a machine with no desktop icon theme installed
— and this one has none. Qt's style draws them **from the palette**, and
`qt.theme` sets a stylesheet, which does not move the palette. On a dark strip
they were dark glyphs on dark: measured invisible, while `qt.has_icon` went on
answering true for every one of them.

**The provenance is the script.** `make_icons.py` is not a build step and
nothing runs it automatically; it is here so that "where did these come from"
has an answer better than "somebody drew them". Run it and it rewrites exactly
the bytes beside it, and `--contact-sheet` composites the five on Studio's own
toolbar colour so they can be looked at rather than guessed at. Apache-2.0
with the rest of Studio, like everything else here that Studio authored — as
opposed to `licenses/`, which is verbatim upstream text with its own README.

**Studio falls back to labels if they are missing.** `qt.set` REFUSES an icon
path that is not there, rather than warning, so `studio_style` checks before
offering one: an installed copy that did not ship this directory gets a
toolbar of words while dark instead of a window that will not open.
