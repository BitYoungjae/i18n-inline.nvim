# Configuration reference

The [README](../README.md) gets you running. This page has the details:
every option, how patterns work, and what the audit reports.

- [Where options come from](#where-options-come-from)
- [Presets](#presets)
- [Examples by stack](#examples-by-stack)
- [Several translation directories](#several-translation-directories)
- [All options](#all-options)
- [Highlights](#highlights)
- [Writing patterns](#writing-patterns)
- [Namespace bindings](#namespace-bindings)
- [Key addressing](#key-addressing)
- [What the audit reports](#what-the-audit-reports)
- [Jumping](#jumping)
- [Other plugins' virtual text](#other-plugins-virtual-text)
- [Performance](#performance)

## Where options come from

There are two layers, and the later one wins key by key:

1. `setup(opts)`, on top of the built-in defaults. Use it for personal
   things like keymaps and display.
2. `.i18n-inline.json`, found by walking up from the buffer's file (or from
   the current directory when the buffer has no file). Use it for things
   about the project: where the files are, which preset, which language to
   preview. The nearest file wins, so a subproject can have its own.

A `preset` (in either layer) slots in underneath your own values, so the
full order is **defaults ← preset ← `setup()` ← project file**.

Lists replace, tables merge. A `patterns` list in the project file replaces
the default list entirely; `hl`, `check`, `hover`, `jump` and `keymaps`
merge key by key.

Two built-in defaults come from the plugin's first user and rarely fit
anyone else: `preview_lang` is `'ko'` and `filetypes` is `{'clojure'}`.
Presets set `filetypes`; set `preview_lang` yourself.

Both layers are validated. A wrong type or value (`"max_len": "60"`,
`"position": "right"`) disables the project with one message naming the
key. Unknown keys, usually typos like `preview_language`, are reported and
ignored. `:checkhealth i18n-inline` lists both. Keys starting with `$` or
`//` are left alone, so `"$schema"` and `"//": "comment"` are fine.

## Presets

| Preset | What it covers |
| --- | --- |
| `next-intl` | `const t = useTranslations('ns')`, `await getTranslations('ns')`, nested keys, no inline default |
| `i18next` | `const { t } = useTranslation('ns')`, `t('ns.key')`, `i18n.t`, `t.raw`, nested keys; `t('key', 'Default')` defaults are compared |
| `vue-i18n` | `$t('key')`, `this.$t('key')`, `t('key')` in templates and scripts, nested keys |
| `flutter` | gen-l10n only: `AppLocalizations.of(context)!.key`, `context.l10n.key`, `l10n.key`; `.arb` files. Other Dart setups need a pattern ([example](#examples-by-stack)) |
| `gettext` | `_("text")`, `gettext("text")`, `__()`, `ngettext()`; the msgid is the key; `.po` files; no comparison |

A preset sets `filetypes`, `patterns`, `namespace_patterns`, `aliases`,
`key_style` and the audit's `check` defaults. You can override any of them.

**Which language to preview.** If your calls carry default strings, preview
the language those defaults are written in. That's the only comparison
that means anything; with any other language every call shows `≠`. If your
calls have no defaults, preview the language you read best.

## Examples by stack

next-intl, English as the source, previewing Korean:

```json
{ "preset": "next-intl", "dir": "messages", "source_lang": "en", "preview_lang": "ko" }
```

i18next with defaults in the code (`t('key', 'Default')`):

```json
{ "preset": "i18next", "dir": "public/locales", "source_lang": "en", "preview_lang": "en" }
```

Flutter gen-l10n. The files are named `app_<lang>.arb`, so list the
languages and give the file name template:

```json
{
  "preset": "flutter",
  "dir": "lib/l10n",
  "languages": ["en", "ko"],
  "file_template": "app_%s.arb",
  "preview_lang": "ko"
}
```

gettext with the usual `<lang>/LC_MESSAGES/messages.po` layout:

```json
{
  "preset": "gettext",
  "dir": "translations",
  "languages": ["ko", "ja"],
  "file_template": "%s/LC_MESSAGES/messages.po",
  "preview_lang": "ko"
}
```

No preset: ClojureScript with `(tr [:key "fallback"])` calls and flat JSON.
These are the built-in defaults, so only the location is needed:

```json
{ "dir": "src/i18n", "preview_lang": "ko", "source_lang": "ko" }
```

A generated Dart accessor class (`Tr().some_key`) over flat JSON. One
capture means "this is the key", and `fallback_style: "none"` stops the
plugin from reading the next string literal as a default:

```json
{
  "dir": "assets/lang",
  "preview_lang": "ko",
  "filetypes": ["dart"],
  "patterns": ["%f[%w]Tr%(%)%s*%.([%w_]+)"],
  "fallback_style": "none",
  "check": { "extensions": ["dart"] }
}
```

## Several translation directories

Some repositories keep a catalog per package, page or email template.
List them all in one project file with `catalogs` rather than writing a
project file per directory: separate projects can't see each other's keys,
and shared code needs them. React-intl email templates with a shared footer
catalog and a shared component:

```json
{
  "preview_lang": "ko",
  "source_lang": "en",
  "filetypes": ["typescript", "typescriptreact"],
  "patterns": ["formatMessage%s*%(%s*{%s*id%s*:%s*['\"]([^'\"\n]+)['\"]"],
  "fallback_style": "none",
  "catalogs": [
    "src/emails/*/messages",
    { "dir": "src/emails/shared/messages", "file_template": "footer-%s.json" }
  ],
  "uses": {
    "src/emails/shared/components/digest.tsx": ["src/emails/digest_*/messages"]
  },
  "check": { "extensions": ["ts", "tsx"] }
}
```

An entry is a directory, or a table with `dir` and any of `languages`,
`file_template`, `format` and `key_style` for that catalog alone; the
top-level values are every entry's defaults. A `*` matches one directory
level, and a directory it matches that holds no translation files is
skipped. A directory one entry names exactly is never taken by another
entry's `*`: above, `shared/messages` is read as `footer-<lang>.json`, not
as a template.

Which catalogs a file reads:

1. **`uses`**, when one of its globs covers the file: the catalogs listed
   there, in the order of `catalogs`. It's for code that gets its messages
   at runtime, like the shared component above, which receives the daily
   or the weekly digest's catalog as props. A glob that names a directory
   covers everything under it, and `**` matches any number of directories.
2. **Its location.** A catalog serves the folder that holds it, widened
   upward until the next level would hold another catalog:
   `src/emails/order/messages` serves `src/emails/order/`, and
   `apps/admin/public/locales` serves `apps/admin/`. The closest one wins.
3. **All of them**, in the order listed, for a file outside every
   catalog's folder. With a single catalog, that's every file.

The first catalog that has the key supplies the value. The popover shows a
section for each catalog the file reads that has the key, and
`:I18nJump!` lists all of them.

A key that the file's catalogs lack but another catalog has shows
`✗ only in <catalog>` instead of `✗ key not found`, and the audit and
`:checkhealth` name the catalogs that have it. Either the file needs a
`uses` entry, or the key really is missing from its own catalog.

`dir` is the one-catalog spelling of `catalogs`. Set one or the other; a
project file that sets either overrides what `setup()` set.

## All options

The same keys work in `setup()` and in the project file.

| Option | Default | Meaning |
| --- | --- | --- |
| `preset` | `nil` | framework preset, see [Presets](#presets) |
| `project_file` | `'.i18n-inline.json'` | name of the project file |
| `dir` | `nil` | translation directory. Absolute, or relative to the project file. Without a project file, the nearest ancestor of the buffer that contains it. Same as a one-entry `catalogs` |
| `catalogs` | `nil` | several translation directories, see [Several translation directories](#several-translation-directories) |
| `uses` | `nil` | `{ ["file glob"] = { "catalog glob", … } }`: the catalogs a file reads when its location doesn't tell |
| `languages` | `nil` | language list. `nil` finds the files directly inside `dir` (not in subfolders) and names each language after its file (`ko.json` → `ko`, `zh_CN.json` → `zh_CN`); a list limits which ones are used |
| `file_template` | `nil` | file name per language, e.g. `'footer-%s.json'` or `'%s/LC_MESSAGES/messages.po'`. Without `languages`, the files it matches name the languages |
| `format` | `nil` | `'json'`, `'arb'` or `'po'`; `nil` picks by extension |
| `key_style` | `'flat'` | `'nested'` reads `{"a": {"b": …}}` as key `a.b` |
| `separator` | `'.'` | joins nested paths and namespaces (`':'` for `ns:key` setups) |
| `preview_lang` | `'ko'` | the language shown inline |
| `source_lang` | `nil` | the language that owns the key set; turns on "missing in `<lang>`" markers and cross-language checks |
| `filetypes` | `{'clojure'}` | filetypes to scan |
| `patterns` | ClojureScript `tr` calls | Lua patterns that find calls, see [Writing patterns](#writing-patterns). The defaults match `(tr [:key …])`, `(tr-release [:key …])`, `(i18n/tr [:key …])` and `(i18n/tr-release [:key …])` |
| `namespace_patterns` | `{}` | patterns for namespace bindings, see [Namespace bindings](#namespace-bindings) |
| `aliases` | `nil` | call receivers to accept for two-capture patterns; `'*'` accepts any |
| `fallback_style` | `'literal'` | where the default lives: `'literal'` (next string), `'prop'` (a `fallback_props` property) or `'none'` |
| `fallback_props` | `{'defaultMessage'}` | property names for `fallback_style: 'prop'` |
| `compare` | `'fallback'` | `'none'` turns off the default-vs-file comparison |
| `normalize` | `'none'` | `'placeholders'` treats `{n}`, `{{n}}`, `%s` and friends as equal |
| `prefix` | `'  '` | text before the inline value |
| `missing_text` | `'key not found'` | text for a key that no file has |
| `max_len` | `60` | inline value length limit, in characters |
| `position` | `'inline'` | `'inline'` (after the string) or `'eol'` |
| `show` | `'always'` | `'always'`, `'problems'` or `'never'` |
| `hl` | `I18nInline*` groups | highlight groups for match, mismatch, missing and underline |
| `underline_mismatch` | `true` | underline a default that differs from the file |
| `keymaps` | `{}` | `{ hover = …, jump = …, toggle = … }`, set per project buffer |
| `jump.lang` | `'preview'` | which file `:I18nJump` opens: `'preview'`, `'source'` or `'ask'` |
| `jump.open` | `'edit'` | `'edit'`, `'split'`, `'vsplit'`, `'tab'` or `'quickfix'` |
| `hover` | `{ max_len = 60, width = 60, max_height = 20 }` | popover size. `hover.border` defaults to `'winborder'` if set, else `'rounded'` |
| `extmark_priority` | `nil` | raise it if another plugin's virtual text draws over the value |
| `debounce_ms` | `150` | delay between an edit and the refresh |
| `max_filesize` | `1000000` | skip buffers larger than this many bytes |
| `check.extensions` | `{'cljs','cljc','clj'}` | file extensions `:I18nCheck` reads |
| `check.exclude_dirs` | `{'.git','node_modules','target','.cpcache','dist','build','out','.next'}` | directories `:I18nCheck` skips. A name matches at any depth; an entry with a `/` is a path from the project root, like `src/generated` or `apps/*/dist`. A list replaces this one, so repeat the ones you keep. Folders with their own project file are always skipped |
| `check.ignore` | `{}` | key globs whose absence isn't reported: missing keys, missing translations and unused keys (mismatches still are), e.g. `"templateVar.*"`. `*` matches any run of characters, dots included; `?` matches one |
| `keymap` | `nil` | old name for `keymaps.hover` |

## Highlights

The plugin links these groups by default. Restyle them in your colorscheme
or with `vim.api.nvim_set_hl`, or point `hl` at other groups.

| Group | Linked to | Used for |
| --- | --- | --- |
| `I18nInlineValue` | `Comment` | a value that matches the code |
| `I18nInlineMismatch` | `DiagnosticWarn` | `≠` values; the differing language in the popover |
| `I18nInlineMissing` | `DiagnosticError` | `✗` missing keys |
| `I18nInlineMismatchUnderline` | `DiagnosticUnderlineWarn` | the underline on a differing default |

## Writing patterns

Patterns are [Lua patterns](https://www.lua.org/manual/5.1/manual.html#5.4.1),
not regular expressions. The number of captures decides what they mean:

- **One capture** is the key. `%(tr%s*%[%s*:([%w%.%-_/]+)` matches
  `(tr [:key "fallback"])`.
- **Two captures** are the receiver and the key.
  `([%w_.$]+)%s*%(%s*['\"]([^'\"\n]+)['\"]` matches `t('key')`,
  `i18n.t('key')` and `$t('key')`. The match counts only when the receiver
  is a namespace binding or in `aliases`, which is what keeps
  `require('x')` and `console.error('…')` out.

After a match, the plugin looks for the default: whitespace, an optional
comma, then a `"…"`, `'…'` or backtick string. Template strings with
`${…}` are skipped, and the search never runs into the next call. Calls
split over several lines work.

A pattern Lua cannot parse is reported once and matches nothing.

Lua patterns escape with `%`, not backslashes, so putting one in JSON only
needs JSON's own escapes: a `"` becomes `\"`, and `\t` and `\n` mean tab
and newline just as they do in Lua.

## Namespace bindings

`const t = useTranslations('billing')` followed by `t('title')` should
resolve to `billing.title`. Namespace patterns describe that binding:

- **Two captures**: the variable and the namespace. `t` → `billing`.
- **One capture**: the variable only; its keys are used as they are.

```json
{
  "namespace_patterns": [
    "const[ \t]+([%w_]+)[ \t]*=[ \t]*[%w_. \t]-useTranslations%(%s*'([^']*)'%s*%)"
  ],
  "aliases": ["t"]
}
```

Bindings apply to the whole file, and the first one wins. A namespace that
isn't a string literal (`getTranslations(SOME_CONST)`) doesn't bind, so
calls through it are skipped rather than guessed. Add those key groups to
`check.ignore` so they don't show up as unused.

## Key addressing

- `key_style: 'flat'` reads the file as key → value (flat JSON, `.po`).
- `key_style: 'nested'` flattens nested JSON when the file is loaded,
  joining the path with `separator`. If a literal `"a.b"` key and a nested
  `{"a": {"b": …}}` path collide, the nested one wins.

## What the audit reports

`:I18nCheck` reads every matching file under the project file's folder,
except `check.exclude_dirs` and folders with a project file of their own
(those are separate projects). It fills the quickfix list with:

- **mismatch**: the code default differs from the preview language.
  Skipped with `compare: 'none'`; placeholder-only differences go away
  with `normalize: 'placeholders'`.
- **missing key**: none of the file's catalogs has the key. When another
  catalog does, the item says `only in <catalog>` and names the catalogs
  the file reads, and the summary counts these apart.
- **missing translation**: the key is in a catalog's `source_lang` but not
  in another of its languages. The item points at that language's file.

It also prints keys that no call uses, per catalog, checked against
`source_lang` (or the preview language). Keys reached through a namespace
count as used, and so do keys a call finds only in another catalog. On
screen the list stops after ten keys. In a headless run (no UI attached)
it's complete, and the report lines are kept in `:messages`, which is what
the command below reads.

`check.ignore` globs leave a key out of everything but mismatches: use
them for keys built at runtime (reported unused) and keys the code adds to
the messages at runtime (reported missing).

Keys that only exist in a translation, and not in `source_lang`, are not
reported.

To run the audit without opening Neovim (in CI, or from an agent):

```sh
nvim --headless +I18nCheck "+sleep 2" "+redir! > /tmp/i18n-check.txt" \
  "+silent! clist" "+silent messages" "+redir END" +qa
```

## Jumping

`:I18nJump` opens the preview language's file, or the one `jump.lang`
names. `'ask'` asks every time, and `:I18nJump <lang>` picks one for a
single jump. If the key is missing there but exists in `source_lang`, the
source file opens instead, with a warning. A key that's only in another
catalog opens that catalog's file, also with a warning. When the translation file is
already open with unsaved changes, the jump lands on the line in that
buffer, not on disk.

## Other plugins' virtual text

Each plugin draws in its own namespace, so nothing breaks when several draw
on one line, but the text can stack up. The value sits right after the
closing quote to stay out of the way. If it still collides, raise
`extmark_priority`, use `position = 'eol'`, or switch to `show = 'problems'`.

## Performance

One Lua-pattern pass per buffer on each change. Some numbers from real
projects: a full audit of a 1,000-file ClojureScript app with about 4,500
calls takes around 130 ms, a 850-file Flutter app around 60 ms. A single
buffer usually scans in under a millisecond.

`:checkhealth` scans every source file (up to 5,000, for at most two
seconds), so a tree where few files call `t()` still gets a real answer:
about 160 ms on the 1,200-file app.

Translation files are parsed once and cached until their size or mtime
changes. Nested JSON is flattened at that point, so each lookup is a single
table index. Extmarks are reused between refreshes, so nothing flickers,
and the audit works in batches to keep the editor responsive.
