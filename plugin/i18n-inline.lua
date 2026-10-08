-- Minimal <Plug> definitions so mappings work even before setup() runs.
-- No default keymaps ship (R6.7): every action is reachable via these
-- mappings plus the :I18nHover / :I18nToggle / :I18nCheck commands.
vim.keymap.set('n', '<Plug>(i18n-inline-hover)', function()
  require('i18n-inline.hover').hover()
end, { silent = true, desc = 'i18n: per-language translations popover' })

vim.keymap.set('n', '<Plug>(i18n-inline-toggle)', function()
  local mode = require('i18n-inline.preview').toggle()
  vim.notify(('[i18n-inline] inline previews: %s'):format(mode), vim.log.levels.INFO)
end, { silent = true, desc = 'i18n: cycle inline display (always/problems/never)' })

vim.keymap.set('n', '<Plug>(i18n-inline-jump)', function()
  require('i18n-inline.jump').jump()
end, { silent = true, desc = 'i18n: open the translation file at the key under the cursor' })
