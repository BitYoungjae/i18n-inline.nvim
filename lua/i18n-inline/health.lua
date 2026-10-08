-- :checkhealth i18n-inline
--
-- Catches the general failure modes (R6.3): missing project/dir, unparseable
-- translation files, key-addressing mismatches (nested JSON read as flat),
-- and patterns that match nothing (or whose keys never resolve) in the
-- actual source tree.

local config = require('i18n-inline.config')
local resolve = require('i18n-inline.resolve')
local scan = require('i18n-inline.scan')
local util = require('i18n-inline.util')

local M = {}

local SAMPLE_FILES = 25
-- The sample is spread evenly over the (sorted) source tree: the first N
-- files of a walk all come from the first directories, which are often
-- build scripts or tooling with no i18n calls (cljs-app: 0 calls in the
-- first 25 files of 1,200). Walking is cheap (~5 ms per 1k files); the cap
-- bounds it on huge trees.
local WALK_CAP = 5000

local function sample(files)
  if #files <= SAMPLE_FILES then
    return files
  end
  local out = {}
  local step = #files / SAMPLE_FILES
  for i = 0, SAMPLE_FILES - 1 do
    out[#out + 1] = files[math.floor(i * step) + 1]
  end
  return out
end

local function count_keys(keys)
  local n = 0
  for _ in pairs(keys or {}) do
    n = n + 1
  end
  return n
end

-- Nested-detection: read the preview file raw and see whether its decoded
-- top level is entirely non-table while nested tables exist (key_style=flat
-- over nested JSON).
local function check_key_style(project)
  local cfg = project.cfg
  local path = project.langs[cfg.preview_lang]
  if not path or path:match('%.json$') == nil or cfg.key_style ~= 'flat' then
    return
  end
  local raw = util.read_file(path)
  if not raw then
    return
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= 'table' then
    return
  end
  local has_table = false
  for _, v in pairs(decoded) do
    if type(v) == 'table' then
      has_table = true
      break
    end
  end
  if has_table then
    vim.health.warn(
      ('%s contains nested objects but key_style is "flat" — dotted keys in code will not resolve. Add "key_style": "nested" to the project file.')
        :format(vim.fs.basename(path))
    )
  end
end

function M.check()
  vim.health.start('i18n-inline.nvim')

  local v = vim.version()
  if vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok(('Neovim %d.%d.%d'):format(v.major, v.minor, v.patch))
  else
    vim.health.error('Neovim 0.10+ is required (vim.uv API)')
  end

  -- Prefer the current buffer's project; fall back to the cwd's.
  local buf = vim.api.nvim_get_current_buf()
  local project = resolve.project_for(buf) or resolve.project_from(vim.uv.cwd() or '.')
  if not project then
    local cwd = vim.uv.cwd() or '.'
    vim.health.warn(('no translation project found from %s (check `dir` or add a %s)')
      :format(cwd, config.get().project_file))
    return
  end

  local cfg = project.cfg
  if cfg.preset then
    vim.health.ok(('preset: %s'):format(cfg.preset))
  end
  if #cfg.patterns > 0 then
    vim.health.ok(
      ('%d extraction patterns, filetypes: %s'):format(#cfg.patterns, table.concat(cfg.filetypes, ', '))
    )
  else
    vim.health.error('patterns is empty')
  end
  if cfg.source_lang then
    vim.health.ok(('source language: %s (audit: missing keys + translation gaps)'):format(cfg.source_lang))
  end

  if project.config_file then
    vim.health.ok(('project config: %s'):format(project.config_file))
    local raw = util.read_file(project.config_file)
    local ok, decoded = pcall(vim.json.decode, raw or '')
    local unknown = ok and type(decoded) == 'table' and config.unknown_keys(decoded) or {}
    if #unknown > 0 then
      vim.health.warn(('unknown options in the project file (ignored): %s'):format(table.concat(unknown, ', ')))
    end
  else
    vim.health.ok(('translation directory: %s (no %s, using setup defaults)'):format(project.dir, cfg.project_file))
  end

  local langs = resolve.sorted_langs(project)
  vim.health.ok(('languages: %s'):format(table.concat(langs, ', ')))

  -- Every file, not just preview/source: a broken one would otherwise only
  -- surface later, in the popover or the audit.
  local broken = 0
  for _, lang in ipairs(langs) do
    local ok, lerr = resolve.ensure_lang(project, lang)
    if not ok then
      broken = broken + 1
      vim.health.error(lerr or ('failed to load language "%s"'):format(lang))
    end
  end
  if broken == 0 then
    vim.health.ok(('all %d translation files parse'):format(#langs))
  end

  if project.langs[project.cfg.preview_lang] == nil then
    vim.health.error(('no file for preview_lang "%s" in %s'):format(project.cfg.preview_lang, project.dir))
    return
  end

  local keys, err = resolve.ensure_lang(project, project.cfg.preview_lang)
  if keys then
    vim.health.ok(('preview language "%s": %d keys loaded'):format(project.cfg.preview_lang, count_keys(keys)))
  else
    vim.health.error(err or ('failed to load preview language "%s"'):format(project.cfg.preview_lang))
    return
  end

  if project.cfg.source_lang then
    local src, serr = resolve.ensure_lang(project, project.cfg.source_lang)
    if src then
      vim.health.ok(('source language "%s": %d keys loaded'):format(project.cfg.source_lang, count_keys(src)))
    else
      vim.health.error(serr or ('failed to load source language "%s"'):format(project.cfg.source_lang))
    end
  end

  check_key_style(project)

  -- Sample the source tree: do the patterns find calls, and do their keys
  -- resolve? This is the G2-class detector — a namespace/pattern mismatch
  -- shows up as "keys never resolve".
  local files = sample(util.walk_files(project.root, cfg.check.extensions, cfg.check.exclude_dirs, WALK_CAP))
  if #files == 0 then
    vim.health.warn(
      ('no files matching check.extensions (%s) found under %s')
        :format(table.concat(project.cfg.check.extensions, ', '), project.root)
    )
    return
  end

  local calls, resolved, bindings_n = 0, 0, 0
  for _, path in ipairs(files) do
    local text = util.read_file(path)
    if text then
      local b = scan.extract_bindings(text, project.cfg.namespace_patterns)
      local n = 0
      for _ in pairs(b) do
        n = n + 1
      end
      bindings_n = bindings_n + n
      for _, m in ipairs(scan.scan(text, project.cfg)) do
        calls = calls + 1
        if keys[m.key] ~= nil then
          resolved = resolved + 1
        end
      end
    end
  end
  local rate = calls > 0 and math.floor(resolved / calls * 100) or 100
  local bind_msg = bindings_n > 0 and (', %d namespace bindings'):format(bindings_n) or ''
  vim.health.ok(('sampled %d files: %d calls matched%s, %d/%d resolve (%d%%)')
    :format(#files, calls, bind_msg, resolved, calls, rate))
  if calls == 0 then
    vim.health.warn(
      'patterns matched no call sites in the sample — check `patterns`/`aliases` against real calls (and filetypes vs check.extensions)'
    )
  elseif resolved == 0 then
    vim.health.warn(
      'keys matched but none resolve — likely an addressing mismatch: try "key_style": "nested", check `separator`, or namespace bindings'
    )
  end
end

return M
