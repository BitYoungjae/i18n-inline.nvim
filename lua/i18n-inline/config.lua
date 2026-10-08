-- Configuration.
--
-- Options come from two places, merged in this order (later wins):
--   1. Global defaults (this file), overridden by `setup(opts)`.
--   2. A per-project file (`.i18n-inline.json` by default) discovered by
--      walking up from each buffer — see README for the schema.
-- A `preset` key (either level) first expands its framework defaults under
-- the base, so the effective order is: defaults ← preset ← overrides.
--
-- Merge semantics (R6.4, intentional): `vim.tbl_deep_extend('force')`
-- replaces list-like tables wholesale (a project file's `patterns` replaces
-- the defaults entirely) while merging dict-like tables key by key.

local presets = require('i18n-inline.presets')

local M = {}

local defaults = {
  -- Framework preset: 'next-intl' | 'i18next' | 'vue-i18n' | 'gettext'.
  -- Provides filetypes/patterns/addressing defaults for the stack.
  preset = nil,
  -- Per-project config file name, resolved upward from the buffer path.
  project_file = '.i18n-inline.json',
  -- Translation directory: absolute path, or relative to the project root
  -- (the nearest ancestor containing it). nil means "must come from the
  -- project file or setup()".
  dir = nil,
  -- Language list. nil discovers translation files in `dir` (ko.json/ko.po
  -- -> "ko").
  languages = nil,
  -- Language -> file path template (e.g. 'locales/%s.json').
  -- When set, `languages` must be given explicitly.
  file_template = nil,
  -- File format: nil auto-detects by extension (.json, .po). Built-in
  -- formats are listed by :checkhealth; see formats.lua to add more.
  format = nil,
  -- Key addressing (R1): 'flat' reads the file as key -> value (today's
  -- behavior); 'nested' flattens hierarchical JSON into separator-joined
  -- paths (Invoice.amount <- {"Invoice": {"amount": …}}).
  key_style = 'flat',
  -- Path separator for key_style='nested' and namespace composition.
  separator = '.',
  -- Language shown in the inline preview.
  preview_lang = 'ko',
  -- Source language (R2.3/R5.3): the locale that owns the key set. When
  -- set, keys missing from other files are audited against it, and a key
  -- present here but missing in preview_lang reads as a translation gap
  -- instead of "key not found".
  source_lang = nil,
  -- Filetypes to scan.
  filetypes = { 'clojure' },
  -- Extraction patterns (Lua patterns). Contract: 1 capture = key;
  -- 2 captures = (receiver, subkey) — see scan.lua.
  patterns = {
    '%(tr%s*%[%s*:([%w%.%-_/]+)',
    '%(tr%-release%s*%[%s*:([%w%.%-_/]+)',
    '%(i18n/tr%s*%[%s*:([%w%.%-_/]+)',
    '%(i18n/tr%-release%s*%[%s*:([%w%.%-_/]+)',
  },
  -- Namespace binding patterns (R1.3), run before the call patterns:
  -- 2 captures = (variable, namespace literal), 1 capture = (variable, root).
  namespace_patterns = {},
  -- Allowed receivers for 2-capture call patterns; a match whose receiver
  -- is neither namespace-bound nor aliased is dropped. '*' allows any.
  aliases = nil,
  -- Fallback extraction: 'literal' = next string literal after the key;
  -- 'prop' = `fallback_props` property (defineMessages defaultMessage, …);
  -- 'none' = no fallback (identifier-style calls like Flutter's Tr().key,
  -- where the next string literal is unrelated code).
  fallback_style = 'literal',
  fallback_props = { 'defaultMessage' },
  -- Drift definition (R2): 'fallback' compares the code fallback against
  -- the preview language value; 'none' disables that comparison entirely
  -- (gettext, no-fallback stacks) leaving value preview + missing keys.
  compare = 'fallback',
  -- Comparison normalization (R2.5): 'placeholders' treats ICU `{n}`,
  -- handlebars `{{n}}` and printf `%s` as equal on both sides; 'none'
  -- compares literally (previous behavior).
  normalize = 'none',
  -- Display
  prefix = '  ',
  missing_text = 'key not found',
  max_len = 60, -- max preview length in runes
  position = 'inline', -- 'inline' | 'eol'
  show = 'always', -- 'always' | 'problems' | 'never' (popover/audit only)
  hl = {
    match = 'Comment',
    mismatch = 'DiagnosticWarn',
    missing = 'DiagnosticError',
    underline = 'DiagnosticUnderlineWarn',
  },
  underline_mismatch = true, -- underline the fallback string on mismatch
  -- Action keymaps (R6.7): no defaults ship — map `<Plug>(i18n-inline-hover)`
  -- / `<Plug>(i18n-inline-toggle)` or :I18nHover / :I18nToggle yourself, or
  -- set these. Applied per buffer (buffer-local) once its project resolves,
  -- so they also work from the project file and never leak globally.
  keymaps = {
    hover = nil,
    toggle = nil,
  },
  keymap = nil, -- deprecated alias for keymaps.hover
  -- Extmark priority for the inline virtual text (R7.4): higher wins when
  -- several plugins draw virtual text at the same position. nil = Neovim
  -- default.
  extmark_priority = nil,
  -- Popover bounds (R6.6): value truncation width, window width and height.
  hover = {
    max_len = 60,
    width = 60,
    max_height = 20,
  },
  -- Performance
  debounce_ms = 150,
  max_filesize = 1000000, -- skip buffers larger than this (bytes)
  -- :I18nCheck project audit
  check = {
    extensions = { 'cljs', 'cljc', 'clj' },
    exclude_dirs = { '.git', 'node_modules', 'target', '.cpcache', 'dist', 'build', 'out', '.next' },
    -- Glob patterns (R5.2) for keys excluded from unused-key detection,
    -- e.g. known-dynamic key groups: "templateVar.*", "Invoice.image".
    ignore = {},
  },
}

local config

function M.get()
  if not config then
    return vim.deepcopy(defaults)
  end
  return config
end

local function is_string_list(v)
  if type(v) ~= 'table' or #v == 0 then
    return false
  end
  for _, s in ipairs(v) do
    if type(s) ~= 'string' then
      return false
    end
  end
  return true
end

local function one_of(v, allowed)
  return v == nil or vim.tbl_contains(allowed, v)
end

-- Validate a config table (used for both setup() and project files).
-- Returns nil when valid, or an error message.
local function validate(cfg)
  if cfg.patterns ~= nil and not is_string_list(cfg.patterns) then
    return 'patterns must be a non-empty list of strings'
  end
  if cfg.namespace_patterns ~= nil and not is_string_list(cfg.namespace_patterns) then
    return 'namespace_patterns must be a non-empty list of strings'
  end
  if cfg.aliases ~= nil and not is_string_list(cfg.aliases) then
    return 'aliases must be a non-empty list of strings'
  end
  if cfg.file_template and not cfg.languages then
    return 'file_template requires an explicit languages list'
  end
  if not one_of(cfg.key_style, { 'flat', 'nested' }) then
    return 'key_style must be "flat" or "nested"'
  end
  if not one_of(cfg.compare, { 'fallback', 'none' }) then
    return 'compare must be "fallback" or "none"'
  end
  if not one_of(cfg.normalize, { 'none', 'placeholders' }) then
    return 'normalize must be "none" or "placeholders"'
  end
  if not one_of(cfg.fallback_style, { 'literal', 'prop', 'none' }) then
    return 'fallback_style must be "literal", "prop" or "none"'
  end
  if not one_of(cfg.show, { 'always', 'problems', 'never' }) then
    return 'show must be "always", "problems" or "never"'
  end
  if not one_of(cfg.format, require('i18n-inline.formats').names()) then
    return ('format must be one of: %s'):format(table.concat(require('i18n-inline.formats').names(), ', '))
  end
  if cfg.preset ~= nil and not presets.get(cfg.preset) then
    return ('unknown preset "%s" (available: %s)'):format(cfg.preset, table.concat(presets.names(), ', '))
  end
  if cfg.keymaps ~= nil then
    if type(cfg.keymaps) ~= 'table' then
      return 'keymaps must be a table { hover = …, toggle = … }'
    end
    for _, k in ipairs({ 'hover', 'toggle' }) do
      local v = cfg.keymaps[k]
      if v ~= nil and type(v) ~= 'string' then
        return ('keymaps.%s must be a string or null'):format(k)
      end
    end
  end
  return nil
end

-- Drop keys explicitly set to JSON null (decoded as vim.NIL): a project
-- file writing `"keymaps": null` means "not set", not "replace with NIL".
local function sanitize(tbl)
  for k, v in pairs(tbl) do
    if type(v) == 'table' then
      sanitize(v)
    elseif v == vim.NIL then
      tbl[k] = nil
    end
  end
  return tbl
end

local setup_opts = {}

-- Effective configuration = defaults ← preset ← setup() ← project file.
-- The preset layer must sit under BOTH user layers, so it is expanded from
-- the merged user options (a project-file preset wins over setup()'s), never
-- on top of an already-defaulted table.
local function build(file_cfg)
  local user = sanitize(vim.tbl_deep_extend('force', vim.deepcopy(setup_opts), file_cfg or {}))
  local base = vim.deepcopy(defaults)
  if user.preset then
    base = vim.tbl_deep_extend('force', base, presets.get(user.preset))
  end
  local cfg = vim.tbl_deep_extend('force', base, user)
  -- keymap (deprecated) still applies, from setup() and project files alike
  if cfg.keymap and not cfg.keymaps.hover then
    cfg.keymaps.hover = cfg.keymap
  end
  return cfg
end

function M.setup(opts)
  opts = sanitize(vim.deepcopy(opts or {}))
  local err = validate(opts)
  if err then
    error('[i18n-inline] ' .. err)
  end
  setup_opts = opts
  config = build({})
  return config
end

-- Merge a project file's table over the global config.
-- Returns the merged table, or nil + error message.
function M.merge_project(file_cfg)
  file_cfg = sanitize(vim.deepcopy(file_cfg or {}))
  local err = validate(file_cfg)
  if err then
    return nil, err
  end
  return build(file_cfg)
end

function M.reset()
  config = nil
  setup_opts = {}
end

return M
