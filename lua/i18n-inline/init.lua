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
--   - :I18nCheck: project-wide audit into the quickfix list.
--
-- No default keymaps ship (R6.7): map the <Plug> mappings or set
-- `keymaps = { hover = …, toggle = … }`. Keymaps are applied buffer-locally
-- per project, from setup() and the project file alike.
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

  -- Any file saved: project config, or a translation file in a known format
  -- (json today, po, …) -> invalidate caches, refresh.
  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(ev)
      preview.on_file_saved(ev.file)
    end,
  })

  -- Commands
  api.nvim_create_user_command('I18nCheck', function()
    require('i18n-inline.check').check()
  end, { desc = 'i18n: audit drift project-wide (quickfix)' })

  api.nvim_create_user_command('I18nHover', function()
    require('i18n-inline.hover').hover()
  end, { desc = 'i18n: popover with per-language translations for the key under cursor' })

  api.nvim_create_user_command('I18nToggle', function()
    local mode = require('i18n-inline.preview').toggle()
    vim.notify(('[i18n-inline] inline previews: %s'):format(mode), vim.log.levels.INFO)
  end, { desc = 'i18n: cycle inline display (always/problems/never) for the session' })

  api.nvim_create_user_command('I18nJump', function(ev)
    require('i18n-inline.jump').jump({ bang = ev.bang, lang = ev.args ~= '' and ev.args or nil })
  end, {
    bang = true,
    nargs = '?',
    complete = function()
      local st = require('i18n-inline.preview').state(api.nvim_get_current_buf())
      local project = st and st.project
      if not project then
        return {}
      end
      local langs = vim.tbl_keys(project.langs)
      table.sort(langs)
      return langs
    end,
    desc = 'i18n: open the translation file at the key under the cursor (<lang> = specific language, ! = all languages)',
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
  vim.notify(('[i18n-inline] inline previews: %s'):format(mode), vim.log.levels.INFO)
  return mode
end

function M.jump(opts)
  require('i18n-inline.jump').jump(opts)
end

function M.check()
  require('i18n-inline.check').check()
end

return M
