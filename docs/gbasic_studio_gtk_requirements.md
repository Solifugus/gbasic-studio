# gBASIC Studio — Native-GTK Requirements Spec

Status: **engineering specification, not implemented.** Companion to
`docs/gbasic_studio_research.md`; this expands and supersedes that report's §4.1
under a fixed premise.

**Premise (given):** gBASIC Studio *will* be written primarily in gBASIC with a
**native GTK4 UI** driven through the `gi` GObject-Introspection bridge. This
document does **not** relitigate that choice. It determines, precisely and against
the current code, exactly what must be added to the `gi` bridge and to gBASIC's
libraries to make that architecture practical — with each gap tied to the specific
IDE surface it unblocks, the exact C site to change, an effort estimate (S ≤ ~2 days,
M ≤ ~2 weeks, L > ~2 weeks of focused work), and a priority.

All `file:line` citations are in `src/eval.c` unless noted.

---

## 0. Approach: three layers, not one

Driving *every* IDE surface cell-by-cell through the generic FFI is neither
necessary nor wise. The practical path is **layered**:

1. **Generic bridge extensions (§2)** — a bounded set of additions to the existing
   `gi.*` marshalling that unblock the large majority of the UI, which is ordinary
   GTK4 widgets (panes, tabs, trees, menus, dialogs, CSS). These are broadly useful
   beyond Studio.
2. **A thin native "Studio widgets" C module (§3)** — for the two surfaces that are
   genuinely impractical to drive over an FFI even after §2 (the **source editor**
   and, optionally, a **data grid**), wrap the underlying GTK widget **once in C**
   and expose an ergonomic record/array gBASIC API. This is far smaller than making
   the generic bridge handle `GtkTextIter`-level editing, and it lets Studio adopt
   GtkSourceView's mature highlighting/undo/search instead of reimplementing them.
3. **A gBASIC ergonomic/UI layer (§4)** — the deferred `.property`/`.method()`
   dispatch hook plus a declarative widget-tree library, so Studio UI code reads
   like UI code, not like `gi.call(obj, "append", child)` noise.

The generic bridge does **not** need to become a complete PyGObject-class FFI. It
needs the specific capabilities below and no more.

---

## 1. What already works (do not rebuild)

Verified reachable through the current bridge — the IDE can lean on these as-is:

- **Object lifecycle & identity:** `gi.new` with construct-time properties, qdata
  canonical wrapping, refcount/floating-ref correctness (`gi_canonical_wrap`,
  12639-12671). Widgets are ordinary gBASIC values; runtime construction/insertion
  works.
- **Properties:** `gi.get`/`gi.set` for scalar/string/object/enum props (12675-12740).
- **Methods with scalar/string/object/enum args and returns:** `gi.call`
  (13272), `gi.invoke` for namespace functions (13331).
- **Signals → gBASIC functions:** `gi.connect`/`gi.disconnect` via a generic
  `GClosure` marshaller with error snapshot/restore (`gi_signal_marshal`, 12915).
  **This already covers `GtkSignalListItemFactory` setup/bind signals and
  GAction `activate`** where the args are objects — a crucial fact for §2.
- **Enums/flags:** `gi.enum`, `gi.is_a`, `gi.type_name` (13430+).
- **Main loop:** `gi.main`/`gi.quit` (a `GMainLoop`), or `GApplication.run`.
- **CSS theming (already reachable, no work needed):** `gtk_css_provider_new`,
  `gtk_css_provider_load_from_string`/`load_from_data` (string arg),
  `gtk_style_context_add_provider_for_display`, and
  `gtk_widget_add_css_class`/`remove_css_class` (string args) all pass through the
  existing scalar/string/object marshalling. Studio styling is a solved problem.

Everything the IDE needs beyond this list is enumerated below.

---

## 2. Generic bridge extensions (the required core)

Each work item names the exact gBASIC surface it unblocks. Priority: **P0** = the
IDE cannot function without it; **P1** = a major surface is missing without it;
**P2** = quality/scope, deferrable.

### WI-1 — Boxed/struct value type + marshalling · **P0 · M**

**Gap.** `GI_TYPE_TAG_INTERFACE` in the marshallers handles only object/enum
interfaces; **structs (boxed types) fall through to failure**
(`gi_value_from_giarg` 12803-12818, `gi_giarg_from_value` 12847-12861,
`gi_value_from_gvalue` default 12702, `gi_value_to_gvalue` default 12737). So
`GtkTextIter`, `GtkTreeIter`, `GdkRGBA`, `GdkRectangle`, `Graphene.Rect`,
`GtkTextChildAnchor`-adjacent structs, and `Gtk.Border` cannot cross the boundary.

**Add.** A new value kind `VALUE_GBOXED` wrapping `{ GType type; gpointer box;
int owned; }`, allocated via `g_boxed_copy`/freed via `g_boxed_free` in
`value_copy`/`value_free` (mirror the existing `GObjectValue` refcount pattern at
227-260, 1220-1335). Extend all four marshalling functions to detect
`GI_IS_STRUCT_INFO`/`G_TYPE_IS_BOXED` and wrap/unwrap. Add a `gi.new_struct(
"Ns.Struct")` and field access (see WI-2/WI-8) so gBASIC can construct and read
these.

**Unblocks.** The prerequisite for WI-2 (out-params are mostly structs), for
`GdkRGBA` color work, geometry, and any struct-taking method.

### WI-2 — Out / inout argument support · **P0 · M**

**Gap.** `gi_invoke_callable` **hard-rejects any non-IN argument**
(13221-13228). A large fraction of GTK4's read APIs return data through
caller-allocated out-params: `gtk_text_buffer_get_bounds(&start,&end)`,
`gtk_text_buffer_get_iter_at_line(buf,&iter,n)`, `gtk_text_view_get_iter_at_location`,
`gtk_widget_measure(...)`, `gtk_tree_model_get_iter`, `gdk_rgba_parse(&rgba,str)`,
`gtk_editable_get_selection_bounds(&a,&b)`.

**Add.** In `gi_invoke_callable`: for `GI_DIRECTION_OUT`/`GI_DIRECTION_INOUT`,
allocate the out storage (a `GIArgument` slot; for caller-allocated structs, a
stack/boxed buffer via WI-1), pass its address, and after invoke **collect the
out-values**. When there is exactly one out-value and a void return, return it
directly; when there are several (or an out-value plus a real return), return a
**record** keyed by arg name (or an array). This is the single most important
unlock: it makes `GtkTextView`/`GtkTextBuffer` and tree models *queryable*.

**Unblocks.** Text iteration/measurement/hit-testing; tree-model reads; geometry;
color parsing. Combined with WI-1, most of the "blocked" getter surface.

### WI-3 — Signal-handler return values · **P0 · S**

**Gap.** `gi_signal_marshal` casts `return_gvalue` to void (12918) — a gBASIC
handler **cannot return a value to GTK**.

**Add.** After `invoke_function`, if `return_gvalue` is non-NULL, convert the
handler's return `Value` into it via `gi_value_to_gvalue` (guard type mismatch).
Free the returned Value as today.

**Unblocks.** `close-request` (return TRUE to veto/confirm-on-exit — essential for
an IDE that must prompt on unsaved changes), `GtkEventControllerKey::key-pressed`
(return TRUE to consume — required for editor keybindings and command palette),
`GtkGestureClick` accept/reject, scroll handling.

### WI-4 — GLib event-source builtins (loop integration) · **P0 · S**

**Gap.** No `idle_add`/`timeout_add`/`io_add_watch` binding exists, so a running
GTK loop **cannot poll an actor mailbox or a socket** — background work either
blocks the UI or never reports back. (Confirmed absent in the audit.)

**Add.** Three builtins wrapping GLib sources with the existing gBASIC-function
closure pattern (reuse `GiClosureData` + `function_resolve` from 12894-12922):
- `gi.timeout(ms, fn)` → `g_timeout_add` (return handler stops the source when it
  returns false);
- `gi.idle(fn)` → `g_idle_add`;
- `gi.watch_fd(fd, fn)` → `g_unix_fd_add` (poll an actor mailbox fd or a socket).
Each returns a source id; add `gi.source_remove(id)`.

**Unblocks.** The entire async story: run a section/branch in a spawned actor
(already works, 8299-8360), `gi.watch_fd` its mailbox, and update the UI when the
result arrives — **without freezing the editor.** This is what makes the IDE
usable during long ETL/stat runs. Small but load-bearing.

### WI-5 — Callback-argument marshalling · **P1 · L**

**Gap.** The bridge marshals **signals** (via `GClosure`) but not **callback
arguments** typed `GI_TYPE_TAG_INTERFACE`/`GICallbackInfo`. Several key APIs take a
C-callback argument rather than a signal: `gtk_drawing_area_set_draw_func`
(custom drawing, gives a `cairo_t`), the `GAsyncReadyCallback` of
`gtk_file_dialog_open()`/`save()` (GTK4 file chooser is async), and various
`*ForeachFunc`.

**Add.** Runtime C-closure generation. The robust route is **vendoring libffi**
(as PyGObject/GJS do): use `GICallbackInfo` to build a `ffi_cif`, create a
`ffi_closure` whose C entry converts native args → gBASIC values (via WI-1/WI-2
marshalling), runs the gBASIC function, and converts the return back. Expose no new
syntax — a `VALUE_FUNCTION` passed where a callback is expected is wrapped
automatically. **Lower-dependency alternative for v1:** hand-write trampolines for
only the two callback signatures Studio actually needs — `GtkDrawingAreaDrawFunc`
and `GAsyncReadyCallback` — avoiding libffi entirely at the cost of generality.

**Unblocks.** Custom drawing (minimap, gutters, custom viewers) via
`GtkDrawingArea` **without subclassing** (WI-9 stays optional), and native
file-open/save dialogs. Recommend the libffi route if custom viewers proliferate;
the hand-rolled route if the editor+grid native module (§3) covers drawing needs.

### WI-6 — GVariant construction/parsing · **P1 · S–M**

**Gap.** `GVariant` is a boxed type the bridge cannot build (WI-1 covers the
*handle* but GVariant needs typed constructors). GTK4 actions and menus are
`GAction`/`GMenu`/`GMenuModel` + `GVariant` parameters:
`gtk_widget_activate_action(w, "win.save", NULL)`,
`g_simple_action_new_stateful`, action state.

**Add.** A small `gi.variant(...)` helper set: `gi.variant_string(s)`,
`gi.variant_bool(b)`, `gi.variant_int(n)`, and a `gi.variant_parse(type, value)`
using `g_variant_new`/`g_variant_parse`; plus reading state back with
`g_variant_get_*`. Marshal `GVariant*` through the `GI_TYPE_TAG_INTERFACE` path
(WI-1 boxed).

**Unblocks.** Application menus, the menubar/gear-menu, keyboard-accelerator
actions (`gtk_application_set_accels_for_action`), and stateful toggle actions —
i.e. the whole command surface of a real IDE.

### WI-7 — Array / GList / GStrv marshalling · **P1 · M**

**Gap.** Containers are **NULL-only** in both directions (13862-13871). Real lists
never cross.

**Add.** Marshal at least: `char**`/`GStrv` and `GI_TYPE_TAG_ARRAY` of UTF8 ⇄
gBASIC string array; `GList`/`GPtrArray` of GObject ⇄ gBASIC object array. Use the
element `GITypeInfo` (`gi_type_info_get_param_type`) to drive per-element
marshalling (reuse WI-1/WI-2 element converters). Honor transfer annotations for
free.

**Unblocks.** `gtk_string_list_new(strv)` (a dead-simple list model — see §3
grid), `g_list_store`/model population, `gtk_file_dialog` multi-select results,
recent-files lists, completion candidate lists.

### WI-8 — Struct field get/set + a few constructors · **P1 · S**

**Gap.** Even with WI-1 wrapping, gBASIC can't read/write a boxed struct's fields
(e.g. a `GtkTextIter`'s line/offset, a `GdkRGBA`'s r/g/b/a) or construct simple
ones.

**Add.** `gi.struct_get(box, "field")` / `gi.struct_set(box, "field", v)` over
`GIFieldInfo` (`gi_struct_info_get_field`/`gi_field_info_get/set_field`), and
`gi.new_struct("Ns.Struct")` (zeroed) for caller-allocated out-params. Most iters
are opaque and accessed via methods (covered by WI-2), so this is mainly for
`GdkRGBA`, `GdkRectangle`, `Gtk.Border`.

**Unblocks.** Color/geometry manipulation; reading positions out of the structs
WI-2 returns.

### WI-9 — Runtime GType subclassing / vfunc override · **P2 · L**

**Gap.** No way to register a new GType with overridden virtual functions.

**Assessment.** **Deliberately deferred / likely unnecessary.** GTK4 custom
drawing is reachable via `GtkDrawingArea.set_draw_func` (a *callback*, WI-5), not a
subclass; list/tree rendering is reachable via `GtkSignalListItemFactory`
(*signals*, already work) rather than a custom cell renderer. The IDE should be
designed to avoid subclassing. Only pursue this if a surface genuinely needs an
overridden `GtkWidget.snapshot`/`measure` — none in the current Studio vision does.

### WI-10 — GError surfacing on out-returning methods · **P2 · S**

**Gap.** `gi_function_info_invoke` already threads a trailing `GError**` and raises
(13248-13253), so *most* fallible calls are fine. The residual gap is methods where
the error is an explicit `GI_TYPE_TAG_ERROR` **argument** (rare). Fold into WI-2's
out handling: an ERROR out-arg becomes a raised gBASIC error, not a value.

---

## 3. Native "Studio widgets" C module (`gi`-adjacent, `HAVE_GIR`)

Two surfaces are impractical to drive over the generic FFI even after §2, because
they involve high-frequency, iterator-level interaction. Wrap each **once in C** and
expose a record/array API. This is *less* code than pushing WI-1/WI-2 to cover
`GtkTextIter`-level editing performantly, and it buys mature widget behavior.

### SW-1 — Source editor widget · **P0 · M** (the highest-value item in this doc)

**Why native.** A code editor touches the buffer thousands of times per second
(highlighting, cursor tracking, selection, undo). Marshalling every `GtkTextIter`
through WI-1/WI-2 would be both slow and painful. Wrapping the widget once is the
right call — and it lets Studio use **GtkSourceView** (highlighting engine, undo,
search/replace, bracket matching, line numbers) instead of reinventing them.

**Expose (returns/takes ordinary gBASIC values):**
- `studio_editor.new()` → a GObject value (a `GtkSourceView` in a `GtkScrolledWindow`).
- `studio_editor.text(ed)` / `studio_editor.set_text(ed, s)` — whole buffer.
- `studio_editor.cursor(ed)` / `set_cursor(ed, line, col)`; `scroll(ed)` /
  `set_scroll(ed, y)` — **the workspace-restoration primitives** the continuity
  vision needs.
- `studio_editor.on_change(ed, fn)`, `on_cursor(ed, fn)` — debounced.
- `studio_editor.highlight(ed, ranges)` — apply syntax spans from gBASIC's **own**
  tokenizer (the LSP/`--tokens` path already tokenizes gBASIC; feed those spans as
  tags), or register gBASIC as a GtkSourceLanguage.
- `studio_editor.mark(ed, line, kind)` — gutter marks for boundaries/breakpoints.
- **`studio_editor.add_inline(ed, line, widget)`** — insert a child widget at a
  `GtkTextChildAnchor`: this is exactly how the **inline execution-boundary bars**
  and the **horizontal branch tab strip** `[ Baseline ][ Robust ][ + ]` get injected
  into the source flow. Without a native wrapper this needs WI-1 anchors + iters;
  wrapping it is trivial in C.

**Dependency.** GtkSourceView 5 (`gir1.2-gtksource-5`, **LGPL-2.1** — dynamically
linked, compatible). If avoiding the dependency, fall back to raw `GtkTextView` +
gBASIC-side highlighting via tags (more work, no undo/search for free). Recommend
GtkSourceView.

### SW-2 — Data grid / tree widget · **P1 · M** (optional but high-value)

**Why native.** The value inspector's "array-of-records → table", "matrix → grid",
and "nested record → tree" viewers (research doc §10) map to `GtkColumnView`/
`GtkTreeListModel` + factories + selection models. That is buildable over WI-3
(signal returns) + WI-7 (lists) + WI-6, but it is fiddly. A one-time C wrapper is
cleaner:
- `studio_grid.new(columns)`; `studio_grid.set_rows(g, array_of_records)`;
  `studio_grid.on_activate(g, fn)`; `studio_grid.filter(g, predicate_fn)`.
- `studio_tree.new()`; `studio_tree.set_root(g, nested_record)`.
Internally backs a `GListModel` from the gBASIC array and rebinds on `set_rows`,
sidestepping "GListModel-of-gBASIC-records-as-GObjects" marshalling entirely.

**Trade-off.** If the team prefers minimal C, this can instead be built in gBASIC
over WI-3/WI-6/WI-7 once those land — at higher gBASIC-code cost. SW-1 is not
optional; SW-2 is.

---

## 4. gBASIC library / language-ergonomics additions

Native widgets are unusable at scale without ergonomic gBASIC on top.

### LE-1 — `.property` / `.method()` dispatch hook · **P0 · M** (language)

Today member access is hardwired to `VALUE_RECORD` and method receivers are limited
to single-identifier record variables (per `PLAN.md` "Deferred — Dynamic property
get/set hook + native `.property`/`.method()` syntax", `PLAN.md:547-559`). All UI
code is therefore `gi.set(win,"title","x")` / `gi.call(win,"present")`. For a
codebase the size of an IDE this is untenable.

**Add** (as PLAN.md scopes it): a getter branch in `AST_EXPR_FIELD` and a **setter
callback** branch in `assign_lvalue` (note `resolve_lvalue_ref` returns a slot and
can't express a setter), plus `eval_call`/grammar work for native-receiver and
chained methods. Then `win.title = "x"`, `box.append(child)`, `ed.cursor.line`
read naturally over the raw bridge. This is the largest *language* change here and
the biggest ergonomic multiplier; everything in §2/§3 is far more pleasant behind
it.

### LE-2 — Idiomatic `gtk.bas` wrapper library · **P1 · S–M** (pure gBASIC)

A thin stdlib library over the (now sugared) bridge: named constructors
(`gtk.button(label)`, `gtk.box("v")`, `gtk.paned("h", a, b)`,
`gtk.notebook()`, `gtk.scrolled(child)`), enum-name helpers, and event helpers.
Pure gBASIC, no core change. Keeps Studio UI code declarative and short.

### LE-3 — Declarative widget-tree / reconciler · **P1 · M** (pure gBASIC)

The old `gui` module's fatal limit was **no dynamic tree mutation**
(`docs/gui_design.md:17`). Rebuild that idea *correctly* over `gi` in gBASIC: a
library that takes a record-tree UI description, builds the GTK widgets, and — on
change — **diffs and applies** (add/remove/reorder children via
`gtk_box_append`/`remove`, `gtk_stack_add_named`, etc., all reachable). This gives
Studio retained-mode declarative UI (open/close file tabs, inject branch strips,
rebuild the inspector) without the old static-tree restriction. Depends on LE-1 for
sane code and WI-7 only if it manipulates list models.

### LE-4 — Non-GTK support gaps (carried from the research doc)

Still required for the IDE as a whole, independent of GTK (research doc §4.2-4.3):
**subprocess-exec** (git CLI, tests), **file mtime/size + atomic rename**
(change-detection, crash-safe saves), **env-dump/serialize-all-top-level-vars**
(section replay + variable diffs), **`llm.bas` tool-calling** (agent loop). These
are unchanged by the native-GTK premise.

---

## 5. Dependency & licensing notes

- **GtkSourceView 5** (SW-1): LGPL-2.1, dynamically linked → compatible; gate behind
  a new `HAVE_GTKSOURCE` pkg-config check mirroring the existing optional-dep
  pattern in the Makefile. Degrade to the `GtkTextView` fallback when absent.
- **libffi** (WI-5, if the general route is chosen): BSD-ish, vendorable; already a
  transitive dependency of GLib on most systems. The hand-rolled-trampoline
  alternative needs no new dependency.
- **GTK4 typelibs** (`gir1.2-gtk-4.0`) and `libgtk-4` runtime: required for any of
  this to resolve; already assumed by the `gi` track. Note the coexistence guard
  (12985) already forbids GTK3 `gui` + GTK4 in one process — Studio is GTK4-only.
- Everything else (WI-1..WI-10, LE-1..LE-4) needs **no new dependency** — it is C
  against libgirepository/GObject/GLib already linked, plus gBASIC code.

---

## 6. What is explicitly NOT required (scope discipline)

To keep this practical, the IDE should be designed to avoid:

- **Runtime subclassing / vfunc overrides** (WI-9) — use draw funcs and factory
  signals instead.
- **A complete PyGObject-parity FFI** — no need to marshal every GLib type; the
  enumerated set suffices for the Studio surface.
- **GTK3** — GTK4 only (the coexistence guard enforces this).
- **Reimplementing a text engine or highlighting** — SW-1 delegates to
  GtkSourceView.
- **Async streaming transports for the UI** — the UI is in-process GTK; SSE/
  WebSocket gaps (research doc) matter only for an external MCP server, out of scope
  here.

---

## 7. Prioritized build order

Grouped so each group leaves Studio measurably more buildable.

**Group A — make widgets reachable and the loop non-blocking (P0):**
WI-1 (boxed) → WI-2 (out-params) → WI-3 (signal returns) → WI-4 (event sources).
After A: panes, tabs, menus-sans-actions, geometry, and *non-blocking background
execution* all work.

**Group B — the editor and ergonomics (P0):**
LE-1 (`.property`/`.method()`) in parallel with SW-1 (source editor). After B: a
real editable, highlighted, inline-widget-capable editor exists and UI code is
readable. **This is the milestone at which "an IDE in gBASIC" becomes real.**

**Group C — command surface and data views (P1):**
WI-6 (GVariant) + WI-7 (lists) → application menus/actions/accelerators; SW-2
(grid/tree) or its gBASIC equivalent → value inspector viewers; LE-2/LE-3
(`gtk.bas` + reconciler) → declarative UI; WI-8 (struct fields) as needed.

**Group D — polish (P1/P2):**
WI-5 (callbacks) → custom drawing + native file dialogs; WI-10 → error edges.
LE-4's non-GTK items land alongside per the research doc's phases.

**Group E — only if proven necessary (P2):**
WI-9 (subclassing).

---

## 8. Answer, precisely

To make "gBASIC Studio, primarily in gBASIC, native GTK4" practical, the **required**
additions are, in order:

1. **Bridge (P0):** boxed/struct values (WI-1), out/inout args (WI-2), signal-handler
   return values (WI-3), and GLib event-source builtins (WI-4).
2. **Editor + language (P0):** a native GtkSourceView-backed editor widget with an
   inline-child API (SW-1), and the `.property`/`.method()` dispatch hook (LE-1).
3. **Command surface + views (P1):** GVariant helpers (WI-6), list/array marshalling
   (WI-7), struct fields (WI-8), a grid/tree viewer (SW-2), and the gBASIC ergonomic
   layer (LE-2/LE-3).
4. **Polish (P1/P2):** callback marshalling for drawing/async dialogs (WI-5), GError
   edges (WI-10), plus the non-GTK items already tracked (LE-4).

**Not required:** runtime subclassing (WI-9), a full PyGObject FFI, GTK3, or a
hand-rolled text engine.

The load-bearing insight is that only **two** things need bespoke native widgets
(the editor, and — optionally — the data grid); everything else is either already
reachable (§1) or reachable after the bounded, broadly-useful bridge extensions in
Group A. That is what turns the native-GTK premise from "a huge open-ended FFI
project" into a scoped, ordered worklist.
