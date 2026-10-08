-- Neovim config for the README recordings: a plain, believable setup
-- (tokyonight, lualine, tree-sitter highlighting) around this plugin.
--
-- Third-party plugins are borrowed from an existing install instead of
-- being vendored: DEMO_PLUGINS points at a lazy.nvim-style directory
-- (default ~/.local/share/nvim/lazy) holding tokyonight.nvim, lualine.nvim,
-- nvim-web-devicons and nvim-treesitter (queries only); DEMO_PARSERS at a
-- directory whose parser/ holds tsx, typescript, json and python.

local here = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local root = vim.fs.dirname(here)
local plugins = vim.env.DEMO_PLUGINS or vim.fn.stdpath('data') .. '/lazy'
local parsers = vim.env.DEMO_PARSERS or vim.fn.stdpath('data') .. '/site'

for _, p in ipairs({
  root,
  plugins .. '/tokyonight.nvim',
  plugins .. '/lualine.nvim',
  plugins .. '/nvim-web-devicons',
  plugins .. '/nvim-treesitter/runtime',
  parsers,
}) do
  vim.opt.rtp:append(p)
end

vim.g.mapleader = ' '
vim.o.termguicolors = true
vim.o.number = true
vim.o.cursorline = true
vim.o.signcolumn = 'yes'
vim.o.laststatus = 3
vim.o.showmode = false
vim.o.showcmd = false -- keystrokes are captioned instead
vim.o.ruler = false
vim.o.shortmess = vim.o.shortmess .. 'IFW'
vim.o.swapfile = false
vim.o.shada = ''
vim.o.wrap = false
vim.o.scrolloff = 4
vim.o.fillchars = 'eob: '
vim.o.splitright = true
-- the window title in the recordings comes from Neovim, like a terminal's
vim.o.title = true
vim.o.titlestring = '%t — %{fnamemodify(getcwd(), ":~")}'
vim.o.expandtab = true
vim.o.shiftwidth = 2

require('tokyonight').setup({ style = 'night' })
vim.cmd.colorscheme('tokyonight-night')

require('lualine').setup({
  options = { theme = 'tokyonight', globalstatus = true, section_separators = { left = '', right = '' } },
  sections = {
    lualine_b = {},
    lualine_c = { { 'filename', path = 1 } },
    lualine_x = { 'filetype' },
    lualine_y = { 'progress' },
    lualine_z = { 'location' },
  },
  extensions = { 'quickfix' },
})

-- nvim-treesitter normally registers these; only its queries are loaded here
vim.treesitter.language.register('tsx', 'typescriptreact')

vim.api.nvim_create_autocmd('FileType', {
  callback = function(ev)
    pcall(vim.treesitter.start, ev.buf)
  end,
})

require('i18n-inline').setup({
  keymaps = { hover = '<leader>ii', jump = '<leader>ij', toggle = '<leader>ui' },
})
