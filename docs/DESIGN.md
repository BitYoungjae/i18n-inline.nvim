# Design notes

Background, measurements and decisions that shaped the implementation.
Written for future maintenance; the README covers usage. The generalization
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
config.lua    defaults + setup() + preset expansion + project-file merge/validate
presets.lua   framework preset tables (next-intl, i18next, vue-i18n, gettext)
formats.lua   format registry: decode(raw, cfg) -> FLAT key->value map (json, po)
resolve.lua   project discovery (walk-up), per-project cfg, mtime+size file cache
scan.lua      pattern scan (arity-dispatched), namespace bindings, fallback
              extraction, placeholder normalization, status classification
preview.lua   per-buffer state, debounced refresh, extmark rendering, display
              toggle, match lookup (shared by hover/jump), per-buffer keymaps
hover.lua     per-language popover (own float, close-on-move autocmds, bounds)
jump.lua      :I18nJump — open the translation file at the key under the
              cursor (per-format line location via formats.find_line)
check.lua     project-wide audit -> quickfix, batched; source-lang gaps,
              ignore globs, namespace-aware unused detection
health.lua    :checkhealth — project, formats, sample resolution rate
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

## Neovim API findings (0.12.5)

Beware when touching these areas:

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
Set `I18N_SMOKE_REPO` to also scan a real ClojureScript repository and
assert sane totals.
