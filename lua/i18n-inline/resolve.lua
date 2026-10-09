-- Project discovery, per-project config, catalogs, key lookup and
-- translation file caching.
--
-- A "project" is either:
--   - a directory tree containing the project config file (`.i18n-inline.json`);
--     relative catalog dirs are then resolved against that file's directory, or
--   - without a project file, the nearest ancestor of the buffer where the
--     configured `dir` (the first catalog's) exists as a directory.
--
-- A project holds one or more catalogs: a translation directory with one
-- file per language (`dir` is the one-catalog spelling of `catalogs`). A `*`
-- in a catalog dir matches one directory level; a directory named exactly
-- by one entry is never taken by another entry's wildcard.
--
-- Which catalogs a source file reads (catalogs_for), in lookup order:
--   1. the catalogs `uses` maps it to, when a `uses` glob covers the file;
--   2. else the catalog(s) whose home holds the file, deepest home first.
--      A home starts at the catalog directory's parent and climbs while the
--      level above holds no other catalog: src/emails/order/messages serves
--      src/emails/order/, apps/admin/public/locales serves apps/admin/. A
--      lone catalog serves the whole project;
--   3. else every catalog, in the order they are declared.
-- A key those catalogs lack is also looked up in the project's other
-- catalogs, so a call can read "only in <catalog>" instead of "not found":
-- code and audit can then tell a missing mapping from a missing key.
--
-- Discovery walks up from the buffer path (or cwd). When nothing is found the
-- plugin stays silent for that buffer.

local uv = vim.uv
local config = require('i18n-inline.config')
local formats = require('i18n-inline.formats')
local scan = require('i18n-inline.scan')
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

-- Options a catalog entry can set for itself; the top-level values are
-- every entry's defaults.
local CATALOG_OPTS = { 'languages', 'file_template', 'format', 'key_style' }

local function is_directory(p)
  local st = uv.fs_stat(p)
  return st ~= nil and st.type == 'directory'
end

local function is_absolute(p)
  return p:sub(1, 1) == '/' or p:sub(1, 1) == '~'
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
  local allowed = only and util.set(only)
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
    if util.is_file(dir .. '/' .. name, ftype) then
      local lang = name:match('^(.+)%.[%w]+$')
      -- only extensions a registered format claims (json, po, …)
      if lang and lang ~= '' and (not allowed or allowed[lang]) and formats.for_path(name, {}) then
        langs[lang] = normalize(dir .. '/' .. name)
      end
    end
  end
  return langs
end

-- Literal template text -> Lua pattern source ('%%' in a template is a
-- literal percent sign).
local function template_literal(s)
  return util.pattern_escape((s:gsub('%%%%', '%%')))
end

-- Discover languages from the files a file_template matches
-- (`footer-%s.json`, `app_%s.arb`, `%s/LC_MESSAGES/messages.po`): the
-- segment holding %s is matched against its parent directory's entries.
local function discover_template_langs(dir, template, only)
  local segs = vim.split(template, '/', { plain = true, trimempty = true })
  local at
  for i, seg in ipairs(segs) do
    if seg:find('%%s') then
      at = i
      break
    end
  end
  local langs = {}
  if not at then
    return langs
  end
  local parent = dir
  for i = 1, at - 1 do
    parent = parent .. '/' .. segs[i]
  end
  local before, after = segs[at]:match('^(.-)%%s(.*)$')
  local pat = '^' .. template_literal(before) .. '(.+)' .. template_literal(after) .. '$'
  local rest = table.concat(segs, '/', at + 1)
  local allowed = only and util.set(only)
  local fs = uv.fs_scandir(parent)
  while fs do
    local name, ftype = uv.fs_scandir_next(fs)
    if not name then
      break
    end
    local lang = name:match(pat)
    if lang and (not allowed or allowed[lang]) then
      local path = parent .. '/' .. name .. (rest == '' and '' or '/' .. rest)
      if util.is_file(path, rest == '' and ftype or nil) then
        langs[lang] = normalize(path)
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

-- Catalog entries as tables, from `catalogs` or the `dir` shorthand.
local function catalog_entries(cfg)
  local list = cfg.catalogs or (cfg.dir and { cfg.dir }) or {}
  local out = {}
  for i, entry in ipairs(list) do
    out[i] = type(entry) == 'string' and { dir = entry } or entry
  end
  return out
end

-- The literal leading part of a catalog dir (segments before the first
-- wildcard): what a setup-only config can walk up to.
local function literal_prefix(dir)
  local out = {}
  for seg in dir:gmatch('[^/]+') do
    if util.has_wildcard(seg) then
      break
    end
    out[#out + 1] = seg
  end
  return (dir:sub(1, 1) == '/' and '/' or '') .. table.concat(out, '/')
end

-- Directories matching `dir` (relative to `root` unless absolute), sorted.
-- Wildcard segments skip hidden directories (unless the segment itself
-- starts with '.') and the exclude_dirs names.
local function expand_dir(root, dir, skip)
  local abs = is_absolute(dir)
  local found = { abs and '' or root }
  for seg in (abs and vim.fs.normalize(dir) or dir):gmatch('[^/]+') do
    local nxt = {}
    if util.has_wildcard(seg) then
      local pat = util.segment_pattern(seg)
      local hidden = seg:sub(1, 1) == '.'
      for _, d in ipairs(found) do
        local fs = uv.fs_scandir(d == '' and '/' or d)
        while fs do
          local name, ftype = uv.fs_scandir_next(fs)
          if not name then
            break
          end
          local path = d .. '/' .. name
          if
            name:find(pat)
            and (hidden or name:sub(1, 1) ~= '.')
            and not skip[name]
            and (ftype == 'directory' or (ftype == 'link' and is_directory(path)))
          then
            nxt[#nxt + 1] = path
          end
        end
      end
      table.sort(nxt)
    else
      for _, d in ipairs(found) do
        if is_directory(d .. '/' .. seg) then
          nxt[#nxt + 1] = d .. '/' .. seg
        end
      end
    end
    found = nxt
  end
  for i, d in ipairs(found) do
    found[i] = normalize(d == '' and '/' or d)
  end
  return found
end

-- (Re)build catalog.langs: from file_template + languages, from the files
-- file_template matches, or by scanning the directory (restricted to
-- `languages` when given).
function M.rediscover(catalog)
  local cfg = catalog.cfg
  if cfg.file_template and cfg.languages then
    catalog.langs = {}
    for _, lang in ipairs(cfg.languages) do
      catalog.langs[lang] = normalize(catalog.dir .. '/' .. cfg.file_template:format(lang))
    end
  elseif cfg.file_template then
    catalog.langs = discover_template_langs(catalog.dir, cfg.file_template)
  else
    catalog.langs = discover_langs(catalog.dir, cfg.languages)
  end
end

local function new_catalog(project, entry, dir, wildcard)
  -- a catalog reads its files with its own options over the project's
  local cfg = {}
  for k, v in pairs(project.cfg) do
    cfg[k] = v
  end
  for _, opt in ipairs(CATALOG_OPTS) do
    if entry[opt] ~= nil then
      cfg[opt] = entry[opt]
    end
  end
  local catalog = {
    dir = dir,
    rel = util.relpath(project.root, dir) or dir,
    cfg = cfg,
    wildcard = wildcard,
  }
  M.rediscover(catalog)
  return catalog
end

-- Does `dir` hold (or equal) another catalog's directory than `catalog`'s?
local function holds_other(project, dir, catalog)
  for _, other in ipairs(project.catalogs) do
    if other ~= catalog and util.relpath(dir, other.dir) then
      return true
    end
  end
  return false
end

local function assign_homes(project)
  local root = project.root
  for _, catalog in ipairs(project.catalogs) do
    if #project.catalogs == 1 or catalog.dir == root then
      catalog.home = root
    elseif not util.relpath(root, catalog.dir) then
      catalog.home = nil -- outside the project: reached via `uses` or the fallback
    else
      local home = vim.fs.dirname(catalog.dir)
      while home ~= root do
        local up = vim.fs.dirname(home)
        if not util.relpath(root, up) or holds_other(project, up, catalog) then
          break
        end
        home = up
      end
      catalog.home = home
    end
  end
end

-- Short display names: the fewest trailing path segments that tell the
-- catalogs apart (order/messages, weekly_report/messages), plus the file
-- template when two catalogs share a directory.
local function assign_labels(project)
  local catalogs = project.catalogs
  for _, catalog in ipairs(catalogs) do
    local segs = vim.split(catalog.rel, '/', { plain = true, trimempty = true })
    catalog.label = catalog.rel
    for n = 1, #segs do
      local suffix = table.concat(segs, '/', #segs - n + 1)
      local unique = true
      for _, other in ipairs(catalogs) do
        if other ~= catalog and (other.rel == suffix or vim.endswith(other.rel, '/' .. suffix)) then
          unique = false
          break
        end
      end
      if unique then
        catalog.label = suffix
        break
      end
    end
    for _, other in ipairs(catalogs) do
      if other ~= catalog and other.dir == catalog.dir and catalog.cfg.file_template then
        catalog.label = ('%s (%s)'):format(catalog.label, catalog.cfg.file_template)
        break
      end
    end
  end
end

-- `uses` compiled: { { covers = fn(rel path), targets = { fn(catalog rel) } } }
local function compile_uses(uses)
  local out = {}
  for glob, targets in pairs(uses or {}) do
    local rule = { covers = util.path_glob(glob), targets = {} }
    for i, target in ipairs(targets) do
      rule.targets[i] = util.path_glob(target)
    end
    out[#out + 1] = rule
  end
  return out
end

-- (Re)build project.catalogs from the configured entries. Entries that
-- match no directory land in project.unmatched, wildcard matches without
-- translation files in project.empty (both reported by :checkhealth).
function M.load_catalogs(project)
  local cfg, root = project.cfg, project.root
  local skip = {}
  for _, d in ipairs(cfg.check.exclude_dirs or {}) do
    skip[d] = true
  end
  local entries = catalog_entries(cfg)
  local matches, named = {}, {}
  for i, entry in ipairs(entries) do
    matches[i] = expand_dir(root, entry.dir, skip)
    if not util.has_wildcard(entry.dir) then
      for _, d in ipairs(matches[i]) do
        named[d] = true
      end
    end
  end

  project.catalogs, project.unmatched, project.empty = {}, {}, {}
  local taken = {} -- dir (+ template) -> true
  for i, entry in ipairs(entries) do
    local wildcard = util.has_wildcard(entry.dir)
    local n = 0
    for _, d in ipairs(matches[i]) do
      local id = d .. '\0' .. (entry.file_template or cfg.file_template or '')
      if not taken[id] and not (wildcard and (named[d] or taken[d])) then
        taken[id], taken[d] = true, true
        local catalog = new_catalog(project, entry, d, wildcard)
        if wildcard and next(catalog.langs) == nil then
          project.empty[#project.empty + 1] = catalog.rel
        else
          project.catalogs[#project.catalogs + 1] = catalog
          n = n + 1
        end
      end
    end
    if n == 0 and #matches[i] == 0 then
      project.unmatched[#project.unmatched + 1] = entry.dir
    end
  end
  assign_homes(project)
  assign_labels(project)
  project.uses = compile_uses(cfg.uses)
  project.cands = {}
end

-- Resolve the project for a base directory. Returns project | nil.
-- A project table: { root, cfg, catalogs = { catalog… }, config_file?,
-- uses, unmatched, empty }; a catalog: { dir, rel, label, home, cfg,
-- langs = { lang = path }, wildcard }.
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

  -- 2) the root catalog dirs resolve against: the project file's directory;
  -- without one, the parent of an absolute first catalog, or the nearest
  -- ancestor that holds the first catalog's directory.
  local entries = catalog_entries(cfg)
  if #entries == 0 then
    return nil
  end
  if not root then
    local first = literal_prefix(entries[1].dir)
    if is_absolute(first) then
      root = vim.fs.dirname(normalize(first))
    elseif first ~= '' then
      local _
      _, root = find_upward(base_path, first, true)
    end
    if not root then
      return nil
    end
  end

  local project = projects[root]
  if project then
    return project
  end

  project = {
    root = root,
    cfg = cfg,
    config_file = cfg_file,
  }
  M.load_catalogs(project)
  if #project.catalogs == 0 then
    return nil
  end
  projects[root] = project
  return project
end

-- Language codes ordered for display: preview language first, then the
-- source language, then alphabetical. Takes a catalog (anything with
-- `cfg` and `langs`).
function M.sorted_langs(catalog)
  local cfg = catalog.cfg
  local rank = function(l)
    return l == cfg.preview_lang and 0 or (l == cfg.source_lang and 1 or 2)
  end
  local langs = vim.tbl_keys(catalog.langs)
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
function M.value(catalog, lang, key)
  local keys = M.ensure_lang(catalog, lang)
  return keys and keys[key]
end

-- Does `rule` cover root-relative path `rel`? A glob naming a directory
-- covers everything under it.
local function covers(rule, rel)
  local path = rel
  while path ~= '' do
    if rule.covers(path) then
      return true
    end
    path = path:match('^(.*)/[^/]*$') or ''
  end
  return false
end

-- The catalogs source file `path` reads, in lookup order (see the header).
-- Cached per path until the catalogs are rebuilt.
function M.catalogs_for(project, path)
  local cached = project.cands[path]
  if cached then
    return cached
  end
  local rel = util.relpath(project.root, path)
  local found = {}

  if rel and #project.uses > 0 then
    local picked = {}
    for _, rule in ipairs(project.uses) do
      if covers(rule, rel) then
        for _, catalog in ipairs(project.catalogs) do
          for _, target in ipairs(rule.targets) do
            if target(catalog.rel) then
              picked[catalog] = true
            end
          end
        end
      end
    end
    for _, catalog in ipairs(project.catalogs) do
      if picked[catalog] then
        found[#found + 1] = catalog
      end
    end
  end

  if #found == 0 then
    local depth = -1
    for _, catalog in ipairs(project.catalogs) do
      if catalog.home and util.relpath(catalog.home, path) then
        if #catalog.home > depth then
          found, depth = { catalog }, #catalog.home
        elseif #catalog.home == depth then
          found[#found + 1] = catalog
        end
      end
    end
  end

  if #found == 0 then
    found = project.catalogs
  end
  project.cands[path] = found
  return found
end

-- A lookup context for one source file: the catalogs it reads, the rest of
-- the project's, and a memo of key tables for one pass (a refresh, an
-- audit) so lookups cost a table index, not a stat per key. Pass the same
-- `memo` to views of one pass to share it.
function M.view(project, path, memo)
  local mine, others = {}, {}
  local catalogs = M.catalogs_for(project, path)
  for _, catalog in ipairs(catalogs) do
    mine[catalog] = true
  end
  for _, catalog in ipairs(project.catalogs) do
    if not mine[catalog] then
      others[#others + 1] = catalog
    end
  end
  return { project = project, catalogs = catalogs, others = others, memo = memo or {} }
end

-- Key table of `catalog` in `lang` through the view's memo, or nil.
function M.keys(view, catalog, lang)
  local per = view.memo[catalog]
  if not per then
    per = {}
    view.memo[catalog] = per
  end
  local keys = per[lang]
  if keys == nil then
    keys = M.ensure_lang(catalog, lang) or false
    per[lang] = keys
  end
  return keys or nil
end

-- Look `key` up for a view. Returns, when the preview language has it:
--   value, catalog
-- otherwise:
--   nil, catalog (its source language has the key: a translation gap) | nil,
--   in_source, elsewhere (the other catalogs that have the key)
function M.find(view, key)
  local cfg = view.project.cfg
  local preview, source = cfg.preview_lang, cfg.source_lang
  if source == preview then
    source = nil
  end
  for _, catalog in ipairs(view.catalogs) do
    local keys = M.keys(view, catalog, preview)
    if keys and keys[key] ~= nil then
      return keys[key], catalog
    end
  end
  if source then
    for _, catalog in ipairs(view.catalogs) do
      local keys = M.keys(view, catalog, source)
      if keys and keys[key] ~= nil then
        return nil, catalog, true
      end
    end
  end
  local elsewhere = {}
  for _, catalog in ipairs(view.others) do
    local p = M.keys(view, catalog, preview)
    local s = source and M.keys(view, catalog, source)
    if (p and p[key] ~= nil) or (s and s[key] ~= nil) then
      elsewhere[#elsewhere + 1] = catalog
    end
  end
  return nil, nil, false, elsewhere
end

-- Classify a scan match for a view: sets m.status ('match' | 'mismatch' |
-- 'missing' | 'novalue'), m.value, m.catalog (where the key was found),
-- m.in_source and m.elsewhere (non-empty list or nil).
function M.classify(view, m)
  local value, catalog, in_source, elsewhere = M.find(view, m.key)
  m.catalog = catalog
  m.in_source = in_source or nil
  m.elsewhere = elsewhere and #elsewhere > 0 and elsewhere or nil
  if value == nil then
    m.status, m.value = 'missing', nil
  else
    m.status, m.value = scan.compare(m, value, view.project.cfg)
  end
end

-- The catalogs to show a classified match from (popover, :I18nJump!): the
-- file's catalogs that have the key in any language, else the catalogs the
-- key is only in, else the file's first catalog.
function M.holders(view, m)
  local out = {}
  for _, catalog in ipairs(view.catalogs) do
    for lang in pairs(catalog.langs) do
      local keys = M.keys(view, catalog, lang)
      if keys and keys[m.key] ~= nil then
        out[#out + 1] = catalog
        break
      end
    end
  end
  if #out == 0 then
    out = m.elsewhere or { view.catalogs[1] }
  end
  return out
end

-- nil when some catalog of the view loads the preview language, else the
-- first error (nothing can render without it).
function M.preview_error(view)
  local lang = view.project.cfg.preview_lang
  local first
  for _, catalog in ipairs(view.catalogs) do
    local keys, err = M.ensure_lang(catalog, lang)
    if keys then
      if view.memo then
        view.memo[catalog] = view.memo[catalog] or {}
        view.memo[catalog][lang] = keys
      end
      return nil
    end
    first = first or err
  end
  return first or 'no catalogs'
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

-- The source path a buffer's lookups go by: its name, or cwd when unnamed.
function M.buf_path(buf)
  local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ''
  return normalize(name ~= '' and name or (uv.cwd() or '.'))
end

function M.forget(buf)
  buf_project[buf] = nil
end

local function project_with_file(path)
  for _, project in pairs(projects) do
    for _, catalog in ipairs(project.catalogs) do
      for _, file in pairs(catalog.langs) do
        if file == path then
          return project
        end
      end
    end
  end
  return nil
end

-- The project whose translation file `path` is (for save-triggered
-- refresh). A translation-format file saved under a catalog directory that
-- is not known yet (a newly added language) re-discovers that catalog; one
-- saved elsewhere in a project with wildcard catalogs re-expands them (a
-- newly added catalog directory).
function M.project_having_file(path)
  path = normalize(path)
  local project = project_with_file(path)
  if project or not formats.for_path(path, {}) then
    return project
  end
  for _, p in pairs(projects) do
    if util.relpath(p.root, path) then
      local rediscovered = false
      for _, catalog in ipairs(p.catalogs) do
        if util.relpath(catalog.dir, path) then
          M.rediscover(catalog)
          rediscovered = true
        end
      end
      if not rediscovered then
        for _, entry in ipairs(catalog_entries(p.cfg)) do
          if util.has_wildcard(entry.dir) then
            M.load_catalogs(p)
            break
          end
        end
      end
    end
  end
  return project_with_file(path)
end

-- Load a language's key table (cached by mtime+size). The key table is the
-- format decoder's output: always a flat key -> string map (nested JSON is
-- flattened at decode time). Returns keys | nil, err.
function M.ensure_lang(catalog, lang)
  local path = catalog.langs[lang]
  if not path then
    return nil, ('no translation file for language "%s" (dir: %s)'):format(lang, catalog.dir)
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

  local fmt = formats.for_path(path, catalog.cfg)
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
  local ok, keys, derr = pcall(fmt.decode, raw, catalog.cfg)
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
