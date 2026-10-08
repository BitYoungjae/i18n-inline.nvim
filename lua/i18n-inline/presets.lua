-- Framework presets (R6.2): a project file like
--   { "preset": "next-intl", "dir": "messages", "preview_lang": "ko", "source_lang": "en" }
-- expands to correct filetypes, patterns, namespace bindings, addressing
-- and comparison defaults for the stack. Explicit keys still win (merged
-- defaults ← preset ← setup()/project file; arrays replace per key).

local M = {}

-- Call pattern shared by the JS stacks: capture (receiver, subkey). The
-- receiver filter (aliases ∪ namespace bindings) turns this permissive
-- pattern into a precise one.
local JS_CALL = "([%w_.$]+)%s*%(%s*['\"]([^'\"\n]+)['\"]"

-- Binding patterns anchor on the `const` literal: matching the generic
-- `ident =` prefix instead costs ~16x more on data-heavy files (the lazy
-- bridge class backtracks through long identifier runs). Hooks are
-- const-bound by convention (lint-enforced in practice); a `let`-bound
-- namespace needs a custom namespace_patterns entry.
--
-- The bridge between `=` and the keyword eats `await ` (or nothing) and
-- stays on one line: it cannot leak a binding across semicolon-less
-- statements.
local BIND = 'const[ \t]+'
local BRIDGE = '[%w_. \t]-'

M.presets = {
  ['next-intl'] = {
    filetypes = { 'typescript', 'typescriptreact', 'javascript', 'javascriptreact' },
    patterns = { JS_CALL },
    aliases = { 't' },
    key_style = 'nested',
    -- const t = useTranslations('ns') / const t = await getTranslations('ns').
    -- Non-literal namespaces (getTranslations(SOME_CONST)) do not bind, so
    -- calls through those receivers are dropped rather than mis-resolved.
    namespace_patterns = {
      BIND .. "([%w_]+)[ \t]*=[ \t]*" .. BRIDGE .. "useTranslations%(%s*'([^']*)'%s*%)",
      BIND .. '([%w_]+)[ \t]*=[ \t]*' .. BRIDGE .. 'useTranslations%(%s*"([^"]*)"%s*%)',
      BIND .. "([%w_]+)[ \t]*=[ \t]*" .. BRIDGE .. "getTranslations%(%s*'([^']*)'%s*%)",
      BIND .. '([%w_]+)[ \t]*=[ \t]*' .. BRIDGE .. 'getTranslations%(%s*"([^"]*)"%s*%)',
      BIND .. '([%w_]+)[ \t]*=[ \t]*' .. BRIDGE .. 'useTranslations%(%s*%)', -- root
    },
    check = {
      extensions = { 'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs' },
      exclude_dirs = { '.git', 'node_modules', 'dist', 'build', '.next', 'out', 'coverage' },
    },
  },

  ['i18next'] = {
    filetypes = { 'typescript', 'typescriptreact', 'javascript', 'javascriptreact' },
    patterns = { JS_CALL },
    aliases = { 't', 'i18n.t', 't.raw' },
    key_style = 'nested',
    -- const { t } = useTranslation('ns') (object and array destructuring,
    -- both quote styles, plus the no-namespace root form).
    namespace_patterns = {
      BIND .. "%{[ \t]*([%w_]+)[ \t]*[^%}\n]*%}[ \t]*=[ \t]*" .. BRIDGE .. "useTranslation%(%s*'([^']*)'%s*%)",
      BIND .. '%{[ \t]*([%w_]+)[ \t]*[^%}\n]*%}[ \t]*=[ \t]*' .. BRIDGE .. 'useTranslation%(%s*"([^"]*)"%s*%)',
      BIND .. '%{[ \t]*([%w_]+)[ \t]*[^%}\n]*%}[ \t]*=[ \t]*' .. BRIDGE .. 'useTranslation%(%s*%)',
      BIND .. '%[[ \t]*([%w_]+)[ \t]*[^%]\n]*%][ \t]*=[ \t]*' .. BRIDGE .. 'useTranslation%(%s*%)',
    },
    check = {
      extensions = { 'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs' },
      exclude_dirs = { '.git', 'node_modules', 'dist', 'build', '.next', 'out', 'coverage' },
    },
  },

  ['vue-i18n'] = {
    filetypes = { 'vue', 'javascript', 'typescript', 'javascriptreact', 'typescriptreact', 'html' },
    patterns = { JS_CALL },
    aliases = { 't', '$t', 'this.$t', 'i18n.t' },
    key_style = 'nested',
    namespace_patterns = {},
    check = {
      extensions = { 'vue', 'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'html' },
      exclude_dirs = { '.git', 'node_modules', 'dist', 'build', 'coverage' },
    },
  },

  -- Flutter gen-l10n: identifier accessors, no string literals anywhere.
  -- Keys are the getter names, flat in .arb files (metadata `@` entries
  -- stripped by the arb decoder). gen-l10n names files app_<lang>.arb, so
  -- point the project file at them with file_template + languages:
  --   { "dir": "lib/l10n", "languages": ["en", "ko"],
  --     "file_template": "app_%s.arb", "preview_lang": "ko" }
  -- Codegen'd accessor classes with string-keyed lookups (e.g. a
  -- `Tr().snake_case_key` codegen class over plain JSON) need no preset —
  -- a 1-capture pattern on the accessor form is enough; see README.
  flutter = {
    filetypes = { 'dart' },
    patterns = {
      'AppLocalizations%.of%([^)]*%)%!?%.([%w_]+)', -- AppLocalizations.of(context)!.key
      'l10n%.([%w_]+)', -- context.l10n.key / <var>.l10n.key
    },
    key_style = 'flat',
    fallback_style = 'none',
    namespace_patterns = {},
    check = {
      extensions = { 'dart' },
      exclude_dirs = { '.git', '.dart_tool', 'build', 'ios', 'android' },
    },
  },

  -- gettext convention: the msgid (source text) is the key and IS the code
  -- literal, so there is nothing to compare against the msgstr — value
  -- preview and missing/untranslated detection only.
  gettext = {
    filetypes = { 'python', 'javascript', 'typescript', 'typescriptreact', 'javascriptreact', 'ruby', 'php', 'c', 'cpp' },
    patterns = { JS_CALL },
    aliases = { 't', '_', 'gettext', '__', 'ngettext' },
    key_style = 'flat',
    format = 'po',
    compare = 'none',
    namespace_patterns = {},
    check = {
      extensions = { 'py', 'js', 'ts', 'tsx', 'jsx', 'rb', 'php', 'c', 'h', 'cpp' },
      exclude_dirs = { '.git', 'node_modules', 'dist', 'build', 'vendor', 'coverage' },
    },
  },
}

function M.get(name)
  return M.presets[name]
end

-- Names for validation error messages.
function M.names()
  local names = {}
  for name in pairs(M.presets) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

return M
