-- setup() 이전에도 매핑 가능하도록 <Plug> 만 최소 정의.
vim.keymap.set('n', '<Plug>(i18n-inline-hover)', function()
  require('i18n-inline.hover').hover()
end, { silent = true, desc = 'i18n 언어별 번역 팝오버' })
