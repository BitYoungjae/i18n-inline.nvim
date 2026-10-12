-- :I18nLang — switch the language shown inline, for the session.
--
-- `:I18nLang <lang>` switches directly (tab-completes); without a language
-- (and from <Plug>(i18n-inline-lang)) it asks with vim.ui.select, so the
-- user's picker UI applies, as with `jump.lang = 'ask'`. The switch covers
-- every buffer of the current buffer's project; picking the configured
-- preview_lang goes back to it. preview.lua holds the state and explains
-- what changes while another language is shown.

local api = vim.api
local preview = require('i18n-inline.preview')
local resolve = require('i18n-inline.resolve')
local util = require('i18n-inline.util')

local M = {}

local function switch(project, lang)
  preview.set_lang(project, lang)
  local cfg = project.cfg
  if lang == cfg.preview_lang then
    util.notify(('preview language: %s (configured)'):format(lang))
  elseif cfg.compare == 'fallback' then
    -- ≠ marks disappear while another language shows: say why
    util.notify(('preview language: %s (≠ marks show in %s only)'):format(lang, cfg.preview_lang))
  else
    util.notify(('preview language: %s'):format(lang))
  end
end

---@param lang string|nil the language to show; nil asks
function M.lang(lang)
  local buf = api.nvim_get_current_buf()
  local project = resolve.project_for(buf)
  if not project then
    util.notify('no translation project for this buffer')
    return
  end
  -- stable order (configured language first), so positions in the picker
  -- don't move from one switch to the next
  local langs = resolve.langs_for(project, resolve.buf_path(buf))
  -- what this buffer shows: the project's language, unless the buffer's
  -- catalogs lack it
  local st = preview.state(buf)
  local current = st and st.lang or preview.preview_lang(project)

  if lang then
    if not vim.tbl_contains(langs, lang) then
      util.notify(
        ('no translation file for "%s" (available: %s)'):format(lang, table.concat(langs, ', ')),
        vim.log.levels.WARN
      )
      return
    end
    switch(project, lang)
    return
  end

  if #langs < 2 then
    util.notify(('no other language to preview (only "%s")'):format(langs[1] or current))
    return
  end
  vim.ui.select(langs, {
    prompt = 'i18n preview language:',
    format_item = function(l)
      local tags = {}
      if l == current then
        tags[#tags + 1] = 'current'
      end
      if l == project.cfg.preview_lang then
        tags[#tags + 1] = 'configured'
      end
      return #tags > 0 and ('%s (%s)'):format(l, table.concat(tags, ', ')) or l
    end,
  }, function(choice)
    if choice then
      switch(project, choice)
    end
  end)
end

return M
