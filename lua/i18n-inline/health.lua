-- :checkhealth i18n-inline
--
-- Catches the general failure modes (R6.3): missing project/dir, catalogs
-- that match nothing, unparseable translation files, key-addressing
-- mismatches (nested JSON read as flat), patterns that match nothing (or
-- whose keys never resolve), and files whose keys only exist in a catalog
-- they don't read (a missing `uses` mapping).

local config = require('i18n-inline.config')
local resolve = require('i18n-inline.resolve')
local scan = require('i18n-inline.scan')
local util = require('i18n-inline.util')

local M = {}

-- The scan covers the whole source tree, not a sample: in a tree where few
-- files hold calls, a 25-file sample missed every call that resolves and
-- warned about key addressing (email-app: 7 of 231 files). A full
-- scan is ~0.1 ms/file; the cap and the time budget bound huge trees, and
-- the visiting order is spread (every STRIDE-th file first) so a cut
-- still samples the whole tree.
local WALK_CAP = 5000
local BUDGET_MS = 2000
local STRIDE = 8
local EXAMPLES = 3

local function spread(files)
  local out = {}
  for offset = 1, STRIDE do
    for i = offset, #files, STRIDE do
      out[#out + 1] = files[i]
    end
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
local function check_key_style(catalog)
  local cfg = catalog.cfg
  local path = catalog.langs[cfg.preview_lang]
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

-- One catalog's languages, parse status and key counts. A lone catalog
-- keeps the plain per-check lines; several get one line each plus errors.
local function check_catalog(catalog, labeled)
  local cfg = catalog.cfg
  local langs = resolve.sorted_langs(catalog)
  local broken = 0
  for _, lang in ipairs(langs) do
    local ok, lerr = resolve.ensure_lang(catalog, lang)
    if not ok then
      broken = broken + 1
      vim.health.error(lerr or ('failed to load language "%s"'):format(lang))
    end
  end

  if labeled then
    local preview = resolve.ensure_lang(catalog, cfg.preview_lang)
    local n = count_keys(preview)
    local counts = preview and ('"%s" %d %s'):format(cfg.preview_lang, n, n == 1 and 'key' or 'keys')
      or ('no "%s" file'):format(cfg.preview_lang)
    local report = catalog.langs[cfg.preview_lang] and vim.health.ok or vim.health.warn
    report(('%s: %d %s, %s'):format(catalog.label, #langs, #langs == 1 and 'language' or 'languages', counts))
    check_key_style(catalog)
    return
  end

  vim.health.ok(('languages: %s'):format(table.concat(langs, ', ')))
  if broken == 0 then
    vim.health.ok(('all %d translation files parse'):format(#langs))
  end
  if catalog.langs[cfg.preview_lang] == nil then
    vim.health.error(('no file for preview_lang "%s" in %s'):format(cfg.preview_lang, catalog.dir))
    return false
  end
  local keys, err = resolve.ensure_lang(catalog, cfg.preview_lang)
  if keys then
    vim.health.ok(('preview language "%s": %d keys loaded'):format(cfg.preview_lang, count_keys(keys)))
  else
    vim.health.error(err or ('failed to load preview language "%s"'):format(cfg.preview_lang))
    return false
  end
  if cfg.source_lang then
    local src, serr = resolve.ensure_lang(catalog, cfg.source_lang)
    if src then
      vim.health.ok(('source language "%s": %d keys loaded'):format(cfg.source_lang, count_keys(src)))
    else
      vim.health.error(serr or ('failed to load source language "%s"'):format(cfg.source_lang))
    end
  end
  check_key_style(catalog)
end

local function check_catalogs(project)
  local cfg = project.cfg
  local labeled = #project.catalogs > 1
  if labeled then
    vim.health.ok(('%d catalogs'):format(#project.catalogs))
  end
  for _, catalog in ipairs(project.catalogs) do
    if check_catalog(catalog, labeled) == false then
      return false
    end
  end
  for _, dir in ipairs(project.unmatched) do
    vim.health.warn(('catalog "%s" matches no directory under %s'):format(dir, project.root))
  end
  if #project.empty > 0 then
    vim.health.info(('skipped directories without translation files: %s'):format(table.concat(project.empty, ', ')))
  end
  for glob, targets in pairs(cfg.uses or {}) do
    for _, target in ipairs(targets) do
      local matches = util.path_glob(target)
      local hit = false
      for _, catalog in ipairs(project.catalogs) do
        hit = hit or matches(catalog.rel)
      end
      if not hit then
        vim.health.warn(('uses["%s"]: "%s" matches no catalog'):format(glob, target))
      end
    end
  end
  if labeled and resolve.preview_error({ project = project, catalogs = project.catalogs }) then
    vim.health.error(('no catalog has a file for preview_lang "%s"'):format(cfg.preview_lang))
    return false
  end
end

-- Scan the source tree: do the patterns find calls, and do their keys
-- resolve? This is the G2-class detector — a namespace/pattern mismatch
-- shows up as "keys never resolve" — and it finds files that read a
-- catalog their location doesn't imply.
local function check_calls(project)
  local cfg = project.cfg
  local walked, nested = util.walk_files(project.root, {
    extensions = cfg.check.extensions,
    exclude_dirs = cfg.check.exclude_dirs,
    project_file = cfg.project_file,
    limit = WALK_CAP,
  })
  if #nested > 0 then
    local rel = {}
    for i, dir in ipairs(nested) do
      rel[i] = util.relpath(project.root, dir) or dir
    end
    vim.health.info(('not scanned, they have their own %s: %s'):format(cfg.project_file, table.concat(rel, ', ')))
  end
  if #walked == 0 then
    vim.health.warn(
      ('no files matching check.extensions (%s) found under %s')
        :format(table.concat(cfg.check.extensions, ', '), project.root)
    )
    return
  end

  local t0 = vim.uv.hrtime()
  local memo = {}
  local s = { files = 0, with_calls = 0, calls = 0, resolved = 0, bindings = 0, elsewhere = 0, unresolved = 0 }
  local elsewhere_files, examples = {}, {}
  for _, path in ipairs(spread(walked)) do
    if (vim.uv.hrtime() - t0) / 1e6 > BUDGET_MS then
      break
    end
    s.files = s.files + 1
    local text = util.read_file(path)
    if text then
      s.bindings = s.bindings + count_keys(scan.extract_bindings(text, cfg.namespace_patterns))
      local matches = scan.scan(text, cfg)
      if #matches > 0 then
        s.with_calls = s.with_calls + 1
      end
      local view = resolve.view(project, path, memo)
      local rel = util.relpath(project.root, path) or path
      local offsets
      for _, m in ipairs(matches) do
        s.calls = s.calls + 1
        resolve.classify(view, m)
        if m.status ~= 'missing' or m.in_source then
          s.resolved = s.resolved + 1
        elseif m.elsewhere then
          s.elsewhere = s.elsewhere + 1
          elsewhere_files[rel] = (elsewhere_files[rel] or 0) + 1
        else
          s.unresolved = s.unresolved + 1
          if #examples < EXAMPLES then
            offsets = offsets or util.build_line_offsets(text)
            examples[#examples + 1] = ('%s (%s:%d)'):format(m.key, rel, util.byte_to_pos(offsets, m.call_s) + 1)
          end
        end
      end
    end
  end

  local rate = s.calls > 0 and math.floor(s.resolved / s.calls * 100) or 100
  local bind_msg = s.bindings > 0 and (', %d namespace bindings'):format(s.bindings) or ''
  vim.health.ok(('scanned %d files: %d calls in %d files%s, %d/%d resolve (%d%%)')
    :format(s.files, s.calls, s.with_calls, bind_msg, s.resolved, s.calls, rate))
  if s.files < #walked then
    vim.health.info(('stopped after %d ms: scanned %d of %d files'):format(BUDGET_MS, s.files, #walked))
  end

  if s.calls == 0 then
    vim.health.warn(
      'patterns matched no call sites — check `patterns`/`aliases` against real calls (and filetypes vs check.extensions)'
    )
    return
  end
  if s.elsewhere > 0 then
    local list = {}
    for rel, n in pairs(elsewhere_files) do
      list[#list + 1] = { rel, n }
    end
    table.sort(list, function(a, b)
      return a[2] ~= b[2] and a[2] > b[2] or a[1] < b[1]
    end)
    local shown = {}
    for i = 1, math.min(#list, EXAMPLES) do
      shown[i] = ('%s (%d)'):format(list[i][1], list[i][2])
    end
    vim.health.warn(
      ('%s keys found only in catalogs their file doesn\'t read: %s%s — a file that gets its messages from those catalogs at runtime (props, a shared component) needs a `uses` entry; otherwise the key is missing from its own catalog')
        :format(s.elsewhere == 1 and '1 call uses' or (s.elsewhere .. ' calls use'), table.concat(shown, ', '), #list > EXAMPLES and ', …' or '')
    )
  end
  if s.resolved == 0 and s.elsewhere == 0 then
    vim.health.warn(
      ('keys matched but none resolve (e.g. %s) — likely an addressing mismatch: try "key_style": "nested", check `separator`, or namespace bindings')
        :format(table.concat(examples, ', '))
    )
  elseif s.unresolved > 0 then
    vim.health.info(('%s keys no catalog has, e.g. %s (the audit lists them all)')
      :format(s.unresolved == 1 and '1 call uses' or (s.unresolved .. ' calls use'), table.concat(examples, ', ')))
    if #nested > 0 then
      -- lookups never cross projects: a shared file can't see the nested ones'
      vim.health.info(
        ('keys are not looked up in the nested projects\' catalogs; to share them, list every catalog in this %s (`catalogs`) and drop the nested files')
          :format(cfg.project_file)
      )
    end
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
  if not require('i18n-inline').is_setup() then
    vim.health.warn('setup() has not run: no inline previews (the commands still work). Call require("i18n-inline").setup() or use `opts` with lazy.nvim')
  end

  -- Prefer the current buffer's project; fall back to the cwd's.
  local buf = vim.api.nvim_get_current_buf()
  local project = resolve.project_for(buf) or resolve.project_from(vim.uv.cwd() or '.')
  if not project then
    local cwd = vim.uv.cwd() or '.'
    vim.health.warn(('no translation project found from %s (check `dir`/`catalogs` or add a %s)')
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
    vim.health.ok(('translation directory: %s (no %s, using setup defaults)')
      :format(project.catalogs[1].dir, cfg.project_file))
  end

  if check_catalogs(project) == false then
    return
  end
  check_calls(project)
end

return M
