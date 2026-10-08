# i18n-inline.nvim

Show the actual translation value next to every i18n call, while you edit.

![screenshot](assets/screenshot.svg)

*Top: the raw buffer. Bottom: the same buffer with the plugin active — the
gray text after each string (not present in the file) is the value from the
translation file. Gray means it matches the fallback, `≠` marks drift, `✗`
marks a missing key, and the popover shows the hover mapping.*

When code contains `(tr [:billing-usage-title "Usage"])`, the string literal is
only a fallback — the text users see comes from a translation file. The two
drift apart silently: a wording fix in the JSON never reaches the code, and a
code edit never reaches the JSON. This plugin surfaces the real value inline
so the drift is visible at a glance, in every affected file.

Works across stacks: flat-key JSON with inline fallbacks (ClojureScript
`(tr [:k "fb"])`), nested JSON with namespace composition (next-intl
`useTranslations('ns')` + `t('key')`), gettext `.po` catalogs, and anything a
custom Lua pattern can describe.

## What it does

- **Inline value preview** — virtual text right after each call (or fallback
  string) shows the value from the preview language's translation file.
- **Drift markers** — when the fallback differs from the file (`≠`, warning
  color, plus an underline on the string) or the key is absent (`✗`, error
  color; `missing in <lang>` when only the preview language lacks it).
- **Language popover** — `<Plug>(i18n-inline-hover)` / `:I18nHover` shows
  every language's value for the key under the cursor, plus the code fallback,
  with mismatching languages highlighted.
- **Display toggle** — `<Plug>(i18n-inline-toggle)` / `:I18nToggle` cycles
  inline display (`always → problems → never`) for the session; hover and the
  audit keep working in every mode.
- **Project audit** — `:I18nCheck` scans the whole project into the quickfix
  list: fallback mismatches, missing keys, translations missing relative to
  the source language, and a summary of unused keys (with ignore globs for
  known-dynamic key groups).
- **Per-project configuration** — a `.i18n-inline.json` at the repository
  root, discovered automatically by walking up from each buffer, with
  framework presets (`next-intl`, `i18next`, `vue-i18n`, `gettext`).

## Requirements

- Neovim 0.10 or later.
- No plugin dependencies. Translation files: JSON (flat or nested) and
  gettext `.po`.

## Installation

With lazy.nvim:

```lua
{
  'i18n-inline.nvim',
  dir = '~/Work/i18n-inline.nvim', -- or a proper git URL
  opts = {},
}
```

The plugin does nothing in buffers that don't resolve to a project (see
below), so loading it for all filetypes is also fine.

### Keymaps

No keymaps are set by default, so nothing can collide with user or distro
mappings. Every action is reachable without any mapping:

- `:I18nHover` / `<Plug>(i18n-inline-hover)`
- `:I18nToggle` / `<Plug>(i18n-inline-toggle)`
- `:I18nCheck`

To opt into keymaps, either set them yourself:

```lua
vim.keymap.set('n', '<leader>ii', '<Plug>(i18n-inline-hover)', { desc = 'i18n translations' })
vim.keymap.set('n', '<leader>ui', '<Plug>(i18n-inline-toggle)', { desc = 'i18n toggle inline' })
```

or configure `keymaps` (applies to the buffers of each project, from
`setup()` and the project file alike):

```lua
opts = { keymaps = { hover = '<leader>ii', toggle = '<leader>ui' } }
```

> Avoid `gK`-style mappings that LazyVim (and some LSP setups) claim at
> **LspAttach time** — they shadow global plugin mappings buffer-locally and
> startup keymap scans won't catch it. `<leader>ii` / `<leader>ui` are
> verified free on the reference LazyVim setup. For discoverability:
>
> ```lua
> local wk = require('which-key')
> wk.add({ { '<leader>i', group = 'i18n' } })
> ```

## Configuration

Options come from two places, merged in this order (later wins per key):

1. built-in defaults, overridden by `setup(opts)` — user-level;
2. the project file `.i18n-inline.json` (name configurable) found at the
   nearest ancestor directory of the buffer.

A `preset` key at either level expands its framework defaults between the
built-ins and your overrides: **defaults ← preset ← setup() ← project file**.

**Merge semantics:** list-valued options (`patterns`, `filetypes`,
`aliases`, …) are replaced wholesale by the later layer — a project file's
`patterns` replaces the defaults entirely. Dict-valued options (`hl`,
`check`, `hover`, `keymaps`) merge key by key. This is intentional: arrays
are alternative sets, not accumulations.

### Framework presets

```json
{ "preset": "next-intl", "dir": "messages", "preview_lang": "ko", "source_lang": "en" }
```

| Preset | Shapes covered |
| --- | --- |
| `next-intl` | `const t = useTranslations('ns')` / `await getTranslations('ns')`, nested dot keys, no code fallback |
| `i18next` | `const { t } = useTranslation('ns')`, `t('ns.key')`, `i18n.t`, `t.raw`, nested dot keys |
| `vue-i18n` | `$t('key')`, `this.$t('key')` in templates and script, nested dot keys |
| `gettext` | `_('text')`, `t('text')`, `__('key')` where the msgid is the key; `.po` files; comparison off |

Presets set `filetypes`, `patterns`, `namespace_patterns`, `aliases`,
`key_style`, and `check` defaults; every key remains overridable.

### All options (same keys in `setup()` and the project file)

| Option | Default | Meaning |
| --- | --- | --- |
| `preset` | `nil` | framework preset name (see above) |
| `project_file` | `'.i18n-inline.json'` | per-project config file name |
| `dir` | `nil` | translation directory; absolute, or relative to the project root (discovered upward from the buffer) |
| `languages` | `nil` | language list; nil discovers translation files in `dir` (`ko.json`/`ko.po` → `"ko"`) |
| `file_template` | `nil` | language → file template, e.g. `'locales/%s.json'`; requires `languages` |
| `format` | `nil` | `'json'` \| `'po'`; nil auto-detects by extension |
| `key_style` | `'flat'` | `'nested'` flattens hierarchical files into separator-joined paths (`Invoice.amount` ← `{"Invoice": {"amount": …}}`) |
| `separator` | `'.'` | path separator for flattening and namespace composition (e.g. `':'` for `ns:key` schemes) |
| `preview_lang` | `'ko'` | language shown inline |
| `source_lang` | `nil` | locale owning the key set; enables translation-gap markers and the cross-language audit |
| `filetypes` | `{'clojure'}` | filetypes to scan |
| `patterns` | see below | extraction patterns (capture contract below) |
| `namespace_patterns` | `{}` | namespace binding patterns (see below) |
| `aliases` | `nil` | allowed call receivers for receiver-capturing patterns; `'*'` allows any |
| `fallback_style` | `'literal'` | `'literal'` = next string literal; `'prop'` = `fallback_props` property (`defineMessages` …) |
| `fallback_props` | `{'defaultMessage'}` | property names for `fallback_style: 'prop'` |
| `compare` | `'fallback'` | `'none'` disables the fallback-vs-file comparison (gettext / no-fallback stacks) |
| `normalize` | `'none'` | `'placeholders'` treats `{n}`, `{{n}}`, `%s` … as equal placeholders when comparing |
| `prefix` | `'  '` | inline preview prefix |
| `missing_text` | `'key not found'` | text shown for keys missing everywhere |
| `max_len` | `60` | max preview length in runes |
| `position` | `'inline'` | `'inline'` after the string, or `'eol'` |
| `show` | `'always'` | `'always'` \| `'problems'` (drift only) \| `'never'` (popover/audit only) |
| `hl` | see config.lua | highlight groups: match / mismatch / missing / underline |
| `underline_mismatch` | `true` | underline mismatched fallback strings |
| `keymaps` | `{}` | `{ hover = …, toggle = … }`; applied per project buffer |
| `keymap` | `nil` | deprecated alias for `keymaps.hover` |
| `extmark_priority` | `nil` | extmark priority for the inline text — raise it to draw over other plugins' virtual text |
| `hover` | see config.lua | popover bounds: `{ max_len, width, max_height }` |
| `debounce_ms` | `150` | edit → refresh debounce |
| `max_filesize` | `1000000` | skip larger buffers (bytes) |
| `check.extensions` | `{'cljs','cljc','clj'}` | file extensions `:I18nCheck` walks |
| `check.exclude_dirs` | `{'.git','node_modules',…}` | directories the audit skips |
| `check.ignore` | `{}` | globs for keys excluded from unused detection (`"templateVar.*"`) |

### The pattern contract

A pattern's capture count selects its shape:

- **1 capture** — the capture is the translation key: the original contract,
  e.g. `%(tr%s*%[%s*:([%w%.%-_/]+)` for `(tr [:key "fallback"])`.
- **2 captures** — #1 is the call *receiver*, #2 the key argument, e.g.
  `([%w_.$]+)%s*%(%s*['\"]([^'\"\n]+)['\"]` matches `t('key')`, `i18n.t('k')`,
  `$t('k')`. A match is kept only when the receiver is a **namespace
  binding** (the key becomes `namespace .. separator .. subkey`) or an
  **alias**. This filter is what makes a permissive receiver pattern safe:
  `require('x')`, `console.error('…')`, `redirect('/x')` are dropped.

After the match ends, the fallback is parsed automatically (bounded by the
next match, so one call can never swallow the next call's key): whitespace
and one optional comma, then a `"…"`, `'…'` or backtick literal — backticks
containing `${…}` are dynamic and skipped. Multiline calls work, which
matters for one-argument-per-line formatting styles.

### Namespace bindings (next-intl / i18next shape)

`const t = useTranslations('error')` followed by `t('retry')` resolves to
`error.retry` when a binding pattern captures it:

- **2 captures** — (variable, namespace): binds `t` → `'error'`
- **1 capture** — (variable): binds to the root namespace (key as-is)

```json
{
  "namespace_patterns": [
    "const[ \t]+([%w_]+)[ \t]*=[ \t]*[%w_. \t]-useTranslations%(%s*'([^']*)'%s*%)"
  ],
  "aliases": ["t"]
}
```

Bindings are file-scope and first-binding-wins. Non-literal namespaces
(`getTranslations(SOME_CONST)`) do not bind — calls through those receivers
are dropped rather than mis-resolved; cover such key groups with
`check.ignore` (resolve the constant's values, e.g. `"templateVar.*"`).

Note the JSON escaping: a Lua pattern `\(` is written `\\(` in JSON, and a
tab inside a class is `\t`.

### Key addressing

- `key_style: 'flat'` reads the file as key → value (flat JSON, `.po`).
- `key_style: 'nested'` flattens hierarchical JSON at load time, joining
  paths with `separator`. When a literal leaf key (`"a.b"`) and a nested
  path (`{"a": {"b": …}}`) produce the same flat key, the nested path wins.

### Audit semantics

`:I18nCheck` fills the quickfix list with:

- **mismatch** — code fallback vs preview language value (unless
  `compare: 'none'`; placeholder-only differences vanish with
  `normalize: 'placeholders'`);
- **missing** — a call's key is in no translation file;
- **gap** — a key present in `source_lang` but missing from another
  language's file (item points at that file).

and echoes **unused** keys: keys in the source language (preview language
when no `source_lang`) that no scanned call references — namespace-composed
references count as used, and `check.ignore` globs exclude known-dynamic
groups.

## Usage

- Open a file — previews render automatically. They refresh (debounced) as
  you edit, immediately after you save, and when a translation file is saved.
- The hover mapping inside a call (or on its key) opens the language
  popover; it closes when the cursor moves.
- `:I18nToggle` cycles inline display for the session.
- `:I18nCheck` audits the project into the quickfix list.
- `:checkhealth i18n-inline` verifies the setup: project found, files parse,
  patterns match real call sites, sample resolution rate — and warns about a
  nested-JSON file read with `key_style: 'flat'`.

### Virtual-text coexistence

Extmarks are namespace-isolated, so other plugins drawing virtual text
(diagnostics, inlay hints) never error or cross-overwrite — the failure mode
is visual stacking. The inline text anchors right after the closing quote to
minimize overlap; if it fights a neighbor, set `extmark_priority` (higher
draws on top) or toggle inline display off with `:I18nToggle`.

## Performance notes

- One Lua-pattern pass per buffer on change; measured on real repositories:
  cljs-app (ClojureScript, 1,067 files, 4,518 calls) audits in ~130 ms;
  next-app (next-intl, 257 files incl. a namespace-binding pre-pass)
  in ~70 ms; typical single buffers scan in well under a millisecond, the
  slowest 40 KB data file in ~3 ms.
- Translation files are decoded once and cached, keyed by mtime and size;
  nested JSON is flattened at decode time, so every lookup stays a flat
  table index.
- Extmarks are reused between refreshes; nothing flickers on re-render.
- Audits process files in batches so the editor stays responsive.

## Limitations

- Static analysis: keys computed at runtime (`t(prefix + '.title')`,
  `t(`${i18nKey}.documentation`)`, data-indirected keys like
  `labelI18nKey: 'itemImage'`) are not resolved — they never produce inline
  false positives, and `check.ignore` keeps them out of the unused report.
- Namespace binding analysis is a same-buffer pattern heuristic: it sees
  `const` bindings with literal namespaces, file-wide, first binding wins.
  `let`-bound or cross-file constants need custom `namespace_patterns` or
  ignore entries.
- Structured extraction (tree-sitter) is not implemented; the next-literal
  fallback heuristic handles `defineMessages` via `fallback_style: 'prop'`.
- Formats beyond JSON and `.po` (YAML, `.arb`, `.properties`) are not
  shipped; `formats.lua` documents the one-function decoder interface to add
  one. PO entries with `msgctxt` are skipped (ambiguous to address from
  code).
- Comparison is plain string equality after unescaping (plus optional
  placeholder normalization).

## Development

Run the test suite (hermetic, plus a real-repository smoke test when
`I18N_SMOKE_REPO` is set):

```sh
nvim --headless -u NORC +'luafile tests/run.lua'
I18N_SMOKE_REPO=/path/to/repo nvim --headless -u NORC +'luafile tests/run.lua'
```

See `docs/DESIGN.md` for architecture notes and measurements.

## License

MIT
