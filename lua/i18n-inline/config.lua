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
  -- Framework preset: 'next-intl' | 'i18next' | 'vue-i18n' | 'flutter' |
  -- 'gettext'.
  -- Provides filetypes/patterns/addressing defaults for the stack.
  preset = nil,
  -- Per-project config file name, resolved upward from the buffer path.
  project_file = '.i18n-inline.json',
  -- Translation directory: absolute path, or relative to the project root
  -- (the nearest ancestor containing it). nil means "must come from the
  -- project file or setup()". Shorthand for a one-entry `catalogs`.
  dir = nil,
  -- Several translation directories ("catalogs") in one project. Entries
  -- are a dir string or { dir, languages?, file_template?, format?,
  -- key_style? }; a `*` in dir matches one directory level. The top-level
  -- languages/file_template/format/key_style are every entry's defaults.
  -- See resolve.lua for which source files read which catalog.
  catalogs = nil,
  -- Source file glob -> catalog dir globs, for code that reads catalogs
  -- other than the one its location implies (a shared component that gets
  -- its messages as props).
  uses = nil,
  -- Language list. nil discovers translation files in `dir` (ko.json/ko.po
  -- -> "ko"); with discovery, a list restricts which files are used.
  languages = nil,
  -- Language -> file path template (e.g. 'locales/%s.json'). Without
  -- `languages`, the languages are discovered from the files it matches.
  file_template = nil,
  -- File format: nil auto-detects by extension (.json, .arb, .po). Built-in
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
  -- Highlight groups. The I18nInline* groups are defined by the plugin as
  -- default links (Comment / DiagnosticWarn / DiagnosticError /
  -- DiagnosticUnderlineWarn), so a colorscheme can restyle them by name;
  -- any group name works here.
  hl = {
    match = 'I18nInlineValue',
    mismatch = 'I18nInlineMismatch',
    missing = 'I18nInlineMissing',
    underline = 'I18nInlineMismatchUnderline',
  },
  underline_mismatch = true, -- underline the fallback string on mismatch
  -- Action keymaps (R6.7): no defaults ship — map `<Plug>(i18n-inline-hover)`
  -- / `<Plug>(i18n-inline-toggle)` / `<Plug>(i18n-inline-jump)` or
  -- :I18nHover / :I18nToggle / :I18nJump yourself, or set these. Applied per
  -- buffer (buffer-local) once its project resolves, so they also work from
  -- the project file and never leak globally.
  keymaps = {
    hover = nil,
    toggle = nil,
    jump = nil,
  },
  keymap = nil, -- deprecated alias for keymaps.hover
  -- :I18nJump — open the translation file at the key under the cursor.
  -- lang: 'preview' | 'source' | 'ask' (vim.ui.select);
  -- open: 'edit' | 'split' | 'vsplit' | 'tab' | 'quickfix' (all languages
  -- into the quickfix list; also :I18nJump!). Missing in the target
  -- language falls back to source_lang when it has the key.
  jump = {
    lang = 'preview',
    open = 'edit',
  },
  -- Extmark priority for the inline virtual text (R7.4): higher wins when
  -- several plugins draw virtual text at the same position. nil = Neovim
  -- default.
  extmark_priority = nil,
  -- Popover bounds (R6.6): value truncation width, window width and height.
  -- border: any nvim_open_win border; nil follows 'winborder' when set,
  -- else 'rounded'.
  hover = {
    max_len = 60,
    width = 60,
    max_height = 20,
    border = nil,
  },
  -- Performance
  debounce_ms = 150,
  max_filesize = 1000000, -- skip buffers larger than this (bytes)
  -- :I18nCheck project audit
  check = {
    extensions = { 'cljs', 'cljc', 'clj' },
    -- Bare names match at any depth; entries with a '/' are path globs
    -- from the project root. Subtrees with their own project file are
    -- always skipped.
    exclude_dirs = { '.git', 'node_modules', 'target', '.cpcache', 'dist', 'build', 'out', '.next' },
    -- Glob patterns (R5.2) for keys whose absence is not reported: missing
    -- keys, missing translations and unused keys (mismatches still are),
    -- e.g. known-dynamic key groups: "templateVar.*", "Invoice.image".
    ignore = {},
  },
}

local config

function M.get()
  if not config then
    config = vim.deepcopy(defaults)
  end
  return config
end

-- Option schema (validation and unknown-key detection share it). A spec is
-- a type name, an enum list, or a nested schema for dict options:
--   'string' | 'number' | 'boolean'
--   'list'     — list of strings, may be empty
--   'patterns' — non-empty list of strings
--   { enum = {...} }
--   { fields = { … } } — dict; unknown sub-keys are reported too
--   { entries = { … } } — non-empty list of strings or of such dicts
--   { map = spec } — dict of string keys to `spec` values
local format_spec = { enum = nil } -- filled lazily (formats requires nothing from here)
local key_style_spec = { enum = { 'flat', 'nested' } }

local schema = {
  preset = { enum = presets.names() },
  project_file = 'string',
  dir = 'string',
  catalogs = {
    entries = {
      dir = 'string',
      languages = 'patterns',
      file_template = 'string',
      format = format_spec,
      key_style = key_style_spec,
    },
  },
  uses = { map = 'patterns' },
  languages = 'patterns',
  file_template = 'string',
  format = format_spec,
  key_style = key_style_spec,
  separator = 'string',
  preview_lang = 'string',
  source_lang = 'string',
  filetypes = 'list',
  patterns = 'patterns',
  namespace_patterns = 'list',
  aliases = 'list',
  fallback_style = { enum = { 'literal', 'prop', 'none' } },
  fallback_props = 'list',
  compare = { enum = { 'fallback', 'none' } },
  normalize = { enum = { 'none', 'placeholders' } },
  prefix = 'string',
  missing_text = 'string',
  max_len = 'number',
  position = { enum = { 'inline', 'eol' } },
  show = { enum = { 'always', 'problems', 'never' } },
  hl = { fields = { match = 'string', mismatch = 'string', missing = 'string', underline = 'string' } },
  underline_mismatch = 'boolean',
  keymaps = { fields = { hover = 'string', toggle = 'string', jump = 'string' } },
  keymap = 'string',
  jump = {
    fields = {
      lang = { enum = { 'preview', 'source', 'ask' } },
      open = { enum = { 'edit', 'split', 'vsplit', 'tab', 'quickfix' } },
    },
  },
  extmark_priority = 'number',
  hover = { fields = { max_len = 'number', width = 'number', max_height = 'number', border = 'any' } },
  debounce_ms = 'number',
  max_filesize = 'number',
  check = { fields = { extensions = 'list', exclude_dirs = 'list', ignore = 'list' } },
}

local function is_string_list(v)
  if type(v) ~= 'table' then
    return false
  end
  for k, s in pairs(v) do
    if type(k) ~= 'number' or type(s) ~= 'string' then
      return false
    end
  end
  return true
end

local function quoted(list)
  local out = {}
  for i, v in ipairs(list) do
    out[i] = '"' .. v .. '"'
  end
  return table.concat(out, ', ')
end

-- nil when `v` satisfies `spec`, else an error message for `name`.
local function check_value(name, v, spec)
  if spec == 'any' then
    return nil
  elseif spec == 'list' then
    if not is_string_list(v) then
      return name .. ' must be a list of strings'
    end
  elseif spec == 'patterns' then
    if not is_string_list(v) or #v == 0 then
      return name .. ' must be a non-empty list of strings'
    end
  elseif type(spec) == 'string' then
    if type(v) ~= spec then
      return ('%s must be a %s'):format(name, spec)
    end
  elseif spec.enum then
    if not vim.tbl_contains(spec.enum, v) then
      if name == 'preset' then
        return ('unknown preset "%s" (available: %s)'):format(tostring(v), table.concat(spec.enum, ', '))
      end
      return ('%s must be one of: %s'):format(name, quoted(spec.enum))
    end
  elseif spec.fields then
    if type(v) ~= 'table' then
      return ('%s must be a table'):format(name)
    end
    for k, sub in pairs(v) do
      if spec.fields[k] then
        local err = check_value(name .. '.' .. k, sub, spec.fields[k])
        if err then
          return err
        end
      end
    end
  elseif spec.entries then
    if type(v) ~= 'table' or not vim.islist(v) or #v == 0 then
      return name .. ' must be a non-empty list'
    end
    for i, entry in ipairs(v) do
      local ename = ('%s[%d]'):format(name, i)
      if type(entry) == 'table' then
        if type(entry.dir) ~= 'string' then
          return ename .. '.dir must be a string'
        end
        local err = check_value(ename, entry, { fields = spec.entries })
        if err then
          return err
        end
      elseif type(entry) ~= 'string' then
        return ename .. ' must be a directory string or a table with "dir"'
      end
    end
  elseif spec.map then
    if type(v) ~= 'table' or (next(v) ~= nil and vim.islist(v)) then
      return ('%s must be a table of name -> value'):format(name)
    end
    for k, sub in pairs(v) do
      local err = check_value(('%s["%s"]'):format(name, tostring(k)), sub, spec.map)
      if err then
        return err
      end
    end
  end
  return nil
end

-- Validate a config table (used for both setup() and project files).
-- Returns nil when valid, or an error message.
local function validate(cfg)
  format_spec.enum = format_spec.enum or require('i18n-inline.formats').names()
  local names = vim.tbl_keys(schema)
  table.sort(names) -- deterministic first error
  for _, name in ipairs(names) do
    if cfg[name] ~= nil then
      local err = check_value(name, cfg[name], schema[name])
      if err then
        return err
      end
    end
  end
  if cfg.dir and cfg.catalogs then
    return 'set either dir or catalogs, not both'
  end
  return nil
end

-- Keys the schema does not know (typos like "preview_language" would
-- otherwise be silently ignored). Dotted for nested dicts. JSON-file
-- conventions ("$schema", "//" comment keys) are not options and pass.
local function is_meta(k)
  return type(k) == 'string' and (k:sub(1, 1) == '$' or k:sub(1, 2) == '//')
end

function M.unknown_keys(cfg)
  local out = {}
  for k, v in pairs(cfg or {}) do
    local spec = schema[k]
    if is_meta(k) then
      -- metadata, not an option
    elseif spec == nil then
      out[#out + 1] = tostring(k)
    elseif type(spec) == 'table' and spec.fields and type(v) == 'table' then
      for sub in pairs(v) do
        if spec.fields[sub] == nil then
          out[#out + 1] = k .. '.' .. tostring(sub)
        end
      end
    elseif type(spec) == 'table' and spec.entries and type(v) == 'table' then
      for i, entry in ipairs(v) do
        if type(entry) == 'table' then
          for sub in pairs(entry) do
            if spec.entries[sub] == nil and not is_meta(sub) then
              out[#out + 1] = ('%s[%d].%s'):format(k, i, tostring(sub))
            end
          end
        end
      end
    end
  end
  table.sort(out)
  return out
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
  -- `dir` and `catalogs` spell one setting: a project file that sets either
  -- overrides whichever one setup() set
  if file_cfg and file_cfg.dir then
    cfg.catalogs = nil
  elseif file_cfg and file_cfg.catalogs then
    cfg.dir = nil
  end
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
  local unknown = M.unknown_keys(opts)
  if #unknown > 0 then
    vim.notify('[i18n-inline] setup(): unknown options ignored: ' .. table.concat(unknown, ', '), vim.log.levels.WARN)
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
