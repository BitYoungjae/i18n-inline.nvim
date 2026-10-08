# Design notes

Background, measurements and decisions that shaped the implementation.
Written for future maintenance; the README covers usage.

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

## Architecture

```
config.lua    defaults + setup() + project-file merge/validate
resolve.lua   project discovery (walk-up), per-project cfg, JSON cache (mtime+size)
scan.lua      pattern scan + string-literal fallback parser + status classification
preview.lua   per-buffer state, debounced refresh, extmark rendering
hover.lua     per-language popover (own float, close-on-move autocmds)
check.lua     project-wide audit -> quickfix, batched via vim.schedule
health.lua    :checkhealth
```

Key decisions:

- **Zero runtime dependencies.** Everything builds on `vim.api`, `vim.uv`,
  `vim.json`. No plenary, no tree-sitter requirement.
- **Pattern contract: capture #1 = key, then parse the next string literal
  manually.** Lua patterns cannot do alternation or escaped-quote-safe string
  matching; a hand-written literal parser (handling `\\`, `\"`, `\'`, `\n`,
  `\t`, rejecting unterminated literals) is more robust than trying to
  encode the fallback into the pattern. It also makes the same contract work
  for other languages (`t('key', 'fallback')`).
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

## Neovim API findings (0.12.5)

Beware when touching these areas:

- `vim.fs.dirname('/')` returns `'/'` (and `dirname('')` returns `'.'`),
  so walk-up loops need an explicit `parent == cur` termination or they spin
  forever. `resolve.find_upward` carries this guard.
- `vim.api.nvim_getqflist` / `nvim_setqflist` are not available;
  `vim.fn.getqflist()` / `vim.fn.setqflist()` are. `check.lua` uses `vim.fn`.
- `vim.lsp.util.open_floating_preview` returns a window and buffer that are
  already closed/wiped by the time it returns (at least in 0.12), which makes
  post-open highlighting impossible. `hover.lua` builds its own
  `nvim_open_win` float instead — plain floats work fine, including headless.
- `nvim_open_win` with `relative = 'cursor'` reports back as
  `relative = 'win'` in the window config; don't identify such windows by
  the `relative` field.
- `nvim_buf_set_extmark` takes the reused id via `opts.id`, not as a
  positional argument.
- In `nvim -l` script mode several APIs are missing (quickfix among them);
  the test suite must run under `--headless -u NORC`.
- Buffer 0 (current-buffer pseudo-id) and real buffer numbers must not be
  mixed as state keys; `preview.lua` normalizes at every entry point.

## Performance measurements

All measured on the source repository (1,057 files, 23 MB of ClojureScript):

| Operation | Time |
| --- | --- |
| Directory walk (fs_scandir, recursive) | ~5 ms |
| Read all files | ~19 ms |
| `vim.json.decode` of one ~170 KB translation file | ~0.6 ms (cached afterwards) |
| Full-repository scan (patterns + literal parsing + classification) | ~220 ms |
| Single typical buffer scan + extmark render | ~1 ms |

`:I18nCheck` processes files in batches of 40 per event-loop tick, so the UI
stays responsive during an audit.

## Test suite

`tests/run.lua` — hermetic unit tests for util/scan/config/resolve plus
end-to-end tests that create temp projects and drive real buffers, extmarks,
the hover popover, and the quickfix audit. Set `I18N_SMOKE_REPO` to also scan
a real repository and assert sane totals.
