-- Configuration.
--
-- Options come from two places, merged in this order (later wins):
--   1. Global defaults (this file), overridden by `setup(opts)`.
--   2. A per-project file (`.i18n-inline.json` by default) discovered by
--      walking up from each buffer — see README for the schema.

local M = {}

local defaults = {
  -- Per-project config file name, resolved upward from the buffer path.
  project_file = '.i18n-inline.json',
  -- Translation directory: absolute path, or relative to the project root
  -- (the nearest ancestor containing it). nil means "must come from the
  -- project file or setup()".
  dir = nil,
  -- Language list. nil discovers `*.json` files in `dir` (ko.json -> "ko").
  languages = nil,
  -- Language -> file path template (e.g. 'locales/%s.json').
  -- When set, `languages` must be given explicitly.
  file_template = nil,
  -- Language shown in the inline preview.
  preview_lang = 'ko',
  -- Filetypes to scan.
  filetypes = { 'clojure' },
  -- Extraction patterns (Lua patterns). Contract: capture #1 is the
  -- translation key. The next string literal after the match is parsed
  -- automatically as the fallback text.
  patterns = {
    '%(tr%s*%[%s*:([%w%.%-_/]+)',
    '%(tr%-release%s*%[%s*:([%w%.%-_/]+)',
    '%(i18n/tr%s*%[%s*:([%w%.%-_/]+)',
    '%(i18n/tr%-release%s*%[%s*:([%w%.%-_/]+)',
  },
  -- Display
  prefix = '  ',
  missing_text = 'key not found',
  max_len = 60, -- max preview length in runes
  position = 'inline', -- 'inline' | 'eol'
  show = 'always', -- 'always' | 'problems' (mismatches and missing keys only)
  hl = {
    match = 'Comment',
    mismatch = 'DiagnosticWarn',
    missing = 'DiagnosticError',
    underline = 'DiagnosticUnderlineWarn',
  },
  underline_mismatch = true, -- underline the fallback string on mismatch
  -- Default key mapping, e.g. 'gK'. nil only provides <Plug>(i18n-inline-hover).
  keymap = nil,
  -- Performance
  debounce_ms = 150,
  max_filesize = 1000000, -- skip buffers larger than this (bytes)
  -- :I18nCheck project audit
  check = {
    extensions = { 'cljs', 'cljc', 'clj' },
    exclude_dirs = { '.git', 'node_modules', 'target', '.cpcache' },
  },
}

local config

function M.get()
  if not config then
    return vim.deepcopy(defaults)
  end
  return config
end

-- Validate a config table (used for both setup() and project files).
-- Returns nil when valid, or an error message.
local function validate(cfg)
  if cfg.patterns ~= nil then
    if type(cfg.patterns) ~= 'table' or #cfg.patterns == 0 then
      return 'patterns must be a non-empty list of strings'
    end
    for i, p in ipairs(cfg.patterns) do
      if type(p) ~= 'string' then
        return ('patterns[%d] must be a string'):format(i)
      end
    end
  end
  if cfg.file_template and not cfg.languages then
    return 'file_template requires an explicit languages list'
  end
  return nil
end

function M.setup(opts)
  opts = opts or {}
  local err = validate(opts)
  if err then
    error('[i18n-inline] ' .. err)
  end
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  return config
end

-- Merge a project file's table over the global config.
-- Returns the merged table, or nil + error message.
function M.merge_project(file_cfg)
  local err = validate(file_cfg)
  if err then
    return nil, err
  end
  return vim.tbl_deep_extend('force', vim.deepcopy(M.get()), file_cfg)
end

function M.reset()
  config = nil
end

return M
