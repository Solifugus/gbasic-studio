# share/fonts/ — the fonts a book figure is drawn in

`./studio shoot` points `FONTCONFIG_FILE` at `fonts.conf` here, and that file
lists THIS directory and nothing else. So a figure is drawn in these two
families on every machine, whatever the host has installed, and two runs on
two machines give the same pixels. They are not used by the ordinary window,
which keeps the desktop's own fonts.

| file | family | used for | licence |
|---|---|---|---|
| `NotoSans-Regular.ttf`, `NotoSans-Bold.ttf` | Noto Sans | the window's text | SIL OFL 1.1 (`OFL-1.1.txt`) |
| `DejaVuSansMono.ttf`, `DejaVuSansMono-Bold.ttf` | DejaVu Sans Mono | the editor, and the glyphs Noto lacks | Bitstream Vera, DejaVu changes public domain (`LICENSE-DejaVu.txt`) |

**Provenance.** Copied unmodified from Ubuntu's packages `fonts-noto-core`
20201225-2build1 and `fonts-dejavu-core` 2.37-8build1. SHA-256:

```
89c3c497f618fdaa0b2d1e98fef93582f28c71debd2c4a8cdf41f190ced2909d  NotoSans-Regular.ttf
e83493c945848ecd4a9ad0f6d19164541a0d3e23a9c952304a00a46e00272ac5  NotoSans-Bold.ttf
a54dca07c76d6289e717e75e0a58c0128f6d7269ef3faf76417c9d7d3bba37ab  DejaVuSansMono.ttf
2d67eed9b325ee2e69f906ce4f3f6264d5105230a13352c8494daad4f17b12c8  DejaVuSansMono-Bold.ttf
```

The licence texts are verbatim: the DejaVu/Vera text as the package's
`copyright` file carries it, and the canonical OFL 1.1 text with Noto's holders
above it. Both licences allow redistributing the fonts with software; neither
covers a document made with them, so a book's figures carry no font licence.

**What Noto Sans lacks.** It has no `●` `○` `▾` `▸`, the glyphs the file tree
draws, so fontconfig takes them from DejaVu Sans Mono, the only other font on
the list. That is deterministic, which is what a figure needs.

**No italic face is shipped.** Nothing Studio draws in a figure is italic
today; if something becomes italic, fontconfig slants the upright face, which
is also deterministic, and an italic file can be added here then.
