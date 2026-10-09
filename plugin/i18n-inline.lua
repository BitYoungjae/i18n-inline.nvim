-- Commands, <Plug> mappings and highlight defaults — available as soon as
-- the plugin is on the runtimepath, before (or without) setup(). setup()
-- adds configuration and the autocmds that render previews automatically;
-- the actions below resolve the project on demand either way.
--
-- No default keymaps ship (R6.7): every action is reachable via these
-- <Plug> mappings and :I18nHover / :I18nToggle / :I18nJump / :I18nCheck.
if vim.g.loaded_i18n_inline then
  return
end
vim.g.loaded_i18n_inline = true

local api = vim.api

-- Default links, re-applied after a colorscheme change (`:hi clear` drops
-- them). `default = true` keeps any definition a colorscheme provides.
local function define_highlights()
  for group, link in pairs({
    I18nInlineValue = 'Comment',
    I18nInlineMismatch = 'DiagnosticWarn',
    I18nInlineMissing = 'DiagnosticError',
    I18nInlineMismatchUnderline = 'DiagnosticUnderlineWarn',
  }) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end
define_highlights()
api.nvim_create_autocmd('ColorScheme', {
  group = api.nvim_create_augroup('i18n-inline-hl', { clear = true }),
  callback = define_highlights,
})

local function i18n()
  return require('i18n-inline')
end

vim.keymap.set('n', '<Plug>(i18n-inline-hover)', function()
  i18n().hover()
end, { silent = true, desc = 'i18n: per-language translations popover' })

vim.keymap.set('n', '<Plug>(i18n-inline-toggle)', function()
  i18n().toggle()
end, { silent = true, desc = 'i18n: cycle inline display (always/problems/never)' })

vim.keymap.set('n', '<Plug>(i18n-inline-jump)', function()
  i18n().jump()
end, { silent = true, desc = 'i18n: open the translation file at the key under the cursor' })

api.nvim_create_user_command('I18nCheck', function()
  i18n().check()
end, { desc = 'i18n: audit drift project-wide (quickfix)' })

api.nvim_create_user_command('I18nHover', function()
  i18n().hover()
end, { desc = 'i18n: popover with per-language translations for the key under cursor' })

api.nvim_create_user_command('I18nToggle', function()
  i18n().toggle()
end, { desc = 'i18n: cycle inline display (always/problems/never) for the session' })

api.nvim_create_user_command('I18nJump', function(ev)
  i18n().jump({ bang = ev.bang, lang = ev.args ~= '' and ev.args or nil })
end, {
  bang = true,
  nargs = '?',
  -- A Lua completion function is customlist-style: filtering is ours.
  complete = function(arglead)
    local resolve = require('i18n-inline.resolve')
    local buf = api.nvim_get_current_buf()
    local project = resolve.project_for(buf)
    if not project then
      return {}
    end
    -- the languages of the catalogs this buffer reads
    local langs = {}
    for _, catalog in ipairs(resolve.catalogs_for(project, resolve.buf_path(buf))) do
      for lang, path in pairs(catalog.langs) do
        langs[lang] = path
      end
    end
    return vim.tbl_filter(function(lang)
      return vim.startswith(lang, arglead)
    end, resolve.sorted_langs({ cfg = project.cfg, langs = langs }))
  end,
  desc = 'i18n: open the translation file at the key under the cursor (<lang> = specific language, ! = all languages)',
})
