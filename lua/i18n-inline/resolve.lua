-- Project discovery, per-project config, and translation file caching.
--
-- A "project" is either:
--   - a directory tree containing the project config file (`.i18n-inline.json`);
--     a relative `dir` is then resolved against that file's directory, or
--   - without a project file, the nearest ancestor of the buffer where the
--     configured `dir` exists as a directory.
--
-- Discovery walks up from the buffer path (or cwd). When nothing is found the
-- plugin stays silent for that buffer.

local uv = vim.uv
local config = require('i18n-inline.config')
local formats = require('i18n-inline.formats')
local util = require('i18n-inline.util')

local M = {}

-- [bufnr] = project | false (false = cached negative result)
local buf_project = {}
-- [project root] = project (shared across buffers)
local projects = {}
-- [file path] = { sig = 'mtime:size', cfg = table | err = string }
local file_cache = {}
-- Project-file problems already reported (keyed by path + signature +
-- message), so a broken file warns once per edit, not once per buffer.
local warned = {}

local normalize = util.abspath

local function is_directory(p)
  local st = uv.fs_stat(p)
  return st ~= nil and st.type == 'directory'
end

local function file_sig(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil
  end
  return ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
end

-- Walk up from `base` looking for `rel` (a file or directory).
-- Returns the absolute path of the match and its parent (the project root).
-- Note: vim.fs.dirname('/') returns '/', so the loop needs an explicit stop.
local function find_upward(base, rel, want_dir)
  local cur = normalize(base)
  while cur do
    local cand = normalize(cur .. '/' .. rel)
    local st = uv.fs_stat(cand)
    if st and (not want_dir or st.type == 'directory') then
      return cand, cur
    end
    local parent = vim.fs.dirname(cur)
    if not parent or parent == cur then
      break
    end
    cur = parent
  end
  return nil
end

-- Discover languages from translation files in dir (ko.json / ko.po -> "ko").
-- `only` (the `languages` option) restricts the result when given.
local function discover_langs(dir, only)
  local allowed
  if only then
    allowed = {}
    for _, l in ipairs(only) do
      allowed[l] = true
    end
  end
  local langs = {}
  local fs = uv.fs_scandir(dir)
  if not fs then
    return langs
  end
  while true do
    local name, ftype = uv.fs_scandir_next(fs)
    if not name then
      break
    end
    if ftype == 'file' then
      local lang = name:match('^(.+)%.[%w]+$')
      -- only extensions a registered format claims (json, po, …)
      if lang and lang ~= '' and (not allowed or allowed[lang]) and formats.for_path(name, {}) then
        langs[lang] = normalize(dir .. '/' .. name)
      end
    end
  end
  return langs
end

-- Read and cache the per-project config file. Returns table | nil, err.
local function read_project_file(path)
  local sig = file_sig(path)
  if not sig then
    return nil, ('cannot stat %s'):format(path)
  end
  local cached = file_cache[path]
  if cached and cached.sig == sig then
    if cached.err then
      return nil, cached.err
    end
    return cached.cfg
  end

  local raw = util.read_file(path)
  if not raw then
    local err = ('cannot open %s'):format(path)
    file_cache[path] = { sig = sig, err = err }
    return nil, err
  end
  raw = raw:gsub('^\239\187\191', '') -- strip BOM

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= 'table' then
    local err = ('invalid JSON in %s'):format(path)
    file_cache[path] = { sig = sig, err = err }
    return nil, err
  end
  file_cache[path] = { sig = sig, cfg = decoded }
  return decoded
end

local function warn_once(path, msg, level)
  local id = path .. '\0' .. (file_sig(path) or '') .. '\0' .. msg
  if not warned[id] then
    warned[id] = true
    util.notify(msg, level or vim.log.levels.WARN)
  end
end

-- Resolve the project for a base directory. Returns project | nil.
-- A project table: { root, dir, langs = {lang = path}, cfg, config_file? }
function M.project_from(base_path)
  local global_cfg = config.get()

  -- 1) nearest project config file
  local cfg_file, root = find_upward(base_path, global_cfg.project_file)
  local file_cfg
  if cfg_file then
    local decoded, err = read_project_file(cfg_file)
    if not decoded then
      warn_once(cfg_file, err)
      return nil
    end
    file_cfg = decoded
  end

  local cfg, err = config.merge_project(file_cfg or {})
  if not cfg then
    warn_once(cfg_file or '', ('%s: %s'):format(cfg_file or 'setup()', err))
    return nil
  end
  if cfg_file then
    local unknown = config.unknown_keys(file_cfg)
    if #unknown > 0 then
      warn_once(cfg_file, ('%s: unknown options ignored: %s'):format(cfg_file, table.concat(unknown, ', ')))
    end
  end

  -- 2) translation directory: absolute; relative to the project file's
  -- directory; or (no project file) the nearest ancestor that has it.
  if not cfg.dir then
    return nil
  end
  local dir
  if cfg.dir:sub(1, 1) == '/' or cfg.dir:sub(1, 1) == '~' then
    dir = normalize(cfg.dir)
    if not is_directory(dir) then
      return nil
    end
    root = root or vim.fs.dirname(dir)
  elseif root then
    dir = normalize(root .. '/' .. cfg.dir)
    if not is_directory(dir) then
      return nil
    end
  else
    dir, root = find_upward(base_path, cfg.dir, true)
    if not dir then
      return nil
    end
  end

  local project = projects[root]
  if project then
    return project
  end

  project = {
    root = root,
    dir = dir,
    cfg = cfg,
    config_file = cfg_file,
  }
  M.rediscover(project)
  projects[root] = project
  return project
end

-- (Re)build project.langs: from file_template + languages, or by scanning
-- the directory (restricted to `languages` when given).
function M.rediscover(project)
  local cfg = project.cfg
  if cfg.file_template then
    project.langs = {}
    for _, lang in ipairs(cfg.languages or {}) do
      project.langs[lang] = normalize(project.dir .. '/' .. cfg.file_template:format(lang))
    end
  else
    project.langs = discover_langs(project.dir, cfg.languages)
  end
end

-- Language codes ordered for display: preview language first, then the
-- source language, then alphabetical.
function M.sorted_langs(project)
  local cfg = project.cfg
  local rank = function(l)
    return l == cfg.preview_lang and 0 or (l == cfg.source_lang and 1 or 2)
  end
  local langs = vim.tbl_keys(project.langs)
  table.sort(langs, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then
      return ra < rb
    end
    return a < b
  end)
  return langs
end

-- The value of `key` in `lang`, or nil (missing key or unreadable file).
function M.value(project, lang, key)
  local keys = M.ensure_lang(project, lang)
  return keys and keys[key]
end

-- Project for a buffer. Unnamed buffers start the search at cwd.
function M.project_for(buf)
  local cached = buf_project[buf]
  if cached ~= nil then
    return cached or nil
  end
  local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ''
  local base
  if name == '' then
    base = normalize(uv.cwd() or '.')
  else
    base = vim.fs.dirname(normalize(name))
  end
  local project = M.project_from(base)
  -- Cache both hits and misses; invalidated on unload or config save.
  buf_project[buf] = project or false
  return project
end

function M.forget(buf)
  buf_project[buf] = nil
end

-- The project whose translation file `path` is (for save-triggered
-- refresh). A translation-format file saved directly in a project's
-- directory that is not yet known (a newly added language) triggers
-- re-discovery first.
function M.project_having_file(path)
  path = normalize(path)
  for _, project in pairs(projects) do
    for _, file in pairs(project.langs) do
      if file == path then
        return project
      end
    end
  end
  local parent = vim.fs.dirname(path)
  for _, project in pairs(projects) do
    if parent == project.dir and not project.cfg.file_template and formats.for_path(path, {}) then
      M.rediscover(project)
      for _, file in pairs(project.langs) do
        if file == path then
          return project
        end
      end
    end
  end
  return nil
end

-- Load a language's key table (cached by mtime+size). The key table is the
-- format decoder's output: always a flat key -> string map (nested JSON is
-- flattened at decode time). Returns keys | nil, err.
function M.ensure_lang(project, lang)
  local path = project.langs[lang]
  if not path then
    return nil, ('no translation file for language "%s" (dir: %s)'):format(lang, project.dir)
  end

  local sig = file_sig(path)
  if not sig then
    return nil, ('translation file not found: %s'):format(path)
  end
  local cached = file_cache[path]
  if cached and cached.sig == sig then
    if cached.err then
      return nil, cached.err
    end
    return cached.cfg
  end

  local fmt = formats.for_path(path, project.cfg)
  if not fmt then
    local ext = path:match('%.([%w]+)$') or '(none)'
    local err = ('no parser for .%s files: %s (set "format" or use %s)')
      :format(ext, path, table.concat(formats.names(), '/'))
    file_cache[path] = { sig = sig, err = err }
    return nil, err
  end

  local raw = util.read_file(path)
  if not raw then
    local err = ('cannot open translation file: %s'):format(path)
    file_cache[path] = { sig = sig, err = err }
    return nil, err
  end
  raw = raw:gsub('^\239\187\191', '') -- strip BOM

  -- decoders report bad input as (nil, msg); pcall catches the unexpected
  local ok, keys, derr = pcall(fmt.decode, raw, project.cfg)
  if not ok or type(keys) ~= 'table' then
    local err = ('failed to parse %s: %s'):format(path, ok and (derr or 'no entries') or tostring(keys))
    file_cache[path] = { sig = sig, err = err }
    return nil, err
  end
  file_cache[path] = { sig = sig, cfg = keys }
  return keys
end

-- Drop cached data for one file (called right after it is saved).
function M.invalidate_path(path)
  file_cache[normalize(path)] = nil
end

-- Full reset (config file saved, or tests).
function M.reset()
  buf_project = {}
  projects = {}
  file_cache = {}
  warned = {}
end

return M
