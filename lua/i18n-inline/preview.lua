-- Buffer preview: scan -> classify -> render extmarks (inline virtual text,
-- plus an underline on mismatched fallback strings).
--
-- Per-buffer state: { project, matches, virt_ids, hl_ids, timer }
-- Each match extends the scan result with row/col positions and status/value.

local api = vim.api
local uv = vim.uv
local config = require('i18n-inline.config')
local scan = require('i18n-inline.scan')
local util = require('i18n-inline.util')
local resolve = require('i18n-inline.resolve')

local M = {}

local ns_id
local state = {}

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
  st.timer:start(config.get().debounce_ms, 0, vim.schedule_wrap(function()
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

local function build_virt_text(m, cfg)
  if m.status == 'missing' then
    return cfg.prefix .. '✗ ' .. cfg.missing_text, cfg.hl.missing
  end
  local sign = m.status == 'mismatch' and '≠ ' or ''
  local value = util.truncate(util.display_value(m.value or ''), cfg.max_len)
  return cfg.prefix .. sign .. value, m.status == 'mismatch' and cfg.hl.mismatch or cfg.hl.match
end

local function render(buf, st, cfg)
  local shown = {}
  for _, m in ipairs(st.matches) do
    if cfg.show == 'always' or m.status == 'mismatch' or m.status == 'missing' then
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

  local keys, err = resolve.ensure_lang(project, cfg.preview_lang)
  if not keys then
    -- Notify once per project, then stay quiet
    if not project._notified then
      project._notified = true
      vim.notify('[i18n-inline] ' .. err, vim.log.levels.WARN)
    end
    M.clear(buf)
    return
  end

  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, '\n')
  local offsets = util.build_line_offsets(text)
  local matches = scan.scan(text, cfg.patterns)

  for _, m in ipairs(matches) do
    m.row_start, m.col_start = util.byte_to_pos(offsets, m.call_s)
    m.row_end, m.col_end = util.byte_to_pos(offsets, m.str_e or m.call_e)
    if m.str_s then
      m.str_row_s, m.str_col_s = util.byte_to_pos(offsets, m.str_s)
    end
    m.status, m.value = scan.status(m, keys)
  end

  local st = state[buf]
  if not st then
    st = {}
    state[buf] = st
  end
  st.project = project
  st.matches = matches

  render(buf, st, cfg)
end

-- A JSON file was saved: refresh whatever it affects.
function M.on_file_saved(path)
  local name = vim.fs.basename(path) or ''
  -- Per-project config changed: drop all project caches and re-resolve.
  if name == config.get().project_file then
    resolve.reset()
    for buf in pairs(state) do
      resolve.forget(buf)
      M.refresh(buf)
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
end

return M
