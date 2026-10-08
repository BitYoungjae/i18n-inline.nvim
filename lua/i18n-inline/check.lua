-- :I18nCheck — audit the whole project for fallback/translation drift.
-- Results land in the quickfix list. Files are processed in batches on the
-- event loop so the UI stays responsive on large repositories.

local api = vim.api
local config = require('i18n-inline.config')
local scan = require('i18n-inline.scan')
local util = require('i18n-inline.util')
local resolve = require('i18n-inline.resolve')

local M = {}

local generation = 0
local BATCH = 40

local function walk_files(root, extensions, excludes)
  local ext_set = {}
  for _, e in ipairs(extensions) do
    ext_set[e:lower()] = true
  end
  local excl_set = {}
  for _, d in ipairs(excludes) do
    excl_set[d] = true
  end
  local files = {}
  local function walk(dir)
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
        if not excl_set[name] then
          walk(path)
        end
      elseif ftype == 'file' then
        local ext = name:match('%.([%w]+)$')
        if ext and ext_set[ext:lower()] then
          files[#files + 1] = path
        end
      end
    end
  end
  walk(root)
  table.sort(files)
  return files
end

local function progress(msg)
  api.nvim_echo({ { msg, 'Comment' } }, false, {})
end

local function finish(qf_items, used_keys, keys, elapsed_ms, root, preview_lang)
  local mismatch_n, missing_n = 0, 0
  for _, it in ipairs(qf_items) do
    if it._kind == 'mismatch' then
      mismatch_n = mismatch_n + 1
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

  local summary = ('[i18n-inline] %s — %d mismatches, %d missing keys (%.1fs)')
    :format(root, mismatch_n, missing_n, elapsed_ms / 1000)
  api.nvim_echo({ { summary, (mismatch_n + missing_n) > 0 and 'WarningMsg' or 'None' } }, false, {})

  local unused = {}
  for k in pairs(keys or {}) do
    if not used_keys[k] then
      unused[#unused + 1] = k
    end
  end
  if #unused > 0 then
    table.sort(unused)
    local shown = {}
    for i = 1, math.min(#unused, 10) do
      shown[#shown + 1] = unused[i]
    end
    api.nvim_echo({
      {
        ('[i18n-inline] %d keys in "%s" are not referenced by any scan pattern: %s%s')
          :format(#unused, preview_lang, table.concat(shown, ', '), #unused > 10 and ' …' or ''),
        'Comment',
      },
    }, false, {})
  end
end

function M.check(buf)
  buf = buf or api.nvim_get_current_buf()
  local cfg = config.get()
  local project = resolve.project_for(buf) or resolve.project_from(vim.uv.cwd() or '.')
  if not project then
    vim.notify('[i18n-inline] no translation project found, cannot audit', vim.log.levels.ERROR)
    return
  end
  local pcfg = project.cfg

  local keys, err = resolve.ensure_lang(project, pcfg.preview_lang)
  if not keys then
    vim.notify('[i18n-inline] ' .. err, vim.log.levels.ERROR)
    return
  end

  local root = project.root
  generation = generation + 1
  local my_gen = generation
  local files = walk_files(root, pcfg.check.extensions, pcfg.check.exclude_dirs)
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
      local fh = io.open(path, 'r')
      if fh then
        local text = fh:read('*a')
        fh:close()
        local offsets = util.build_line_offsets(text)
        for _, m in ipairs(scan.scan(text, pcfg.patterns)) do
          used_keys[m.key] = true
          local status, value = scan.status(m, keys)
          if status == 'mismatch' or status == 'missing' then
            local row, col = util.byte_to_pos(offsets, m.call_s)
            local desc
            if status == 'mismatch' then
              desc = ('mismatch :%s — code %q vs %s %q')
                :format(m.key, util.truncate(m.fb, 60), pcfg.preview_lang, util.truncate(value or '', 60))
            else
              desc = ('missing key :%s — fallback %q'):format(m.key, util.truncate(m.fb or '', 60))
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
      finish(qf_items, used_keys, keys, (vim.uv.hrtime() - t0) / 1e6, root, pcfg.preview_lang)
    end
  end

  progress(('[i18n-inline] auditing %d files…'):format(#files))
  vim.schedule(step)
end

return M
