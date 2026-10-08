-- :checkhealth i18n-inline
--
-- Catches the general failure modes (R6.3): missing project/dir, unparseable
-- translation files, key-addressing mismatches (nested JSON read as flat),
-- and patterns that match nothing (or whose keys never resolve) in the
-- actual source tree.

local config = require('i18n-inline.config')
local resolve = require('i18n-inline.resolve')
local scan = require('i18n-inline.scan')

local M = {}

local SAMPLE_FILES = 25

local function count_keys(keys)
  local n = 0
  for _ in pairs(keys or {}) do
    n = n + 1
  end
  return n
end

-- Walk eligible source files (by check.extensions) up to a cap.
local function sample_files(project)
  local cfg = project.cfg
  local ext_set = {}
  for _, e in ipairs(cfg.check.extensions) do
    ext_set[e:lower()] = true
  end
  local excl = {}
  for _, d in ipairs(cfg.check.exclude_dirs) do
    excl[d] = true
  end
  local files = {}
  local function walk(dir)
    if #files >= SAMPLE_FILES then
      return
    end
    local fs = vim.uv.fs_scandir(dir)
    if not fs then
      return
    end
    while true do
      local name, ftype = vim.uv.fs_scandir_next(fs)
      if not name then
        break
      end
      local path = dir .. '/' .. name
      if ftype == 'directory' then
        if not excl[name] then
          walk(path)
        end
      elseif ftype == 'file' then
        local ext = name:match('%.([%w]+)$')
        if ext and ext_set[ext:lower()] then
          files[#files + 1] = path
          if #files >= SAMPLE_FILES then
            return
          end
        end
      end
    end
  end
  walk(project.root)
  return files
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
  local fh = io.open(path, 'r')
  if not fh then
    return
  end
  local raw = fh:read('*a')
  fh:close()
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
  if v.major == 0 and v.minor >= 10 then
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
  else
    vim.health.ok(('translation directory: %s (no %s, using setup defaults)'):format(project.dir, cfg.project_file))
  end

  local langs = {}
  for lang in pairs(project.langs) do
    langs[#langs + 1] = lang
  end
  table.sort(langs)
  vim.health.ok(('languages: %s'):format(table.concat(langs, ', ')))

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
  local files = sample_files(project)
  if #files == 0 then
    vim.health.warn(
      ('no files matching check.extensions (%s) found under %s')
        :format(table.concat(project.cfg.check.extensions, ', '), project.root)
    )
    return
  end

  local calls, resolved, bindings_n = 0, 0, 0
  for _, path in ipairs(files) do
    local fh = io.open(path, 'r')
    if fh then
      local text = fh:read('*a')
      fh:close()
      local b = scan.extract_bindings(text, project.cfg.namespace_patterns)
      local n = 0
      for _ in pairs(b) do
        n = n + 1
      end
      bindings_n = bindings_n + n
      for _, m in ipairs(scan.scan(text, project.cfg)) do
        calls = calls + 1
        if keys[m.key] ~= nil and keys[m.key] ~= vim.NIL then
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
