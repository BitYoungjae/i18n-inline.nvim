-- Buffer preview: scan -> classify -> render extmarks (inline virtual text,
-- plus an underline on mismatched fallback strings).
--
-- Per-buffer state: { project, matches, tick, virt_ids, hl_ids, timer, … }
-- Each match extends the scan result with row/col positions and the
-- resolve.classify fields (status, value, catalog, in_source, elsewhere).
-- `tick` is the changedtick the matches were computed at; hover and jump go
-- through current_match(), which re-scans first when the buffer changed
-- since (or was never scanned), so they never act on stale positions.
--
-- Inline display mode is runtime-toggleable (:I18nToggle,
-- <Plug>(i18n-inline-toggle)): it cycles 'always' -> 'problems' -> 'never'
-- for the session, starting from the configured `show`. Scanning and hover
-- keep working in every mode; 'never' only hides the extmarks.

local api = vim.api
local uv = vim.uv
local config = require('i18n-inline.config')
local scan = require('i18n-inline.scan')
local util = require('i18n-inline.util')
local resolve = require('i18n-inline.resolve')

local M = {}

local SHOW_MODES = { 'always', 'problems', 'never' }

local ns_id
local state = {}
-- Session-wide show-mode override (R6.5); nil = follow config.
local show_override = nil
-- The configured mode most recently seen while rendering, so the toggle
-- cycle starts from the active project's `show` rather than global defaults.
local last_cfg_show = nil

local function ns()
  if not ns_id then
    ns_id = api.nvim_create_namespace('i18n_inline')
  end
  return ns_id
end

-- Normalize the "current buffer" pseudo-id (0) to a real buffer number.
local function real_buf(buf)
  if buf == nil or buf == 0 then
    return api.nvim_get_current_buf()
  end
  return buf
end

function M.state(buf)
  return state[real_buf(buf)]
end

-- Distance from (row, col) to a match's span: 0 inside it, otherwise the
-- column gap on the row it shares; nil when the match does not touch `row`.
local function distance(m, row, col)
  if row < m.row_start or row > m.row_end then
    return nil
  end
  if row == m.row_start and col < m.col_start then
    return m.col_start - col
  end
  if row == m.row_end and col > m.col_end then
    return col - m.col_end
  end
  return 0
end

-- The match under (row, col) in `buf` — the one containing the position,
-- else the nearest one on that row (several calls can share a line:
-- `{t('a')} {t('b')}`). Without `col`, the first match on the row.
function M.match_at(buf, row, col)
  local st = state[real_buf(buf)]
  if not st or not st.matches then
    return nil
  end
  local best, best_d
  for _, m in ipairs(st.matches) do
    local d = distance(m, row, col or 0)
    if d and (not best_d or d < best_d) then
      best, best_d = m, d
      if d == 0 then
        break
      end
    end
  end
  return best
end

-- The match under the cursor of the current window, plus its project.
-- Re-scans first when the buffer changed since the last refresh (edits
-- inside the debounce window, insert-mode changes) or was never scanned.
-- Returns match, project — or nil, nil, message when there is nothing to
-- act on.
function M.current_match()
  local buf = api.nvim_get_current_buf()
  local st = state[buf]
  if not st or st.tick ~= api.nvim_buf_get_changedtick(buf) then
    M.refresh(buf)
    st = state[buf]
  end
  if not st or not st.project then
    return nil, nil, 'no translation project for this buffer'
  end
  local cursor = api.nvim_win_get_cursor(0)
  local m = M.match_at(buf, cursor[1] - 1, cursor[2])
  if not m then
    return nil, nil, 'no i18n call under the cursor'
  end
  return m, st.project
end

-- Cycle the inline display mode for the session and re-render.
-- Returns the new mode ('always' | 'problems' | 'never').
function M.toggle()
  local cur = show_override or last_cfg_show or config.get().show
  local next_i = 1
  for i, mode in ipairs(SHOW_MODES) do
    if mode == cur then
      next_i = (i % #SHOW_MODES) + 1
      break
    end
  end
  show_override = SHOW_MODES[next_i]
  for buf, st in pairs(state) do
    if st and st.project and api.nvim_buf_is_valid(buf) then
      M.refresh(buf)
    end
  end
  return show_override
end

-- Is this buffer eligible for previewing, under the project's config?
local function eligible(buf, cfg)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= '' then
    return false
  end
  if not vim.tbl_contains(cfg.filetypes, vim.bo[buf].filetype) then
    return false
  end
  local lines = api.nvim_buf_line_count(buf)
  if lines > 0 and api.nvim_buf_get_offset(buf, lines) > cfg.max_filesize then
    return false
  end
  return true
end

-- Debounced refresh
function M.schedule(buf)
  buf = real_buf(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local st = state[buf]
  if not st then
    st = {}
    state[buf] = st
  end
  if not st.timer then
    st.timer = uv.new_timer()
  end
  st.timer:stop()
  local cfg = st.project and st.project.cfg or config.get()
  st.timer:start(cfg.debounce_ms, 0, vim.schedule_wrap(function()
    M.refresh(buf)
  end))
end

local function clear_marks(buf, st)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns(), 0, -1)
  end
  st.virt_ids = nil
  st.hl_ids = nil
end

function M.clear(buf)
  local st = state[buf]
  if st then
    if st.timer then
      st.timer:stop()
    end
    clear_marks(buf, st)
    st.matches = nil
    st.project = nil
    st.tick = nil
    M._unset_keymaps(buf, st)
  end
end

function M.unload(buf)
  local st = state[buf]
  if st and st.timer then
    st.timer:close()
  end
  state[buf] = nil
  resolve.forget(buf)
end

-- Effective `show` after the runtime toggle.
local function effective_show(cfg)
  last_cfg_show = cfg.show
  return show_override or cfg.show
end

-- "only in <catalog>" (+N more): the key exists, but in catalogs this file
-- does not read (see resolve.lua).
local function elsewhere_text(m)
  local more = #m.elsewhere > 1 and (' +%d'):format(#m.elsewhere - 1) or ''
  return 'only in ' .. m.elsewhere[1].label .. more
end

local function build_virt_text(m, cfg)
  if m.status == 'missing' then
    local text = cfg.missing_text
    if m.in_source then
      text = 'missing in ' .. cfg.preview_lang
    elseif m.elsewhere then
      text = elsewhere_text(m)
    end
    return cfg.prefix .. '✗ ' .. text, cfg.hl.missing
  end
  local sign = m.status == 'mismatch' and '≠ ' or ''
  local value = util.truncate(util.display_value(m.value or ''), cfg.max_len)
  return cfg.prefix .. sign .. value, m.status == 'mismatch' and cfg.hl.mismatch or cfg.hl.match
end

local function render(buf, st, cfg)
  local eff = effective_show(cfg)
  if eff == 'never' then
    -- Popover/audit-only mode: matches stay in state (hover works), no marks.
    clear_marks(buf, st)
    return
  end

  local shown = {}
  for _, m in ipairs(st.matches) do
    if eff == 'always' or m.status == 'mismatch' or m.status == 'missing' then
      shown[#shown + 1] = m
    end
  end

  -- Inline virtual text right after the fallback's closing quote (or the key
  -- when there is no fallback). Extmark ids are reused in scan order, so
  -- unchanged marks keep their identity and nothing flickers.
  local virt_ids = {}
  for i, m in ipairs(shown) do
    local text, hl = build_virt_text(m, cfg)
    local opts = {
      virt_text = { { text, hl } },
      virt_text_pos = cfg.position,
      hl_mode = 'combine',
    }
    if cfg.extmark_priority then
      opts.priority = cfg.extmark_priority
    end
    if st.virt_ids and st.virt_ids[i] then
      opts.id = st.virt_ids[i]
    end
    local row, col
    if cfg.position == 'eol' then
      row, col = m.row_end, 0
    else
      row, col = m.row_end, m.col_end + 1
    end
    virt_ids[i] = api.nvim_buf_set_extmark(buf, ns(), row, col, opts)
  end
  for i = #shown + 1, #(st.virt_ids or {}) do
    api.nvim_buf_del_extmark(buf, ns(), st.virt_ids[i])
  end
  st.virt_ids = virt_ids

  -- Underline mismatched fallback strings
  if cfg.underline_mismatch then
    local hl_ids = {}
    local n = 0
    for _, m in ipairs(shown) do
      if m.status == 'mismatch' and m.str_row_s then
        n = n + 1
        local opts = {
          hl_group = cfg.hl.underline,
          end_row = m.row_end,
          end_col = m.col_end + 1, -- include the closing quote
        }
        if cfg.extmark_priority then
          opts.priority = cfg.extmark_priority
        end
        if st.hl_ids and st.hl_ids[n] then
          opts.id = st.hl_ids[n]
        end
        hl_ids[n] = api.nvim_buf_set_extmark(buf, ns(), m.str_row_s, m.str_col_s, opts)
      end
    end
    for i = n + 1, #(st.hl_ids or {}) do
      api.nvim_buf_del_extmark(buf, ns(), st.hl_ids[i])
    end
    st.hl_ids = hl_ids
  end
end

-- Buffer-local action keymaps (R6.1/R6.7). Applied once per distinct keymap
-- configuration when a buffer's project resolves — so project-file keymaps
-- work, and nothing leaks to unrelated buffers.
local ACTIONS = {
  hover = { plug = '<Plug>(i18n-inline-hover)', desc = 'i18n translations popover' },
  toggle = { plug = '<Plug>(i18n-inline-toggle)', desc = 'i18n cycle inline display' },
  jump = { plug = '<Plug>(i18n-inline-jump)', desc = 'i18n jump to translation file' },
}

function M._unset_keymaps(buf, st)
  if st.set_keymaps then
    for _, lhs in pairs(st.set_keymaps) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end
    st.set_keymaps = nil
  end
  st.keymap_sig = nil -- so the next resolve re-applies them
end

local function apply_keymaps(buf, st, cfg)
  local sig = vim.inspect(cfg.keymaps)
  if st.keymap_sig == sig then
    return
  end
  M._unset_keymaps(buf, st)
  st.set_keymaps = {}
  for action, def in pairs(ACTIONS) do
    local lhs = cfg.keymaps and cfg.keymaps[action]
    if lhs then
      vim.keymap.set('n', lhs, def.plug, {
        buffer = buf,
        silent = true,
        desc = def.desc,
      })
      st.set_keymaps[action] = lhs
    end
  end
  st.keymap_sig = sig
end

function M.refresh(buf)
  buf = real_buf(buf)

  local project = resolve.project_for(buf)
  if not project then
    M.clear(buf)
    return
  end
  local cfg = project.cfg
  if not eligible(buf, cfg) then
    M.clear(buf)
    return
  end

  local view = resolve.view(project, resolve.buf_path(buf))
  local err = resolve.preview_error(view)
  if err then
    -- Notify once per project, then stay quiet
    if not project._notified then
      project._notified = true
      vim.notify('[i18n-inline] ' .. err, vim.log.levels.WARN)
    end
    M.clear(buf)
    return
  end

  local tick = api.nvim_buf_get_changedtick(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, '\n')
  local offsets = util.build_line_offsets(text)
  local matches = scan.scan(text, cfg)

  for _, m in ipairs(matches) do
    m.row_start, m.col_start = util.byte_to_pos(offsets, m.call_s)
    m.row_end, m.col_end = util.byte_to_pos(offsets, m.str_e or m.call_e)
    if m.str_s then
      m.str_row_s, m.str_col_s = util.byte_to_pos(offsets, m.str_s)
    end
    resolve.classify(view, m)
  end

  local st = state[buf]
  if not st then
    st = {}
    state[buf] = st
  end
  st.project = project
  st.matches = matches
  st.tick = tick

  apply_keymaps(buf, st, cfg)
  render(buf, st, cfg)
end

-- A file was saved: refresh whatever it affects. `path` must be absolute
-- (the buffer name — the autocmd's <afile> can be relative to cwd).
function M.on_file_saved(path)
  local name = vim.fs.basename(path) or ''
  -- Per-project config changed: drop all project caches and re-resolve.
  if name == config.get().project_file then
    resolve.reset()
    for buf in pairs(state) do
      resolve.forget(buf)
      if api.nvim_buf_is_valid(buf) then
        M.refresh(buf)
      end
    end
    return
  end

  -- Translation file changed: drop its cache, refresh that project's buffers.
  resolve.invalidate_path(path)
  local project = resolve.project_having_file(path)
  if not project then
    return
  end
  for buf, st in pairs(state) do
    if st and st.project == project and api.nvim_buf_is_valid(buf) then
      M.refresh(buf)
    end
  end
end

-- Tests only
function M._reset()
  for buf in pairs(state) do
    M.unload(buf)
  end
  state = {}
  show_override = nil
  last_cfg_show = nil
end

return M
