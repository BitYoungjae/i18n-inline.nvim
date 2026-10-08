-- i18n-inline.nvim — show real translation values next to i18n calls.
--
-- What it does:
--   - Inline virtual text after each fallback string shows the actual value
--     from the preview language's translation file.
--   - Drift is visible immediately: mismatch (≠, warning color + underline)
--     and missing keys (✗, error color).
--   - <Plug>(i18n-inline-hover) / :I18nHover: popover with every language's
--     value for the key under the cursor.
--   - <Plug>(i18n-inline-toggle) / :I18nToggle: hide/show inline previews
--     for the session (popover and audit keep working).
--   - <Plug>(i18n-inline-jump) / :I18nJump: open the translation file at
--     the key under the cursor.
--   - :I18nCheck: project-wide audit into the quickfix list.
--
-- No default keymaps ship (R6.7): map the <Plug> mappings or set
-- `keymaps = { hover = …, toggle = …, jump = … }`. Keymaps are applied
-- buffer-locally per project, from setup() and the project file alike.
-- Commands and <Plug> mappings live in plugin/i18n-inline.lua and work
-- without setup(); setup() adds configuration and automatic rendering.
--
-- Configuration lives in a `.i18n-inline.json` at each repository's root,
-- with `setup(opts)` providing user-level defaults. See README.

local api = vim.api

local M = {}

---@param opts table|nil setup options (see config.lua defaults)
function M.setup(opts)
  local config = require('i18n-inline.config')
  config.setup(opts)

  local preview = require('i18n-inline.preview')

  local group = api.nvim_create_augroup('i18n-inline', { clear = true })

  -- Buffer open/save/filetype settled -> refresh soon
  api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'FileType' }, {
    group = group,
    callback = function(ev)
      preview.schedule(ev.buf)
    end,
  })

  -- Editing -> debounced refresh
  api.nvim_create_autocmd({ 'InsertLeave', 'TextChanged' }, {
    group = group,
    callback = function(ev)
      preview.schedule(ev.buf)
    end,
  })

  -- Buffer unload -> drop state
  api.nvim_create_autocmd('BufUnload', {
    group = group,
    callback = function(ev)
      preview.unload(tonumber(ev.match) or ev.buf)
    end,
  })

  -- Buffer renamed (:saveas, :file) -> its project may differ
  api.nvim_create_autocmd('BufFilePost', {
    group = group,
    callback = function(ev)
      require('i18n-inline.resolve').forget(ev.buf)
      preview.schedule(ev.buf)
    end,
  })

  -- Any file saved: project config, or a translation file in a known format
  -- (json, arb, po) -> invalidate caches, refresh. The buffer name, not
  -- ev.file: <afile> is relative to cwd when the file was opened that way.
  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(ev)
      preview.on_file_saved(api.nvim_buf_get_name(ev.buf))
    end,
  })

  -- Handle buffers opened before setup() ran (lazy loading)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      preview.schedule(buf)
    end
  end

  return M
end

function M.refresh(buf)
  require('i18n-inline.preview').refresh(buf)
end

function M.hover()
  require('i18n-inline.hover').hover()
end

function M.toggle()
  local mode = require('i18n-inline.preview').toggle()
  require('i18n-inline.util').notify(('inline previews: %s'):format(mode))
  return mode
end

function M.jump(opts)
  require('i18n-inline.jump').jump(opts)
end

function M.check()
  require('i18n-inline.check').check()
end

return M
