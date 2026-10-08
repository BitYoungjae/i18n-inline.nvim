# Generalization requirements

Requirements for extending i18n-inline.nvim beyond its current sweet spot
(flat-key JSON + inline string fallback, i.e. the cljs-app shape).
This file records **requirements and evidence only** — solution design happens
in a separate session. Written 2026-10-08 after setup attempts against real
repositories.

## Evidence: what works and what doesn't today

### Works — cljs-app (ClojureScript)

- Flat key → string JSON (`src/tr/cljs/*.json`, 13 languages), inline fallback
  in `(tr [:key "fallback"])`.
- Verified headless: inline preview, `≠` mismatch + underline, `✗` missing,
  `gK` popover, `:I18nCheck` audit.

### Works — synthetic JS project (pattern swap only)

- `t('key', 'fallback')` with a project-file `patterns`/`filetypes` override:
  all four statuses render correctly and the audit works. The plugin core is
  language-agnostic; Clojure is just the default config.
- Limitation found: fallback literals in backticks (JS template literals) are
  not parsed — `scan.lua` accepts only `"` and `'`.

### Does not work — next-app (Next.js + next-intl)

Empirical result (2026-10-08): pointed at `messages/` with a
`t%(...['"]key['"]...)` pattern, **7 of 7 call sites in
`src/views/editor/ui/EditorPage.tsx` rendered
`✗ key not found`**. Three independent structural mismatches, each alone
enough to block usage:

- **G1 — nested JSON.** `messages/*.json` are nested objects addressed by dot
  paths (`Invoice.amount`). Key lookup is `keys[m.key]` (`scan.status`), a
  flat top-level index; there is no flattening or path descent, so even
  fully-qualified dotted keys in code do not resolve.
- **G2 — namespace composition.** `const t = useTranslations('error')` then
  `t('retry')` — the real key `error.retry` is composed at runtime. A static
  single-line pattern can only capture `retry`. This affects the majority of
  call sites (most `t('x')` calls are namespace-relative).
- **G3 — no inline fallback.** next-intl's `t(key, values?, opts?)` has no
  fallback parameter; the second argument is an interpolation-values object.
  The plugin's core comparison (code fallback vs file value) has no input
  here. The meaningful features for this shape are value preview, and drift
  defined *between language files* (source lang vs preview lang) instead of
  code-vs-file.

Secondary gaps observed in the same codebase:

- **G4 — dynamic keys.** `` t(`${i18nKey}.documentation`) ``, `t(titleI18nKey)`.
  Unresolvable statically (already a documented limitation). Today these are
  simply not matched (the pattern requires a quote), so no inline false
  positives — but they poison the audit's unused-key detection.
- **G5 — call aliases.** `tCommon(...)`, `t.raw(...)`: alias-bound or namespaced
  receivers are invisible to a literal `t%(` pattern.

### Implementation facts the requirements build on

- `status = 'novalue'` (key resolves, no fallback literal) already renders the
  value in match style (`preview.lua/build_virt_text`) — value-only preview is
  nearly free once keys resolve.
- Config merge is `tbl_deep_extend('force')` at both levels: project-file
  arrays (`filetypes`, `patterns`, …) **replace** defaults per key.
- **Bug:** `keymap` in a project file is silently ignored — it is applied only
  inside `setup()` (`init.lua:71`) before any project file is read, although
  the README documents it as a project-file option.
- `:I18nCheck` classifies against **`preview_lang` only**; there is no
  separate source-language concept. Unused detection = keys in the preview
  file not matched by any scan pattern (false positives under G2/G4).
- `:I18nCheck` walks `project.root` by `check.extensions` / `check.exclude_dirs`.

## Requirements

### R1 — key addressing schemes

- **R1.1** Flat top-level keys (today's behavior) must keep working unchanged.
- **R1.2** Nested JSON addressed by dot paths (next-intl, i18next, vue-i18n):
  `Invoice.amount` must resolve against `{"Invoice": {"amount": …}}`.
- **R1.3** Namespace-composed keys: extraction must combine a namespace
  binding visible in the buffer (`useTranslations('error')`,
  `getTranslations('error')`, …) with relative subkeys. Scope and precision of
  the binding analysis (multiple/conditional bindings per file) is a design
  decision, not settled here.
- **R1.4** Configurable separator/shape for flat-but-delimited schemes
  (e.g. i18next JSON namespace files with `ns:key`, slash-separated keys).
- **R1.5** Keys containing literal dots (i18next escape syntax `a\.b`) must
  not silently collide with path descent — collision policy is a design
  question.

### R2 — fallback sources and drift definition

- **R2.1** Inline string literal after the key (today) must keep working.
- **R2.2** Structured adjacent fallback: `defineMessages({ id: 'k',
  defaultMessage: 'fb' })` — the fallback is not the *next* literal (a
  `description` may intervene). The "next string literal" heuristic is
  insufficient; extraction needs property awareness or per-project structure.
- **R2.3** No-fallback stacks must be first-class: value preview for every
  resolvable key, and a drift notion of **source language vs preview
  language** (next-app: `en` is the source of truth — its existing
  `i18n-check` CLI audits missing keys against `en`). The plugin currently
  has no source-language concept; audit "missing" should be definable against
  it, and code-vs-file comparison disabled when no fallback exists.
- **R2.4** Gettext convention where the msgid *is* the source text (key =
  natural-language text): fallback comparison degenerates to msgid-vs-msgstr.
- **R2.5** Comparison normalization policy: ICU placeholders (`{count}`),
  printf (`%s`), and handlebars (`{{n}}`) differences should not be reported
  as drift (or the policy must be configurable). Today comparison is literal
  after unescaping.

### R3 — extraction robustness

- **R3.1** Backtick string literals must parse as fallbacks (JS/TS template
  literals without interpolation).
- **R3.2** Call aliases (`tCommon(`, `i18n.t(`, `$t(`, `t.raw(`) — either a
  user-declarable alias list or extraction smart enough to see them; missed
  aliases silently hide call sites.
- **R3.3** Structured/multiline calls where intervening literals break the
  next-literal heuristic (React props, message catalogs). Any structural
  extraction (tree-sitter or similar) must respect the zero-dependency stance
  at least as a graceful-degradation floor (see R7.2).
- **R3.4** Dynamic keys must never produce inline false positives (holds
  today because patterns require quoted keys) and must be excludable from
  audit noise (see R5.2).

### R4 — storage formats beyond JSON

- **R4.1** A format-agnostic parser interface: decode(path) → key→value map
  with the same mtime+size caching, so formats plug in without touching
  scan/preview/audit.
- **R4.2** Priority and exact set of formats (YAML — Rails/vue-i18n; `.po` —
  gettext/Django/WordPress; `.arb` — Flutter; `.properties`/XML — Java/
  Android; PHP arrays — Laravel) is a design-session decision; the
  requirement is the interface, not each format.

### R5 — audit (`:I18nCheck`) semantics

- **R5.1** Namespace-aware unused detection: keys referenced only through a
  namespace binding must count as used (today they read as unused).
- **R5.2** Ignore patterns (glob) for known-dynamic key groups.
  next-app already maintains such a list for its `i18n-check` CLI
  (`templateVar.*`, `Invoice.image`, …); the plugin should accept an
  equivalent list, and ideally interop with or read from existing tooling
  config where practical.
- **R5.3** Missing-key audit against a declared **source language** distinct
  from `preview_lang` (see R2.3).
- **R5.4** File-walk exclusion must remain adequate for JS monorepos
  (`node_modules` is default; consider respecting `.gitignore` basics).

### R6 — configuration and ergonomics

- **R6.1** Every option documented as project-file-writable must actually
  apply from the project file (`keymap` does not — bug above).
- **R6.2** Framework presets: common stacks (next-intl, i18next/react-i18next,
  vue-i18n, gettext) should not require hand-written Lua patterns — a
  `"preset": "next-intl"`-style project file should produce correct
  `filetypes`, `patterns`, addressing, and source-language defaults.
- **R6.3** `:checkhealth` must catch G1/G2-class misconfigurations with
  actionable output: dir found, files parse, keys resolve, patterns match at
  least one call site in the project, sample resolution rate.
- **R6.4** The array-replacement merge semantics (project file replaces
  `patterns`/`filetypes` wholesale) must be documented and kept intentional.
- **R6.5 Display policy and runtime toggle.** `show` today is
  `'always' | 'problems'`; a mode that renders no inline text at all
  (popover/audit-only usage) is required, plus a user-facing toggle (command +
  default keymap) that flips inline display at runtime. Toggle scope (current
  buffer / whole project / global) is a design decision.
- **R6.6 Popover readability.** The `gK` popover must stay readable at
  production scale (13 languages): stable language-code column alignment, a
  truncation/wrapping policy for long CJK values, bounded width/height with
  scrolling if needed. (Per-language mismatch highlighting already exists.)
- **R6.7 Action keymaps as config.** Both actions — popover and the inline
  toggle (R6.5) — must expose configurable keymaps (e.g. `<leader>…`
  mappings), from `setup()` and the project file alike; project-file keymaps
  must actually apply (same code path as the R6.1 bug). **Ship no default
  keymaps**: every action must be reachable via a `<Plug>` mapping and a
  command (`:I18nHover`, `:I18nToggle`, …) so defaults cannot collide with
  user or distro mappings. The README carries suggested, distro-aware
  mappings instead — which must avoid keys claimed at **LspAttach time**:
  empirically, LazyVim maps `gK` → signature help buffer-locally on attach
  (`lazyvim/plugins/lsp/init.lua`, `has = "signatureHelp"`), silently
  shadowing any global plugin mapping (startup-state keymap scans do not
  catch this; it was missed once here). Prefer `<leader>…` mappings outside
  the LSP attach set — `<leader>ii` hover and `<leader>ui` toggle are
  verified free on the reference LazyVim setup — plus a which-key group
  registration snippet for discoverability.

### R7 — non-functional

- **R7.1** Performance budget from DESIGN.md must hold: ~1 ms per buffer
  scan, few hundred ms for a ~1,000-file audit. Namespace binding analysis
  adds a pre-pass; budget must be re-measured, not assumed.
- **R7.2** Zero-runtime-dependency stance: optional richer extraction
  (tree-sitter) may exist, but pattern-based extraction must keep working
  without it.
- **R7.3** Cache invalidation stays mtime+size keyed; new formats follow the
  same contract.
- **R7.4 Virtual-text coexistence.** Other plugins also draw virtual text
  (diagnostics `virtual_text`, native/LS inlay hints, context/preview
  plugins). Extmarks are namespace-isolated, so coexistence never errors or
  cross-overwrites — the failure mode is visual stacking noise (concatenation
  for `eol`/`inline` anchoring, covering for `overlay`). The plugin must stay
  legible next to common neighbors: deliberate anchoring (today: inline right
  after the closing quote), optionally a configurable extmark `priority` for
  stacking order, and the R6.5 toggle as the escape hatch.

## Ecosystem survey (source of the requirements above)

| Stack | Call form | Key addressing | Fallback | Storage |
| --- | --- | --- | --- | --- |
| cljs-app `(tr …)` | `(tr [:k "fb"])` | flat | inline literal | flat JSON |
| next-app (next-intl) | `useTranslations('ns')` + `t('k')` | ns + dot-nested | none | nested JSON |
| i18next / react-i18next | `useTranslation('ns')` + `t('k')` / `t('ns.k')` | dot-nested or `ns:key` | `defaultValue` option, not positional | nested JSON |
| vue-i18n | `$t('k')` | dot-nested | via `fallbackLocale` | JSON/YAML |
| FormatJS / react-intl | `defineMessages({id, defaultMessage})` | flat ICU id | adjacent property | JSON |
| gettext (Django, Rails, WordPress) | `_('text')`, `t('text')` | msgid = source text | msgid | `.po` |
| Laravel | `__('k')` | dot-nested | none | PHP arrays / JSON |
| Flutter | generated accessors | class members | ARB metadata | `.arb` |
| Java / Android | `R.string.k` / `msg('k')` | flat id | none | `.properties` / XML |

## Suggested priorities (input for the design session, not decisions)

- **P0 — make next-app usable:** R1.2, R1.3, R2.3, R3.1, R3.2 (aliasing),
  plus a next-intl preset (R6.2).
- **P1 — correctness/ergonomics:** R6.1 (keymap bug), R6.3 (checkhealth),
  R6.5–R6.7 (display toggle, popover readability, action keymaps),
  R2.5 (placeholder normalization), R5.1–R5.3 (audit semantics).
- **P2 — breadth:** R4 format parsers, R3.3 structural extraction.

## Open questions (to settle during design)

1. Namespace binding analysis: buffer-scope heuristic vs tree-sitter vs
   LSP — precision/dependency trade-off.
2. Flattening vs lazy path descent for R1.2, and the literal-dot collision
   policy (R1.5).
3. Drift-definition configurability (R2.3): config shape and naming
   (`source_lang`? `compare`?).
4. Whether presets live in the plugin or as documented recipes (R6.2).
5. Whether audit interop with existing CLI tooling (e.g. reading
   `i18n-check` ignore lists from package.json) is worth the coupling (R5.2).
6. Toggle scope for R6.5 (buffer vs project vs global), and whether extmark
   `priority` needs to be user-configurable for R7.4 coexistence.
