# share/ — the desktop files Studio ships

An application that draws a window is expected to have a name, an icon and a
desktop entry, and Studio had none of the three: `set_icon_name` was never
called, so every window carried the toolkit's fallback, and nothing in the
repository told a desktop environment what Studio was.

```
share/applications/org.gbasic.Studio.desktop   the desktop entry
share/icons/hicolor/<size>/apps/org.gbasic.Studio.png   the icon, 16 … 256
share/icons/toolbar/*.svg                      the Qt toolbar's icons for the DARK theme
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

The name is the application id, `org.gbasic.Studio`, so the entry and the icon
agree without anyone having to keep two spellings in step.

(The GTK window shipped a gutter error icon here too, because a
`GtkSource.MarkAttributes` drew from an icon NAME and neither freedesktop name
resolved on every theme. The Qt editor's margin draws its own marks, so that
file went with GTK.)

The application icon is the gBASIC mascot from `~/development/gbasic/docs/assets/mascot.png`,
squared to the beaver and resampled to each hicolor size. It is a raster and not
an SVG because the mascot is a raster; a real release should draw a vector
version, since 16px of a 1629px illustration is a smudge no downsampler can save.

**How a desktop finds it.** `./studio` prepends this directory to
`XDG_DATA_DIRS`, where desktop environments look for entries and icon themes.
Installed the ordinary way — these two trees copied into `/usr/local/share` or
`~/.local/share` — the same name resolves with nothing set at all.

## The Qt toolbar's dark icons

`icons/toolbar/` holds five SVGs — `save`, `reload`, `open-folder`,
`new-file`, `new-folder` — drawn in a light stroke for Studio's dark theme.

**They exist because a stylesheet cannot recolour a style's own icon.** The
toolbar's declared icons are `SP_` standard pixmaps, Qt's own 81, which are
the only source that works on a machine with no desktop icon theme installed
— and this one has none. Qt's style draws them **from the palette**, and
`qt.theme` sets a stylesheet, which does not move the palette. On a dark strip
they were dark glyphs on dark: measured invisible, while `qt.has_icon` went on
answering true for every one of them.

**SVG rather than PNG**, for two reasons. Qt ships an icon-engine plugin for
it (`libqsvgicon.so`), so a QIcon re-renders at whatever size it is asked for
— where the 24px bitmaps these replaced were resampled and soft at 200%
scaling, and the conventional fix is `@2x` variants, which is two files per
icon and a naming rule. And **an SVG is its own provenance**: it is text, it
diffs, and a reader can see what the shape is without running a generator.
That is the same argument that keeps `templates/` declarative. Apache-2.0 with
the rest of Studio, like everything else here that Studio authored — as
opposed to `licenses/`, which is verbatim upstream text with its own README.

**24x24 viewBox, 2px stroke, `#d6d6d6`** (`studio_style.dark_fg()`), with the
two "new" icons carrying a `#4a9eff` plus (`accent_color`). Keeping the stroke
weight identical across the five is what makes them look like a set.

**Studio falls back to labels if they cannot be used.** Two different failures,
both handled: `qt.set` refuses a path that is not there, so `studio_style`
checks the directory first; and it refuses a file **Qt cannot read**, which a
build without the SVG plugin would make of all five — that one cannot be
answered from the filesystem, so `app/studio.bas`'s `qt_apply_toolbar`
catches the refusal and switches the toolbar to text. Both paths are exercised:
a corrupt `save.svg` and a missing `share/` each produce a toolbar of words and
a line on stderr, not a window that will not open.
