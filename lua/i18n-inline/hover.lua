-- Language popover: show every language's value for the key under the cursor.
--
-- Readability at scale (R6.6): stable language-column alignment, values
-- truncated per line, window width/height bounded (long content wraps rather
-- than growing the popover without limit).
--
-- In a project with several catalogs, every catalog the file reads that has
-- the key gets a named section (a shared component fed by two catalogs
-- shows both); a key only found elsewhere shows those catalogs, marked.
--
-- At most one popover exists: opening a new one closes the previous one
-- (its close-on-move autocmds would otherwise be replaced and leak it).

local api = vim.api
local preview = require('i18n-inline.preview')
local resolve = require('i18n-inline.resolve')
local scan = require('i18n-inline.scan')
local util = require('i18n-inline.util')

local M = {}

local popup = nil -- { win, group }

local function close()
  if not popup then
    return
  end
  pcall(api.nvim_del_augroup_by_id, popup.group)
  if api.nvim_win_is_valid(popup.win) then
    api.nvim_win_close(popup.win, true)
  end
  popup = nil
end

M.close = close

local function border(hcfg)
  if hcfg.border ~= nil then
    return hcfg.border
  end
  -- 'winborder' (0.11+) already applies when border is omitted
  local ok, wb = pcall(function()
    return vim.o.winborder
  end)
  if ok and wb ~= nil and wb ~= '' then
    return nil
  end
  return 'rounded'
end

function M.hover()
  local m, project, err = preview.current_match()
  if not m then
    util.notify(err)
    return
  end
  close()
  local cfg = project.cfg
  local hcfg = cfg.hover or {}
  local view = resolve.view(project, resolve.buf_path(0))
  local holders = resolve.holders(view, m)
  -- With several catalogs each section names its own; a lone catalog
  -- needs no name.
  local labeled = #project.catalogs > 1
  local reads = {}
  for _, catalog in ipairs(view.catalogs) do
    reads[catalog] = true
  end

  local pad = 0
  for _, catalog in ipairs(holders) do
    for lang in pairs(catalog.langs) do
      pad = math.max(pad, api.nvim_strwidth(lang))
    end
  end

  local max_len = hcfg.max_len or 60
  local rule = ('─'):rep(math.max(12, math.min(40, pad + 20)))
  local lines = {}
  local line_meta = {} -- per-line highlight info

  if m.fb then
    lines[#lines + 1] = ('fallback: %s'):format(util.truncate(util.display_value(m.fb), max_len))
  else
    lines[#lines + 1] = 'fallback: (none)'
  end
  line_meta[#lines] = {}

  for _, catalog in ipairs(holders) do
    lines[#lines + 1] = rule
    line_meta[#lines] = {}
    if labeled then
      local note = reads[catalog] and '' or ' · not read by this file'
      lines[#lines + 1] = catalog.label .. note
      line_meta[#lines] = { header = true }
    end
    for _, lang in ipairs(resolve.sorted_langs(catalog)) do
      local keys = resolve.keys(view, catalog, lang)
      local value = keys and keys[m.key]
      local display = value ~= nil and util.truncate(util.display_value(value), max_len) or '(missing)'
      -- Only the preview language is expected to mirror the code fallback;
      -- other languages are translations, so differing there is not drift.
      -- Same comparison as the inline status (compare/normalize applied).
      local mismatch = lang == cfg.preview_lang and value ~= nil and scan.compare(m, value, cfg) == 'mismatch'
      local label = lang .. (' '):rep(pad - api.nvim_strwidth(lang)) .. '  '
      lines[#lines + 1] = label .. display
      line_meta[#lines] = { lang = lang, mismatch = mismatch, label_width = #label }
    end
  end

  -- Open a non-focusable popup at the cursor. Built directly on nvim_open_win:
  -- vim.lsp.util.open_floating_preview closes its window before returning on
  -- current Neovim, which makes post-open highlighting impossible.
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, api.nvim_strwidth(l))
  end
  width = math.max(20, math.min(width, hcfg.width or 60))

  local fbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].bufhidden = 'wipe'

  local ns = api.nvim_create_namespace('i18n_inline_hover')
  for i, meta in ipairs(line_meta) do
    if meta.lang then
      api.nvim_buf_set_extmark(fbuf, ns, i - 1, 0, {
        end_col = meta.label_width,
        hl_group = meta.mismatch and cfg.hl.mismatch or 'Comment',
      })
    elseif meta.header then
      api.nvim_buf_set_extmark(fbuf, ns, i - 1, 0, { end_col = #lines[i], hl_group = 'Title' })
    end
  end

  local wopts = {
    relative = 'cursor',
    anchor = 'NW',
    row = 1,
    col = 0,
    width = width,
    height = math.min(#lines, hcfg.max_height or 20),
    style = 'minimal',
    border = border(hcfg),
    focusable = false,
  }
  -- a title needs a visible border
  if (wopts.border or vim.o.winborder) ~= 'none' then
    wopts.title = ' ' .. util.truncate(m.key, 40) .. ' '
    wopts.title_pos = 'center'
  end
  local ok, win = pcall(api.nvim_open_win, fbuf, false, wopts)
  if not ok then
    return
  end
  vim.wo[win].wrap = true

  local group = api.nvim_create_augroup('i18n_inline_hover', { clear = true })
  popup = { win = win, group = group }
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufLeave', 'InsertCharPre', 'WinLeave' }, {
    group = group,
    callback = close,
  })
end

return M
