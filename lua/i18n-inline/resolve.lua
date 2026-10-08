-- Project discovery, per-project config, and translation JSON caching.
--
-- A "project" is either:
--   - a directory tree containing the project config file (`.i18n-inline.json`),
--     or
--   - the nearest ancestor of the buffer where the configured `dir` exists.
--
-- Discovery walks up from the buffer path (or cwd). When nothing is found the
-- plugin stays silent for that buffer.

local uv = vim.uv
local config = require('i18n-inline.config')

local M = {}

-- [bufnr] = project | false (false = cached negative result)
local buf_project = {}
-- [project root] = project (shared across buffers)
local projects = {}
-- [file path] = { sig = 'mtime:size', cfg = table | err = string }
local file_cache = {}

local function normalize(p)
  return vim.fs.normalize(vim.fn.expand(p))
end

local function stat_directory(p)
  local st = uv.fs_stat(p)
  if st and st.type == 'directory' then
    return st
  end
  return nil
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
local function find_upward(base, rel)
  local cur = normalize(base)
  while cur do
    local cand = normalize(cur .. '/' .. rel)
    if uv.fs_stat(cand) then
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

-- Discover languages from `*.json` files in dir (ko.json -> "ko").
local function discover_langs(dir)
  local langs = {}
  local fs = uv.fs_scandir(dir)
  if not fs then
    return langs
  end
  while true do
    local name = uv.fs_scandir_next(fs)
    if not name then
      break
    end
    local lang = name:match('^(.+)%.json$')
    if lang and lang ~= '' then
      langs[lang] = normalize(dir .. '/' .. name)
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

  local fh = io.open(path, 'r')
  if not fh then
    local err = ('cannot open %s'):format(path)
    file_cache[path] = { sig = sig, err = err }
    return nil, err
  end
  local raw = fh:read('*a')
  fh:close()
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
      vim.notify('[i18n-inline] ' .. err, vim.log.levels.WARN)
      return nil
    end
    file_cfg = decoded
  end

  local cfg, err = config.merge_project(file_cfg or {})
  if not cfg then
    vim.notify('[i18n-inline] ' .. err, vim.log.levels.WARN)
    return nil
  end

  -- 2) translation directory
  if not cfg.dir then
    return nil
  end
  local dir
  if cfg.dir:sub(1, 1) == '/' then
    if not stat_directory(cfg.dir) then
      return nil
    end
    dir, root = normalize(cfg.dir), root or vim.fs.dirname(normalize(cfg.dir))
  else
    local dir_found, dir_root = find_upward(base_path, cfg.dir)
    if not dir_found then
      return nil
    end
    dir = dir_found
    root = root or dir_root
  end

  local project = projects[root]
  if project then
    return project
  end

  local langs
  if cfg.file_template then
    langs = {}
    for _, lang in ipairs(cfg.languages or {}) do
      langs[lang] = normalize(dir .. '/' .. cfg.file_template:format(lang))
    end
  else
    langs = discover_langs(dir)
  end

  project = {
    root = root,
    dir = dir,
    langs = langs,
    cfg = cfg,
    config_file = cfg_file,
  }
  projects[root] = project
  return project
end

-- Project for a buffer. Unnamed buffers fall back to cwd.
function M.project_for(buf)
  local cached = buf_project[buf]
  if cached ~= nil then
    return cached or nil
  end
  local base = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ''
  if base == '' then
    base = uv.cwd() or ''
  end
  base = vim.fs.dirname(normalize(base)) or normalize(base)
  local project = M.project_from(base)
  -- Cache both hits and misses; invalidated on unload or config save.
  buf_project[buf] = project or false
  return project
end

function M.forget(buf)
  buf_project[buf] = nil
end

-- Is this path a known project's translation file? (for save-triggered refresh)
function M.project_having_file(path)
  path = normalize(path)
  for _, project in pairs(projects) do
    for _, file in pairs(project.langs) do
      if file == path then
        return project
      end
    end
  end
  return nil
end

-- Load a language's key table (cached by mtime+size). Returns keys | nil, err.
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

  local fh = io.open(path, 'r')
  if not fh then
    local err = ('cannot open translation file: %s'):format(path)
    file_cache[path] = { sig = sig, err = err }
    return nil, err
  end
  local raw = fh:read('*a')
  fh:close()
  raw = raw:gsub('^\239\187\191', '') -- strip BOM

  local ok, keys = pcall(vim.json.decode, raw)
  if not ok or type(keys) ~= 'table' then
    local err = ('failed to parse JSON: %s'):format(path)
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
end

return M
