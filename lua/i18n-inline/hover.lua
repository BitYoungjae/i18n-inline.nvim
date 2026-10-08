-- Language popover: show every language's value for the key under the cursor.

local api = vim.api
local preview = require('i18n-inline.preview')
local resolve = require('i18n-inline.resolve')
local util = require('i18n-inline.util')

local M = {}

local function match_at(buf, row)
  local st = preview.state(buf)
  if not st or not st.matches then
    return nil
  end
  for _, m in ipairs(st.matches) do
    if row >= m.row_start and row <= m.row_end then
      return m
    end
  end
  return nil
end

function M.hover()
  local buf = api.nvim_get_current_buf()
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local m = match_at(buf, row)
  if not m then
    vim.notify('[i18n-inline] no i18n call under the cursor', vim.log.levels.INFO)
    return
  end

  local st = preview.state(buf)
  local project = st and st.project
  if not project then
    vim.notify('[i18n-inline] no translation project for this buffer', vim.log.levels.WARN)
    return
  end
  local cfg = project.cfg

  -- Language order: preview language first, then alphabetical.
  local langs = {}
  for lang in pairs(project.langs) do
    langs[#langs + 1] = lang
  end
  table.sort(langs, function(a, b)
    if a == cfg.preview_lang then
      return true
    end
    if b == cfg.preview_lang then
      return false
    end
    return a < b
  end)

  local pad = 0
  for _, lang in ipairs(langs) do
    pad = math.max(pad, api.nvim_strwidth(lang))
  end

  local lines = {}
  local line_meta = {} -- per-line highlight info

  if m.fb then
    lines[#lines + 1] = ('fallback: %s'):format(util.truncate(util.display_value(m.fb), 80))
  else
    lines[#lines + 1] = 'fallback: (none)'
  end
  line_meta[#lines] = {}
  lines[#lines + 1] = ('─'):rep(math.max(12, math.min(40, pad + 20)))
  line_meta[#lines] = {}

  for _, lang in ipairs(langs) do
    local keys = resolve.ensure_lang(project, lang)
    local value = keys and keys[m.key] or nil
    if value == vim.NIL then
      value = nil
    end
    local display = value ~= nil and util.display_value(value) or '(missing)'
    local mismatch = m.fb ~= nil and value ~= nil and m.fb ~= value
    local label = lang .. (' '):rep(pad - api.nvim_strwidth(lang)) .. '  '
    lines[#lines + 1] = label .. display
    line_meta[#lines] = { lang = lang, mismatch = mismatch, label_width = api.nvim_strwidth(label) }
  end

  -- Open a non-focusable popup at the cursor. Built directly on nvim_open_win:
  -- vim.lsp.util.open_floating_preview closes its window before returning on
  -- current Neovim, which makes post-open highlighting impossible.
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, api.nvim_strwidth(l))
  end
  width = math.max(20, math.min(width, 80))

  local fbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].bufhidden = 'wipe'

  local ok, win = pcall(api.nvim_open_win, fbuf, false, {
    relative = 'cursor',
    anchor = 'NW',
    row = 1,
    col = 0,
    width = width,
    height = math.min(#lines, 20),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. util.truncate(m.key, 40) .. ' ',
    title_pos = 'center',
    focusable = false,
  })
  if not ok then
    return
  end
  vim.wo[win].wrap = true

  local group = api.nvim_create_augroup('i18n_inline_hover', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufLeave', 'InsertCharPre', 'WinLeave' }, {
    group = group,
    callback = function()
      api.nvim_del_augroup_by_id(group)
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end,
  })

  -- Highlight inside the popover: language label dimmed (or warned on mismatch)
  if api.nvim_buf_is_valid(fbuf) then
    local ns = api.nvim_create_namespace('i18n_inline_hover')
    for i, meta in ipairs(line_meta) do
      if meta.lang then
        api.nvim_buf_set_extmark(fbuf, ns, i - 1, 0, {
          end_col = meta.label_width,
          hl_group = meta.mismatch and cfg.hl.mismatch or 'Comment',
        })
      end
    end
  end
end

return M
