-- i18n-inline.nvim — show real translation values next to i18n calls.
--
-- What it does:
--   - Inline virtual text after each fallback string shows the actual value
--     from the preview language's translation file.
--   - Drift is visible immediately: mismatch (≠, warning color + underline)
--     and missing keys (✗, error color).
--   - <Plug>(i18n-inline-hover): popover with every language's value.
--   - :I18nCheck: project-wide audit into the quickfix list.
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
  local cfg = config.get()

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

  -- Translation or project config JSON saved -> invalidate caches, refresh
  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = '*.json',
    callback = function(ev)
      preview.on_file_saved(ev.file)
    end,
  })

  -- Commands
  api.nvim_create_user_command('I18nCheck', function()
    require('i18n-inline.check').check()
  end, { desc = 'i18n: audit fallback/translation drift project-wide (quickfix)' })

  api.nvim_create_user_command('I18nHover', function()
    require('i18n-inline.hover').hover()
  end, { desc = 'i18n: popover with per-language translations for the key under cursor' })

  -- Optional default mapping
  if cfg.keymap then
    vim.keymap.set('n', cfg.keymap, '<Plug>(i18n-inline-hover)', { silent = true, desc = 'i18n translations' })
  end

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

function M.check()
  require('i18n-inline.check').check()
end

return M
