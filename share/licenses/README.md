# The licence texts New Project can write

Studio does not *author* a licence. When the New Project window is asked for
one it copies the file named here, substituting `[year]` and `[fullname]` in the
two that carry them. Nothing here is generated, paraphrased or reformatted.

Where each came from, so a reader can check rather than trust:

| File | Provenance |
| --- | --- |
| `Apache-2.0.txt` | `/usr/share/common-licenses/Apache-2.0`, byte-identical to gBASIC's own `LICENSE` — two independent copies agreeing |
| `GPL-3.0.txt` | `/usr/share/common-licenses/GPL-3`, verbatim |
| `MPL-2.0.txt` | `/usr/share/common-licenses/MPL-2.0`, verbatim |
| `MIT.txt` | body word-for-word identical to the copy shipped with `asn1crypto`, cross-checked against Debian's `python3-zipp` copyright; the `Copyright (c) [year] [fullname]` line is the placeholder |
| `BSD-3-Clause.txt` | `/usr/share/common-licenses/BSD` with **four** substitutions, each replacing the University-of-California wording with the SPDX template's: the copyright line, "the name of the University" → "the name of the copyright holder", and "THE REGENTS" → "THE COPYRIGHT HOLDER(S)" twice. `diff` against the system file shows exactly those four lines. |

Adding one means putting the text here and naming it in
`studio_ui.license_ids()`. A licence whose file is missing is offered by the
window and **refused** by `project_plan` rather than written empty: a LICENSE
file that is not the licence is worse than no LICENSE file.

`[year]` and `[fullname]` are the SPDX placeholder spellings. A template whose
holder would come out blank is refused too — a licence naming nobody grants
nothing, and the window has the field right there to fill in.
