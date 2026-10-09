# Design notes

Background, measurements and decisions that shaped the implementation.
Written for future maintenance; the README covers usage. The measurements
come from private production codebases, called `cljs-app`
(ClojureScript), `next-app` (Next.js + next-intl), `dart-app` (Flutter)
and `email-app` (react-intl email templates) here. The generalization
requirements and their evidence live in `REQUIREMENTS.md`.

## Problem

The source repository (cljs-app) renders text through
`(tr [:translation-key "fallback"])` with translations in
`src/tr/cljs/<lang>.json` (flat key → string, 13 languages, ~2.2k keys each).
Measured facts from that codebase that motivated the plugin:

- 4,497 `tr`/`tr-release` call sites across 1,057 `.cljs` files.
- **99.3% of calls span multiple lines** (key and fallback string on different
  lines), because of the one-argument-per-line formatting style. Single-line
  regex-based i18n plugins would miss nearly every call here.
- **948 of 4,478 fallback-bearing calls (21%) disagreed with ko.json** at the
  time of measurement — wording drift like `"팀 / 1년"` vs `"팀당 / 연간"`.
  This is the core problem the plugin guards against.
- Near-identical function names exist as false-positive traps:
  `(transient [...])`, `(traverse [...])` — the defaults must anchor on exact
  call names, not a `tr.*` prefix.

The generalization round (2026-10-08) extends the plugin beyond that shape;
the requirements document records what failed against next-app
(next-intl: nested JSON G1, namespace composition G2, no inline fallback G3)
and what this implementation settled on, summarized below.

## Architecture

```
plugin/       commands, <Plug> mappings, highlight-group defaults (no setup
              needed); init.lua: setup() = config + rendering autocmds
config.lua    defaults + setup() + preset expansion + project-file merge;
              schema-driven validation and unknown-key detection
presets.lua   framework preset tables (next-intl, i18next, vue-i18n, flutter,
              gettext)
formats.lua   format registry: decode(raw, cfg) -> FLAT key->STRING map
              (json, arb, po); find_line(lines, key) -> lnum, col, len
resolve.lua   project discovery (walk-up), per-project cfg, catalogs
              (wildcard expansion, homes, `uses`), per-file lookup views
              (find/classify, "only in" another catalog), mtime+size file
              cache, language ordering (sorted_langs)
scan.lua      pattern scan (arity-dispatched), namespace bindings, fallback
              extraction, placeholder normalization, status classification
preview.lua   per-buffer state, debounced refresh, extmark rendering, display
              toggle, cursor-aware match lookup + on-demand re-scan
              (current_match, shared by hover/jump), per-buffer keymaps
hover.lua     per-language popover (own float, single instance, close-on-move)
jump.lua      :I18nJump — open the translation file at the key under the
              cursor (per-format line location via formats.find_line)
check.lua     project-wide audit -> quickfix, batched; per-catalog gaps and
              unused keys, ignore globs, nested projects skipped
health.lua    :checkhealth — project, catalogs, formats, unknown keys,
              resolution over the whole source tree (capped, budgeted)
util.lua      notify, paths, path globs, file reading, source-tree walk,
              offsets, truncation/quoting for display
```

Key decisions (original round):

- **Zero runtime dependencies.** Everything builds on `vim.api`, `vim.uv`,
  `vim.json`. No plenary, no tree-sitter requirement.
- **Pattern contract: capture #1 = key, then parse the next string literal
  manually.** Lua patterns cannot do alternation or escaped-quote-safe string
  matching; a hand-written literal parser (handling `\\`, `\"`, `\'`, `\n`,
  `\t`, backticks without `${`, rejecting unterminated literals) is more
  robust than trying to encode the fallback into the pattern.
- **Byte offsets → (line, col) via a line-offset table + binary search.**
  A naive "copy the prefix and count newlines" approach cost ~490 ms for the
  full repository scan; the table-based version runs the same scan in ~220 ms.
- **Extmark id reuse in scan order.** Each refresh sets extmarks with stable
  ids (1..N) and deletes the surplus, so unchanged marks keep their identity
  and there is no flicker.
- **Project file `.i18n-inline.json` wins over `setup()`.** Repository-local
  truth belongs in the repository; user config provides defaults. The file is
  parsed with the same mtime+size cache as translation files.
- **Silence outside projects.** Buffers that resolve to no project (no config
  file and no configured `dir` in any ancestor) get no state, no extmarks,
  no messages.

Key decisions (generalization round, settling REQUIREMENTS' open questions):

- **Flatten at decode time, not lazy path descent (Q2).** Every format
  decoder returns a flat key→value map (nested JSON flattened with
  `separator`), cached under the same mtime+size contract. Scan, hover and
  audit keep doing `keys[key]` — addressing complexity stays inside
  `formats.lua`. Collision policy: a nested path beats a literal dotted leaf
  key (`"a.b"` vs `{"a":{"b":…}}`); decided by segment count, so it is
  deterministic under arbitrary Lua table iteration order.
- **Pattern contract v2 by capture arity (Q1).** 1 capture = key (unchanged,
  Clojure shape). 2 captures = (receiver, subkey); the match survives only
  if the receiver is a namespace binding (key = ns..sep..sub) or an alias.
  Validated on the reference file before implementation: 22 raw receiver
  matches → 10 kept (all real i18n calls, correctly composed) and 12 noise
  drops (`cookieStore.get`, `redirect`, `console.error`, the
  `useTranslations(...)` declarations themselves). This is why permissive
  receiver patterns are safe without tree-sitter — Q1 answered: buffer-scope
  pattern heuristic, zero dependencies, documented first-binding-wins.
- **Binding patterns anchor on `const`.** Matching the generic
  `ident =` prefix with a lazy bridge to the keyword cost ~16× more on
  data-heavy files (lazy-class backtracking through long identifier runs);
  `const[ \t]+NAME[ \t]*=[ \t]*[%w_. \t]-useTranslations(` scans a 40 KB mock
  data file in ~0.15 ms vs ~2 ms per pattern. The line-bounded bridge class
  also prevents bindings leaking across semicolon-less statements.
  `let`-bound namespaces need custom patterns (lint conventions make them
  rare).
- **Drift config is three orthogonal knobs (Q3):** `compare`
  ('fallback' | 'none' — gettext/no-fallback stacks disable the code-vs-file
  comparison), `normalize` ('placeholders' — `{n}`/`{{n}}`/`%s` canonicalized
  before comparing), `source_lang` (keys missing in other locales become
  `missing in <lang>` markers and audit gap items pointing at the file).
  Cross-language *value* equality is deliberately not a drift notion —
  translations are expected to differ.
- **Presets live in the plugin (Q4)** as small tables expanded between
  defaults and user options (`defaults ← preset ← setup ← project file` —
  note the preset layer must be rebuilt from the merged user options, never
  stacked onto an already-defaulted table). Recipes in the README complement
  them.
- **Identifier-style accessors are 1-capture patterns + `fallback_style:
  'none'`** (Flutter round). Generated classes (a codegen'd `Tr().snake_key`
  codegen class, gen-l10n `AppLocalizations.of(context)!.key`) carry the
  key in an identifier, not a string literal. The 1-capture contract already
  covers them (the capture is just an identifier), but the next-literal
  fallback heuristic must be off: `Text(Tr().key, '{{count}}')` would
  otherwise grab `'{{count}}'` and fabricate drift. Dart has no dynamic
  member access, so these projects have zero dynamic-key caveats — the
  cleanest extraction class the plugin supports. `.arb` decodes as JSON
  minus `@`/`@@` metadata entries; gen-l10n's `app_<lang>.arb` naming needs
  `file_template` + explicit `languages` (discovery takes the file stem).
- **No coupling to external CLI config (Q5).** next-app's `i18n-check`
  ignore list is copied into `.i18n-inline.json` manually; reading
  package.json script args would couple the plugin to one tool's argv shape.
- **Display toggle is a session-wide 3-mode cycle (Q6):** effective show =
  runtime override (`always → problems → never`) or the configured `show`.
  Scanning and hover keep working under 'never'; only the extmarks disappear.
  Extmark `priority` is user-configurable for stacking (Q6b); the plugin
  anchors inline right after the closing quote and never touches other
  namespaces (coexistence failures are visual only).
- **Jump locates lines by raw-text search at jump time, not via the decode
  cache** (:I18nJump round). The cache stores flat key→value maps — positions
  are destroyed by flattening and `vim.json.decode` never reports them — and
  translation files are small, so re-reading one on demand is sub-millisecond
  and always fresh. Each format owns a `find_line(lines, key, cfg)` next to
  its decoder: JSON/ARB resolve structural paths with an indentation-tracked
  stack (nested beats literal separator characters, matching the decode
  collision policy; inline `{…}` values and minified files fall back to the
  first raw occurrence of the quoted leaf — column included, so the cursor
  still lands on the key), PO anchors the msgid line. Missing in the target
  language falls back to `source_lang` when it has the key — that is where a
  fix starts. `:I18nJump!`/`jump.open='quickfix'` puts every language's
  occurrence in the quickfix, solving "which language?" without a picker;
  `jump.lang='ask'` defers to `vim.ui.select` (which picks up the user's
  picker UI for free).
- **No default keymaps (R6.7).** Every action ships as a `<Plug>` mapping
  plus a command; `keymaps` config (and the deprecated `keymap`) is applied
  buffer-locally when a project resolves — which also fixes the original
  bug where project-file `keymap` was silently ignored (applied only inside
  `setup()` before any project file was read). The `gK` lesson: LazyVim
  claims `gK` buffer-locally at LspAttach time, invisibly to startup keymap
  scans — suggested mappings are `<leader>ii` / `<leader>ui`.

Key decisions (review pass, 2026-10-09). Every item started as a defect
reproduced by a script before fixing; `tests/regressions.lua` pins each
one, and each of those tests fails against the pre-review code. The scan
output over the three reference repositories (7,849 calls) is
byte-identical before and after.

- **Decoders return string-valued maps.** Numbers/booleans are stringified,
  JSON `null` and (flat mode) nested objects are dropped. Before, every
  consumer re-checked `vim.NIL`, and a flat read of nested JSON rendered
  `table: 0x…` inline. Now `keys[key]` is a string or nil everywhere.
- **A relative `dir` resolves against the project file's directory.**
  Walking up from the buffer let a nearer same-named directory
  (`src/components/messages/` vs `messages/`) hijack the project — and since
  projects are cached by root, whichever buffer opened first decided it for
  all. Walk-up remains only for setup-only configs (no project file), and
  then requires a directory, not any file with that name.
- **`languages` filters discovery** (it was ignored without
  `file_template`).
- **Cursor-aware match lookup.** `match_at(buf, row, col)` picks the call
  containing the cursor, else the nearest on the row; it used to return the
  first call on the line, making the second `t()` in `{t('a')} {t('b')}`
  unreachable for hover and jump.
- **On-demand re-scan for actions.** `preview.current_match()` re-scans
  when `changedtick` moved since the last render (edits inside the
  debounce window, insert-mode edits) or the buffer was never scanned —
  which is also what makes the commands work without `setup()`.
- **One popover at a time.** The hover augroup is recreated (`clear =
  true`) per popover, so a second hover deleted the first popover's
  close-on-move autocmds and leaked its window.
- **Popover mismatch = inline status.** The popover compared raw strings
  and ignored `normalize`/non-string values; it now reuses `m.status`.
- **Keymap signature resets with the keymaps.** `clear()` deleted the
  buffer-local maps but kept the signature, so a buffer that left and
  re-entered a project (filetype flip, transiently invalid project file)
  never got them back.
- **Saved-file paths come from the buffer name.** `<afile>` is relative
  when the file was opened relatively (`:e messages/ko.json`), so saving a
  translation file never refreshed other buffers. Saving a new
  translation-format file in a project's `dir` re-discovers languages.
- **Preset fixes.** Flutter's `l10n.key` pattern gained frontiers so
  `import '…/l10n/l10n.dart'` (the Very Good CLI layout) no longer reads as
  key `dart`; gettext uses one pattern per quote style, because msgids are
  source text and `"Don't panic"` stopped at the apostrophe.
- **Schema-driven validation.** Type errors (`position`, numbers, strings)
  used to pass validation and then fail on every render; empty lists were
  rejected for options that legitimately clear a preset
  (`namespace_patterns: []`). Unknown keys are reported, not fatal, so an
  older plugin still reads a newer project file.
- **Health samples evenly.** The first 25 files of a depth-first walk all
  came from the first directories — on cljs-app that was 0 calls of
  4,518, a false "patterns matched nothing" warning. The sample is now
  spread over the sorted file list (walk capped at 5,000 files).
- **Plugin-owned highlight groups** (`I18nInline*`, default links,
  re-applied on `ColorScheme`) so colorschemes can target them by name.
- **The jump flash is a buffer extmark.** It was a `matchaddpos` match,
  which belongs to the window: `<C-o>` within the 800 ms flash painted it
  over the code buffer at the translation file's line and column. Found
  while recording the README GIFs.
- **Health parses every language file**, not only preview and source, and
  parse failures carry the decoder's message: decoders return
  `(nil, msg)`, which the `pcall` wrapper used to drop (`"…: empty
  table"`). Both came out of trial runs of the README's agent setup prompt
  against the three reference repos. In a headless run (no UI attached)
  the audit's report lines go to `:messages` and list every unused key, so
  CI or an agent can capture them; with a UI they stay out of the history,
  which would turn consecutive lines into a hit-enter prompt.

Key decisions (catalogs round, 2026-10-09). An agent ran the README's
setup prompt on a fourth private repository, `email-app` (react-intl
email templates): 8 translation directories
(7 per-template `messages/<lang>.json` plus a shared
`footer-<lang>.json`), 13 languages each, and a shared component that
receives one of two templates' catalogs as props. It reported seven
problems; each was reproduced headless against a copy of that repository
before designing:

1. One project file bound one directory, so it took eight.
2. The shared component's 9 calls bound to the footer project by
   proximity and all read `✗` although the keys exist (in the two
   templates' catalogs).
3. A root project file audited the whole tree, so every other project's
   calls read missing: 69 false items without a 26-entry `exclude_dirs`
   of sibling names (name-based, so `components` couldn't be targeted).
4. `:checkhealth` sampled 25 of 231 files where 7 hold calls, and warned
   "patterns matched no call sites" or "none resolve", depending on
   which files the sample hit, pointing at addressing when the patterns
   were fine.
5. With lazy.nvim's `ft` (or `keys`) the plugin isn't on the
   runtimepath, so `:checkhealth i18n-inline` finds nothing.
6. `check.ignore` didn't apply to missing keys.
7. Nothing told a structural false missing from a real one.

The model behind 1–3 and 7 was "project file = one directory = one audit
scope, buffer → nearest project file". The decisions:

- **A project holds catalogs (#1).** `catalogs` lists directories, each
  a string or a table overriding the read options (`languages`,
  `file_template`, `format`, `key_style`); `dir` is the one-entry
  spelling, and the layer that sets either decides (a project file's
  `dir` beats `setup()`'s `catalogs` and vice versa). `*` matches one
  directory level; `**` is not supported for catalogs (no use case
  needed it, and it means a recursive walk at project load). A directory
  an entry names exactly is never claimed by another entry's `*`
  (`src/emails/*/messages` also matches `shared/messages`, whose
  `footer-%s.json` naming only the exact entry describes); between two
  wildcards the first wins. Wildcard matches without translation files
  are dropped and listed by health.
- **`file_template` discovers languages** when `languages` is absent: the
  template segment holding `%s` becomes a pattern over its parent's
  entries (`footer-%s.json`, `%s/LC_MESSAGES/messages.po`). The old
  "file_template requires languages" rule only existed because discovery
  couldn't read templates.
- **Which catalogs a file reads (#2).** In order: `uses` (file glob →
  catalog globs; a directory glob covers its subtree), else the deepest
  catalog home holding the file, else every catalog in declaration order.
  A home is the catalog dir's parent, climbed while the level above holds
  no other catalog (with several catalogs the climb stops below the
  root, which holds them all; a catalog directly under the root has the
  root as home, and a deeper home wins over it). Two
  simpler rules failed real layouts: "parent of the dir" gives
  `apps/admin/public` for `apps/admin/public/locales` (the code is in
  `apps/admin/src`), and "highest folder holding no other catalog" can't
  nest (`x/messages` plus `x/sub/messages` left `x/index.ts` homeless).
  The climb handles both. A lone catalog serves every file, so
  single-directory projects behave exactly as before. The scan output of
  the three reference repositories (7,611 calls) is byte-identical.
- **Runtime-chosen catalogs are declared, not inferred.** The shared
  component's catalog is a prop, and following imports and JSX props is
  out of reach for patterns. `uses` says it in one line. Union-by-default (i18n-ally's approach) was rejected:
  per-template catalogs reuse generic keys (`heading`, `cta`,
  `preview`), so a template reading another's key would silently
  resolve, a real bug hidden.
- **"Only in <catalog>" (#7).** A key the file's catalogs lack is looked
  up in the project's other catalogs. Found there, it stays `missing`
  (users of that file would see the raw id) but says where it is:
  inline `✗ only in order/messages +2`, in the audit item with the
  catalogs the file reads, counted apart in the summary, and as a health
  warning naming the files and `uses`. Lookups never cross projects;
  health says so when nested projects exist.
- **Audit scope (#3).** The walk skips subtrees holding their own project
  file (listed in the summary and health), so a root file next to
  per-directory files needs no excludes. `exclude_dirs` entries with a
  `/` are root-relative path globs; bare names keep matching at any
  depth, as in .gitignore. Lists still replace wholesale (R6.4).
- **`check.ignore` covers absence (#6):** missing keys, missing
  translations and unused keys. Not mismatches: those compare two values
  that exist, and are never structural. The README prompt keeps agents
  from using it to hide findings: runtime-added keys are listed for the
  user.
- **Health scans everything (#4)** up to 5,000 files and two seconds, in
  a strided order so a cut still covers the tree: 50–160 ms on the
  reference repositories (the sample took 3–34 ms; a one-off diagnostic
  can afford it). Unresolved keys come with examples (`key (file:line)`),
  and "none resolve" only fires when nothing resolves anywhere.
- **Don't lazy-load (#5).** Nothing in the plugin can make a health check
  visible before the plugin is on the runtimepath, so the README says not
  to lazy-load (and why `keys` implies it), and the agent prompt says the
  same. `setup()` now loads the rendering modules on the first event that
  needs them: 0.15 ms for plugin/ plus ~0.45 ms for `setup()`, down from
  ~0.8 ms. Health warns when `setup()` never ran (commands work, previews
  don't).
- **Lookups go through a view** (`resolve.view(project, path, memo)`):
  the file's catalogs, the others, and a memo of key tables shared across
  one pass, so an audit loads each catalog's tables once, not once per
  file. Audit time is unchanged (cljs-app, 1,223 files: 124 → 129 ms,
  within noise).

Second review pass (2026-10-09), started from inline values piling up
(`제품명  제품명  제품명`) and drifting into the middle of keywords. Same
rules: each defect reproduced first and pinned in `tests/regressions.lua`
(each test fails against the previous code); the scan output over
boxhero-web (4,497 calls) is identical before and after, and the scan
time unchanged (115 vs 116 ms).

- **Marks go with the state that tracks them.** `:edit`/`:edit!` fire
  BufUnload, which dropped the buffer's state, but the extmarks survive the
  re-read: every reload added a full set beside untracked ones that then
  drifted with edits. `unload()` clears them, and a render without ids to
  reuse starts from an empty namespace.
- **Marks stay on the line.** A pattern ending on the newline (a trailing
  `%s`) put the mark one column past the line end and raised from the
  debounce timer on every edit; the column is clamped.
- **Turning `underline_mismatch` off removes drawn underlines** (they were
  left untracked).
- **Scanning cannot hang or raise on user patterns.** A pattern that
  matches the empty string looped forever (Neovim had to be killed); an
  empty match now moves on one byte. A malformed pattern raised from every
  refresh and stopped `:I18nCheck` midway; it is reported once and matches
  nothing. Lua only notices a malformed pattern when the matcher reaches
  the bad part, so config validation cannot catch it.
- **Fallbacks:** `\uXXXX` (surrogate pairs too), `\u{…}`, `\xHH`, `\r`, `\b`,
  `\f`, `\v`, `\0` decode, so `"caf\u00e9"` matches `café`; a literal must be
  the whole argument (`t('k', 'a' + b)` and Clojure's `'sym` are not
  defaults). The default Clojure patterns take the whole keyword
  (`:valid?`, `:a->b`).
- **`.po`:** a `#, fuzzy` flag survives the `#|` lines msgmerge writes after
  it; `msgstr[n > 0]` continuations no longer append to `msgstr[0]`; "fuzzy"
  in a translator comment is just a word.
- **Nested JSON jump lands on the right key.** `json_leaf_positions` read
  its captures in the wrong order, so the structural index was always
  empty and every jump went to the first `"leaf"` anywhere in the file; an
  inline `{ … }` value no longer opens a level for the lines after it.
- **Fresh projects.** A project file edited outside Neovim (git checkout,
  another editor) is re-read: the decoded table's identity tells a stale
  project, at one stat per refresh. `setup()` called again drops projects
  built from the old options. A language file added outside Neovim is found
  once its directory's signature changes. Symlinked translation and source
  files count as files.

### README media

The README images are recorded, not drawn: `media/render.mjs` runs
`nvim --embed` with a small config (tokyonight, lualine, tree-sitter),
attaches as a linegrid UI over msgpack-RPC, and paints the composed grid
(floats included, `ext_multigrid` off) on a canvas in headless Chromium.
Box-drawing characters are painted on the cell grid rather than taken from
the font, as GPU terminals do; font glyphs leave gaps and offsets at a
22 px line height. Frames carry scripted durations, so the GIF timing does
not depend on machine speed; `wait()` lets real timers (the jump flash)
expire before the next frame. Fixtures are copied under a temporary `$HOME`
so every printed path reads `~/orbit/...`.

## Neovim API findings (0.12.5)

Beware when touching these areas:

- `:edit` / `:edit!` on a loaded buffer fire BufUnload (and BufReadPost),
  yet the buffer's extmarks survive the re-read. State dropped on BufUnload
  must take its marks with it.
- `vim.fs.dirname('/')` returns `'/'` (and `dirname('')` returns `'.'`),
  so walk-up loops need an explicit `parent == cur` termination or they spin
  forever. `resolve.find_upward` carries this guard.
- `vim.api.nvim_getqflist` / `nvim_setqflist` are not available;
  `vim.fn.getqflist()` / `vim.fn.setqflist()` are. `check.lua` uses `vim.fn`.
- Quickfix items with a `filename` but no `lnum` may come back as `bufnr`
  with `filename = nil` (the file gets loaded into a buffer); gap items set
  `lnum = 1` partly for this reason, and the test reads either field.
- `vim.lsp.util.open_floating_preview` returns a window and buffer that are
  already closed/wiped by the time it returns (at least in 0.12), which makes
  post-open highlighting impossible. `hover.lua` builds its own
  `nvim_open_win` float instead — plain floats work fine, including headless.
- `nvim_open_win` with `relative = 'cursor'` reports back as
  `relative = 'win'` in the window config; don't identify such windows by
  the `relative` field.
- `nvim_buf_set_extmark` takes the reused id via `opts.id`, not as a
  positional argument.
- `vim.fn.escape` escapes with *backslashes* (Vim-regex style); Lua patterns
  need `%`-escaping — `check.glob_to_pattern` does its own `gsub('[...]', '%%%0')`.
- `nvim_strwidth` counts East-Asian wide characters (Hangul, CJK) as 2;
  `max_len` options are *runes*, not display cells — the hover test compares
  against `util.truncate` output for this reason.
- In `nvim -l` script mode several APIs are missing (quickfix among them);
  the test suite must run under `--headless -u NORC`.
- Buffer 0 (current-buffer pseudo-id) and real buffer numbers must not be
  mixed as state keys; `preview.lua` normalizes at every entry point.
- `:tab {file}` is not "open in a tab": `:tab` takes a *command*, so
  `:tab /path/x.json` runs `:/path…` as a search (E486). Use `:tabedit`.
- In autocmds, `ev.file` (`<afile>`) is the name as the user typed it —
  relative when opened relatively. Use `nvim_buf_get_name(ev.buf)` for an
  absolute path.
- A Lua `complete` function for a user command behaves like `customlist`:
  Neovim does not filter by the typed prefix — the function must.
- `vim.fn.expand()` on a file path interprets `%`, `#` and `<cfile>`;
  normalize paths with `vim.fs.normalize` + `fnamemodify(':p')` instead.
- `vim.tbl_deep_extend('force')`: an empty table over a list replaces it
  (so `"aliases": []` clears a preset's list), while an empty table over a
  dict merges (a no-op). `vim.json.decode` keeps the distinction: `{}` is a
  `vim.empty_dict()` (not `islist`), `[]` an empty list.
- `nvim_open_win` rejects `title` when the border is `'none'`; omit the
  title in that case (relevant once `'winborder'` is honored).
- `matchaddpos()` highlights belong to the *window*: they stay when the
  window switches to another buffer. Use buffer extmarks for anything tied
  to a buffer position.
- With `nvim --embed`, a float that does not fit below the cursor is moved
  up and may cover the cursor row; the UI then reported mode `replace` for
  the cursor shape in one case. Give floats room in recordings.

## Performance measurements

All measured on the source repository (1,057 files, 23 MB of ClojureScript)
unless noted:

| Operation | Time |
| --- | --- |
| Directory walk (fs_scandir, recursive) | ~5 ms |
| Read all files | ~19 ms |
| `vim.json.decode` + flatten of one next-intl message file (244 keys) | ~0.2 ms (cached afterwards) |
| Full-repository scan (patterns + literal parsing + classification) | ~130 ms |
| next-app full scan (295 files, receiver patterns + binding pre-pass + nested flatten) | ~70 ms (~0.26 ms/file avg; slowest 40 KB data file ~3 ms) |
| dart-app full scan (852 Dart files, `Tr().key` accessor pattern, flat JSON; 2,964 calls, 100% resolve, 0 false missing) | ~60 ms (~0.07 ms/file) |
| Binding pre-pass, const-anchored (worst 40 KB file) | ~0.15 ms/pattern (vs ~2 ms before anchoring) |
| Single typical buffer scan + extmark render | ~1 ms |

`:I18nCheck` processes files in batches of 40 per event-loop tick, so the UI
stays responsive during an audit. The audit adds a synchronous cross-language
pass at the end (ensure_lang per locale, all cached after the first run).

## Test suite

`tests/run.lua` — hermetic unit tests for util/scan/config/resolve plus
end-to-end tests that create temp projects and drive real buffers, extmarks,
the hover popover, and the quickfix audit. `tests/generalization.lua` (loaded
by run.lua) covers the generalization surface: nested flattening and the
collision policy, PO parsing, namespace composition (both presets), alias
filtering, backtick/bounded fallbacks, prop fallbacks, placeholder
normalization, preset expansion and array-replacement merge semantics,
project-file keymaps, the display-mode cycle, source-language gaps, ignore
globs, Flutter identifier accessors (arb decoding, fallback none), and jump
line-location (flat/nested/literal-dot/minified JSON, PO, E2E jump with
missing→source fallback, quickfix variant, ask mode).
`tests/regressions.lua` (also loaded by run.lua) holds one test per defect
fixed in the review pass, including the autocmd wiring (relative-name
saves, new language files) and the plugin file (commands without
`setup()`, completion filtering).
`tests/catalogs.lua` covers the catalogs round: path globs, the walk's
path excludes and nested-project skip, catalog validation and the
dir/catalogs layer rule, wildcard expansion and template discovery,
homes/`uses`/fallback, "only in" lookups through inline, popover, jump
and the audit, ignore semantics, the full-tree health scan, and
catalogs appearing on save.
Set `I18N_SMOKE_REPO` to also scan a real ClojureScript repository and
assert sane totals.
