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

-- vim.ui.select, as a small floating list. The built-in draws a numbered
-- list in the message area, which scrolls the buffer up and leaves a
-- hit-enter prompt behind; a float stands in for the picker a reader would
-- already have (telescope, fzf-lua, snacks). Recordings only: the plugin
-- calls plain vim.ui.select.
--
-- The float never takes focus, so the window title and the statusline keep
-- showing the file; j/k/<CR>/<Esc> are mapped for as long as it is up.
vim.ui.select = function(items, opts, on_choice)
  opts = opts or {}
  local format_item = opts.format_item or tostring
  local lines = {}
  local width = vim.fn.strdisplaywidth(opts.prompt or '') + 2
  for i, item in ipairs(items) do
    lines[i] = '  ' .. format_item(item) .. '  '
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = vim.o.lines - #lines - 4, -- clear of the statusline
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    style = 'minimal',
    border = 'rounded',
    title = opts.prompt and (' ' .. opts.prompt .. ' ') or nil,
    title_pos = 'center',
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = 'CursorLine:PmenuSel'

  local sel, mapped = 1, {}
  local function finish(chosen)
    for _, lhs in ipairs(mapped) do
      pcall(vim.keymap.del, 'n', lhs)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    on_choice(chosen and items[sel] or nil, chosen and sel or nil)
  end
  local function map(lhs, fn)
    mapped[#mapped + 1] = lhs
    vim.keymap.set('n', lhs, fn)
  end
  for lhs, step in pairs({ j = 1, ['<Down>'] = 1, k = -1, ['<Up>'] = -1 }) do
    map(lhs, function()
      sel = math.max(1, math.min(#items, sel + step))
      vim.api.nvim_win_set_cursor(win, { sel, 0 })
    end)
  end
  map('<CR>', function()
    finish(true)
  end)
  for _, lhs in ipairs({ '<Esc>', 'q' }) do
    map(lhs, function()
      finish(false)
    end)
  end
end

require('i18n-inline').setup({
  keymaps = { hover = '<leader>ii', jump = '<leader>ij', toggle = '<leader>ui', lang = '<leader>il' },
})
