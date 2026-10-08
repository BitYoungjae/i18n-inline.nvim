-- :I18nCheck — audit the project for drift. Results land in the quickfix
-- list. Files are processed in batches on the event loop so the UI stays
-- responsive on large repositories.
--
-- Three findings:
--   mismatch — code fallback disagrees with the preview language value
--   missing  — a call's key is absent from the preview language (and from
--              the source language, when configured)
--   gap      — key present in the source language but missing from another
--              language's file (source_lang audit, R5.3)
-- Plus a summary echo of unused keys (not referenced by any scanned call,
-- honoring check.ignore globs, R5.2).

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

-- Cross-language audit against the source language (R5.3): every key the
-- source owns must exist in every other language file.
local function lang_gaps(project, ignored)
  local cfg = project.cfg
  local src = cfg.source_lang
  if not src or not project.langs[src] then
    return {}, {}
  end
  local src_keys = resolve.ensure_lang(project, src)
  if not src_keys then
    return {}, { src }
  end
  local src_sorted = vim.tbl_keys(src_keys)
  table.sort(src_sorted)
  local items, unreadable = {}, {}
  for _, lang in ipairs(resolve.sorted_langs(project)) do
    if lang ~= src then
      local keys = resolve.ensure_lang(project, lang)
      if not keys then
        unreadable[#unreadable + 1] = lang
      else
        for _, k in ipairs(src_sorted) do
          if keys[k] == nil and not ignored(k) then
            items[#items + 1] = {
              filename = project.langs[lang],
              lnum = 1, -- keep filename intact in quickfix (no line to point at)
              text = ('missing key :%s — present in %s'):format(k, src),
              _kind = 'gap',
            }
          end
        end
      end
    end
  end
  return items, unreadable
end

local function finish(project, qf_items, used_keys, keys, elapsed_ms)
  local cfg = project.cfg
  local ignored = compile_ignores(cfg.check.ignore)
  local mismatch_n, missing_n, gap_n = 0, 0, 0

  local gap_items, unreadable = lang_gaps(project, ignored)
  for _, it in ipairs(gap_items) do
    qf_items[#qf_items + 1] = it
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
  local summary = ('[i18n-inline] %s — %s, %s, %s (%.1fs)'):format(
    vim.fn.fnamemodify(project.root, ':~'),
    count(mismatch_n, 'mismatch', 'mismatches'),
    count(missing_n, 'missing key', 'missing keys'),
    count(gap_n, 'missing translation', 'missing translations'),
    elapsed_ms / 1000
  )
  api.nvim_echo({ { summary, (mismatch_n + missing_n + gap_n) > 0 and 'WarningMsg' or 'None' } }, headless, {})
  if #unreadable > 0 then
    table.sort(unreadable)
    api.nvim_echo({
      { ('[i18n-inline] could not read languages: %s'):format(table.concat(unreadable, ', ')), 'WarningMsg' },
    }, headless, {})
  end

  -- Unused keys are audited against the source language when configured
  -- (it owns the key set), else the preview language.
  local unused_keys = keys
  if cfg.source_lang then
    local src = resolve.ensure_lang(project, cfg.source_lang)
    if src then
      unused_keys = src
    end
  end
  local unused = {}
  for k in pairs(unused_keys or {}) do
    if not used_keys[k] and not ignored(k) then
      unused[#unused + 1] = k
    end
  end
  if #unused > 0 then
    table.sort(unused)
    local limit = headless and #unused or 10 -- ten fit a message line
    local shown = {}
    for i = 1, math.min(#unused, limit) do
      shown[#shown + 1] = unused[i]
    end
    local against = cfg.source_lang or cfg.preview_lang
    api.nvim_echo({
      {
        ('[i18n-inline] %d %s in "%s" not referenced by any scan: %s%s'):format(
          #unused,
          #unused == 1 and 'key' or 'keys',
          against,
          table.concat(shown, ', '),
          #unused > limit and ' …' or ''
        ),
        'Comment',
      },
    }, headless, {})
  end
end

function M.check(buf)
  buf = buf or api.nvim_get_current_buf()
  local project = resolve.project_for(buf) or resolve.project_from(vim.uv.cwd() or '.')
  if not project then
    util.notify('no translation project found, cannot audit', vim.log.levels.ERROR)
    return
  end
  local pcfg = project.cfg

  local keys, err = resolve.ensure_lang(project, pcfg.preview_lang)
  if not keys then
    util.notify(err, vim.log.levels.ERROR)
    return
  end
  local source_keys = nil
  if pcfg.source_lang and pcfg.source_lang ~= pcfg.preview_lang then
    source_keys = resolve.ensure_lang(project, pcfg.source_lang)
  end

  local root = project.root
  generation = generation + 1
  local my_gen = generation
  local files = util.walk_files(root, pcfg.check.extensions, pcfg.check.exclude_dirs)
  local t0 = vim.uv.hrtime()

  local qf_items = {}
  local used_keys = {}
  local idx = 0

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
        for _, m in ipairs(scan.scan(text, pcfg)) do
          used_keys[m.key] = true
          local status, value, in_source = scan.status(m, keys, pcfg, source_keys)
          if status == 'mismatch' or status == 'missing' then
            local row, col = util.byte_to_pos(offsets, m.call_s)
            local desc
            if status == 'mismatch' then
              desc = ('mismatch :%s — code %s vs %s %s')
                :format(m.key, util.quote(m.fb), pcfg.preview_lang, util.quote(value))
            elseif in_source then
              desc = ('missing in %s :%s — present in %s')
                :format(pcfg.preview_lang, m.key, pcfg.source_lang)
            elseif m.fb then
              desc = ('missing key :%s — fallback %s'):format(m.key, util.quote(m.fb))
            else
              desc = ('missing key :%s'):format(m.key)
            end
            qf_items[#qf_items + 1] = {
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
      finish(project, qf_items, used_keys, keys, (vim.uv.hrtime() - t0) / 1e6)
    end
  end

  progress(('[i18n-inline] auditing %d %s…'):format(#files, #files == 1 and 'file' or 'files'))
  vim.schedule(step)
end

return M
