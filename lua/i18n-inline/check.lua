-- :I18nCheck — audit the project for drift. Results land in the quickfix
-- list. Files are processed in batches on the event loop so the UI stays
-- responsive on large repositories.
--
-- Three findings:
--   mismatch — code fallback disagrees with the preview language value
--   missing  — a call's key is absent from the preview language (and from
--              the source language, when configured) of every catalog the
--              file reads; a key that another catalog of the project has
--              says so ("only in <catalog>"), since that is usually a file
--              reading a catalog its location doesn't imply (see `uses`)
--   gap      — key present in a catalog's source language but missing from
--              another language's file (source_lang audit, R5.3)
-- Plus a summary echo of unused keys per catalog (not referenced by any
-- scanned call that reads it).
--
-- check.ignore globs (R5.2) silence every finding about a key's absence:
-- missing keys, gaps and unused keys. Mismatches compare two values that
-- both exist, so they are always reported.
--
-- The audit covers the project root minus check.exclude_dirs and minus any
-- subtree with its own project file (another project's).

local api = vim.api
local scan = require('i18n-inline.scan')
local util = require('i18n-inline.util')
local resolve = require('i18n-inline.resolve')

local M = {}

local generation = 0
local BATCH = 40

local function progress(msg)
  api.nvim_echo({ { msg, 'Comment' } }, false, {})
end

-- Glob (only * and ? special) -> anchored Lua pattern. Magic characters
-- are escaped with '%' (Lua pattern syntax — vim.fn.escape's backslashes
-- would be wrong here); * and ? stay for the wildcard pass.
local function glob_to_pattern(glob)
  local escaped = glob:gsub('[%^%$%(%)%%%.%[%]%+%-%_#]', '%%%0')
  escaped = escaped:gsub('%*', '.*'):gsub('%?', '.')
  return '^' .. escaped .. '$'
end

M.glob_to_pattern = glob_to_pattern

local function compile_ignores(globs)
  local pats = {}
  for _, g in ipairs(globs or {}) do
    pats[#pats + 1] = glob_to_pattern(g)
  end
  return function(key)
    for _, p in ipairs(pats) do
      if key:find(p) then
        return true
      end
    end
    return false
  end
end

M.compile_ignores = compile_ignores

local function labels(catalogs)
  local out = {}
  for i, catalog in ipairs(catalogs) do
    out[i] = catalog.label
  end
  return table.concat(out, ', ')
end

-- Quickfix text for a missing key.
local function missing_text(m, cfg, view)
  if m.in_source then
    return ('missing in %s :%s — present in %s'):format(cfg.preview_lang, m.key, cfg.source_lang)
  elseif m.elsewhere then
    return ('missing key :%s — only in %s; this file reads %s'):format(m.key, labels(m.elsewhere), labels(view.catalogs))
  elseif m.fb then
    return ('missing key :%s — fallback %s'):format(m.key, util.quote(m.fb))
  end
  return ('missing key :%s'):format(m.key)
end

-- Cross-language audit against the source language (R5.3): every key a
-- catalog's source owns must exist in each of its other language files.
local function lang_gaps(catalog, ignored, items, unreadable)
  local src = catalog.cfg.source_lang
  if not src or not catalog.langs[src] then
    return
  end
  local src_keys = resolve.ensure_lang(catalog, src)
  if not src_keys then
    unreadable[#unreadable + 1] = { catalog, src }
    return
  end
  local src_sorted = vim.tbl_keys(src_keys)
  table.sort(src_sorted)
  for _, lang in ipairs(resolve.sorted_langs(catalog)) do
    if lang ~= src then
      local keys = resolve.ensure_lang(catalog, lang)
      if not keys then
        unreadable[#unreadable + 1] = { catalog, lang }
      else
        for _, k in ipairs(src_sorted) do
          if keys[k] == nil and not ignored(k) then
            items[#items + 1] = {
              filename = catalog.langs[lang],
              lnum = 1, -- keep filename intact in quickfix (no line to point at)
              text = ('missing key :%s — present in %s'):format(k, src),
              _kind = 'gap',
            }
          end
        end
      end
    end
  end
end

-- Keys of each catalog no scanned call reads, against the source language
-- (it owns the key set) or else the preview language. Returns
-- { { catalog, lang, keys = sorted list } } for catalogs with any.
local function unused_keys(project, used, ignored)
  local cfg = project.cfg
  local out = {}
  for _, catalog in ipairs(project.catalogs) do
    local lang = cfg.source_lang and catalog.langs[cfg.source_lang] and cfg.source_lang or cfg.preview_lang
    local keys = resolve.ensure_lang(catalog, lang)
    if not keys and lang ~= cfg.preview_lang then
      lang = cfg.preview_lang
      keys = resolve.ensure_lang(catalog, lang)
    end
    local list = {}
    local seen = used[catalog] or {}
    for k in pairs(keys or {}) do
      if not seen[k] and not ignored(k) then
        list[#list + 1] = k
      end
    end
    if #list > 0 then
      table.sort(list)
      out[#out + 1] = { catalog = catalog, lang = lang, keys = list }
    end
  end
  return out
end

local function report_unused(project, groups, headless)
  if #groups == 0 then
    return
  end
  local echo = function(text)
    api.nvim_echo({ { text, 'Comment' } }, headless, {})
  end
  local function shown(list, limit)
    local out = {}
    for i = 1, math.min(#list, limit) do
      out[i] = list[i]
    end
    return table.concat(out, ', ') .. (#list > limit and ' …' or '')
  end
  local function count(n)
    return ('%d %s'):format(n, n == 1 and 'key' or 'keys')
  end

  if #project.catalogs == 1 then
    local g = groups[1]
    -- ten fit a message line; a headless run keeps all of them
    echo(('[i18n-inline] %s in "%s" not referenced by any scan: %s')
      :format(count(#g.keys), g.lang, shown(g.keys, headless and #g.keys or 10)))
  elseif headless then
    for _, g in ipairs(groups) do
      echo(('[i18n-inline] %s in "%s" of %s not referenced by any scan: %s')
        :format(count(#g.keys), g.lang, g.catalog.label, shown(g.keys, #g.keys)))
    end
  else
    -- one line on screen (more would stop at a hit-enter prompt)
    local total, parts, budget = 0, {}, 10
    for _, g in ipairs(groups) do
      total = total + #g.keys
      if budget > 0 then
        parts[#parts + 1] = ('%s: %s'):format(g.catalog.label, shown(g.keys, budget))
        budget = budget - math.min(#g.keys, budget)
      end
    end
    echo(('[i18n-inline] %s not referenced by any scan: %s%s')
      :format(count(total), table.concat(parts, '; '), #parts < #groups and ' …' or ''))
  end
end

local function finish(project, run, elapsed_ms)
  local cfg = project.cfg
  local qf_items = run.items
  local mismatch_n, missing_n, gap_n = 0, 0, 0

  local unreadable = {}
  for _, catalog in ipairs(project.catalogs) do
    lang_gaps(catalog, run.ignored, qf_items, unreadable)
  end
  for _, it in ipairs(qf_items) do
    if it._kind == 'mismatch' then
      mismatch_n = mismatch_n + 1
    elseif it._kind == 'gap' then
      gap_n = gap_n + 1
    else
      missing_n = missing_n + 1
    end
    it._kind = nil
  end

  -- quickfill via vim.fn: the nvim_setqflist API is not available on Neovim 0.12
  vim.fn.setqflist({}, ' ', { title = 'i18n audit', items = qf_items })
  if #qf_items > 0 then
    vim.cmd('copen')
  end

  -- With no UI attached (CI, an agent's headless run) nobody reads the
  -- screen: keep the report in :messages and list every unused key. With a
  -- UI, history would turn the consecutive lines into a hit-enter prompt.
  local headless = #api.nvim_list_uis() == 0

  local function count(n, one, many)
    return ('%d %s'):format(n, n == 1 and one or many)
  end
  local missing = count(missing_n, 'missing key', 'missing keys')
  if run.elsewhere_n > 0 then
    missing = ('%s (%d only in another catalog)'):format(missing, run.elsewhere_n)
  end
  local nested = ''
  if #run.nested > 0 then
    nested = ('; skipped %s'):format(count(#run.nested, 'nested project', 'nested projects'))
  end
  local summary = ('[i18n-inline] %s — %s, %s, %s%s (%.1fs)'):format(
    vim.fn.fnamemodify(project.root, ':~'),
    count(mismatch_n, 'mismatch', 'mismatches'),
    missing,
    count(gap_n, 'missing translation', 'missing translations'),
    nested,
    elapsed_ms / 1000
  )
  api.nvim_echo({ { summary, (mismatch_n + missing_n + gap_n) > 0 and 'WarningMsg' or 'None' } }, headless, {})
  if #unreadable > 0 then
    local names = {}
    for i, u in ipairs(unreadable) do
      names[i] = #project.catalogs > 1 and ('%s:%s'):format(u[1].label, u[2]) or u[2]
    end
    table.sort(names)
    api.nvim_echo({
      { ('[i18n-inline] could not read languages: %s'):format(table.concat(names, ', ')), 'WarningMsg' },
    }, headless, {})
  end

  report_unused(project, unused_keys(project, run.used, run.ignored), headless)
end

function M.check(buf)
  buf = buf or api.nvim_get_current_buf()
  local project = resolve.project_for(buf) or resolve.project_from(vim.uv.cwd() or '.')
  if not project then
    util.notify('no translation project found, cannot audit', vim.log.levels.ERROR)
    return
  end
  local pcfg = project.cfg

  local err = resolve.preview_error({ project = project, catalogs = project.catalogs })
  if err then
    util.notify(err, vim.log.levels.ERROR)
    return
  end

  local root = project.root
  generation = generation + 1
  local my_gen = generation
  local files, nested = util.walk_files(root, {
    extensions = pcfg.check.extensions,
    exclude_dirs = pcfg.check.exclude_dirs,
    project_file = pcfg.project_file,
  })
  local t0 = vim.uv.hrtime()

  local run = {
    items = {},
    used = {}, -- [catalog] = { key = true }
    ignored = compile_ignores(pcfg.check.ignore),
    elsewhere_n = 0,
    nested = nested,
  }
  local memo = {} -- key tables, shared by every file's view
  local idx = 0

  local function mark_used(catalogs, key)
    for _, catalog in ipairs(catalogs or {}) do
      local set = run.used[catalog]
      if not set then
        set = {}
        run.used[catalog] = set
      end
      set[key] = true
    end
  end

  local function step()
    if my_gen ~= generation then
      return -- superseded by a newer run
    end
    local until_i = math.min(idx + BATCH, #files)
    while idx < until_i do
      idx = idx + 1
      local path = files[idx]
      local text = util.read_file(path)
      if text then
        local offsets = util.build_line_offsets(text)
        local view = resolve.view(project, path, memo)
        for _, m in ipairs(scan.scan(text, pcfg)) do
          resolve.classify(view, m)
          mark_used(view.catalogs, m.key)
          mark_used(m.elsewhere, m.key)
          local status = m.status
          if status == 'mismatch' or (status == 'missing' and not run.ignored(m.key)) then
            local row, col = util.byte_to_pos(offsets, m.call_s)
            local desc
            if status == 'mismatch' then
              desc = ('mismatch :%s — code %s vs %s %s')
                :format(m.key, util.quote(m.fb), pcfg.preview_lang, util.quote(m.value))
            else
              desc = missing_text(m, pcfg, view)
              if m.elsewhere then
                run.elsewhere_n = run.elsewhere_n + 1
              end
            end
            run.items[#run.items + 1] = {
              filename = path,
              lnum = row + 1,
              col = col + 1,
              text = desc,
              _kind = status,
            }
          end
        end
      end
    end

    if idx < #files then
      progress(('[i18n-inline] auditing… %d/%d files'):format(idx, #files))
      vim.schedule(step)
    else
      finish(project, run, (vim.uv.hrtime() - t0) / 1e6)
    end
  end

  progress(('[i18n-inline] auditing %d %s…'):format(#files, #files == 1 and 'file' or 'files'))
  vim.schedule(step)
end

return M
