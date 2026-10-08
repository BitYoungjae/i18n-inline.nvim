-- :I18nJump — open the translation file at the key under the cursor.
--
-- The "see it" counterpart is the hover popover; this is the "edit it"
-- motion: land on the defining line so a fix is a keystroke away. Line
-- location is delegated to each format's find_line (raw-text search at jump
-- time — see formats.lua for why the decode cache cannot serve this).
--
-- Modes (config `jump.lang`, `jump.open`, or a one-shot override):
--   lang  = 'preview' (default) | 'source' | 'ask' (vim.ui.select)
--   open  = 'edit' (default) | 'split' | 'vsplit' | 'tab'
-- `:I18nJump!` / open='quickfix' fills the quickfix list with the key's
-- line in every language, for walking translations with :cnext.
--
-- When the target language lacks the key but the source language has it,
-- the source file opens instead with a warning — that is where the fix
-- starts.

local api = vim.api
local preview = require('i18n-inline.preview')
local resolve = require('i18n-inline.resolve')
local formats = require('i18n-inline.formats')
local util = require('i18n-inline.util')

local M = {}

local notify = util.notify

-- Ex command per open mode (`:tab {file}` is not a command — it would run
-- `:/{file}` as a search).
local OPEN_CMD = { edit = 'edit', split = 'split', vsplit = 'vsplit', tab = 'tabedit' }

-- Lines of a translation file: the loaded buffer when there is one (it may
-- hold unsaved edits, and that is the text the cursor will land in), else
-- the file on disk.
local function read_lines(path)
  -- exact name comparison: with no exact match, bufnr() falls back to
  -- file-pattern matching, where a `[locale]` path segment is a character
  -- class — an unopened `…/[locale]/ko.json` would pick up `…/l/ko.json`
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf) == path then
      return api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  local raw = util.read_file(path)
  return raw and vim.split(raw, '\r?\n')
end

-- lnum/col/len of `key` in `lang`'s file, or nil when the file has no line
-- for it (the key may still exist — minified files, unusual formatting).
local function locate(project, lang, key)
  local path = project.langs[lang]
  if not path then
    return nil
  end
  local lines = read_lines(path)
  if not lines then
    return nil
  end
  local fmt = formats.for_path(path, project.cfg)
  if not fmt or not fmt.find_line then
    return nil
  end
  return fmt.find_line(lines, key, project.cfg)
end

-- A buffer extmark, not matchaddpos: a match belongs to the window, so
-- jumping back (<C-o>) within the flash would paint it over the code buffer
-- at the translation file's coordinates.
local flash_ns = api.nvim_create_namespace('i18n_inline_flash')

local function flash(lnum, col, len)
  local buf = api.nvim_get_current_buf()
  local line = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ''
  local ok, id = pcall(api.nvim_buf_set_extmark, buf, flash_ns, lnum - 1, col - 1, {
    end_col = math.min(col - 1 + len, #line),
    hl_group = 'IncSearch',
  })
  if ok then
    vim.defer_fn(function()
      pcall(api.nvim_buf_del_extmark, buf, flash_ns, id)
    end, 800)
  end
end

-- Open `path` and put the cursor on (lnum, col), flashing `len` bytes.
-- Returns false when the file could not be opened (E37 and friends are
-- reported instead of raised).
local function open_at(open, path, lnum, col, len)
  local ok, err = pcall(vim.cmd, ('%s %s'):format(OPEN_CMD[open] or 'edit', vim.fn.fnameescape(path)))
  if not ok then
    notify(tostring(err):gsub('^Vim%(%w+%):', ''), vim.log.levels.ERROR)
    return false
  end
  lnum = math.min(lnum, api.nvim_buf_line_count(0))
  api.nvim_win_set_cursor(0, { lnum, math.max(0, col - 1) })
  vim.cmd('normal! zz')
  if len then
    flash(lnum, col, len)
  end
  return true
end

-- Jump to one language, with the missing->source fallback.
local function jump_lang(project, lang, key, open)
  local cfg = project.cfg
  if resolve.value(project, lang, key) ~= nil then
    local lnum, col, len = locate(project, lang, key)
    if lnum then
      open_at(open, project.langs[lang], lnum, col, len)
      return
    end
    -- Key exists but no line was located (minified/unusual file): open at top.
    if open_at(open, project.langs[lang], 1, 1) then
      notify(('opened %s — could not locate the line for %s'):format(vim.fs.basename(project.langs[lang]), key))
    end
    return
  end

  -- Missing in the target: point at the source of truth when possible.
  local src = cfg.source_lang
  if src and src ~= lang and resolve.value(project, src, key) ~= nil then
    local lnum, col, len = locate(project, src, key)
    if open_at(open, project.langs[src], lnum or 1, col or 1, len) then
      notify(('missing in %s — showing %s'):format(lang, src), vim.log.levels.WARN)
    end
    return
  end
  notify(('key %s not found in %s'):format(key, lang), vim.log.levels.WARN)
end

-- Quickfix variant: one item per language that has the key.
local function jump_quickfix(project, key)
  local items, missing = {}, {}
  for _, lang in ipairs(resolve.sorted_langs(project)) do
    local value = resolve.value(project, lang, key)
    if value == nil then
      missing[#missing + 1] = lang
    else
      local lnum, col = locate(project, lang, key)
      items[#items + 1] = {
        filename = project.langs[lang],
        lnum = lnum or 1,
        col = col or 1,
        text = ('%s  %s'):format(key, util.quote(value)),
      }
    end
  end
  if #items == 0 then
    notify(('key %s not found in any language'):format(key), vim.log.levels.WARN)
    return
  end
  vim.fn.setqflist({}, ' ', { title = 'i18n: ' .. key, items = items })
  vim.cmd('copen')
  if #missing > 0 then
    notify(('missing in: %s'):format(table.concat(missing, ', ')), vim.log.levels.WARN)
  end
end

---@param opts table|nil { bang = boolean, lang = string } — bang forces the
--- quickfix variant; lang overrides jump.lang for this jump (:I18nJump <lang>)
function M.jump(opts)
  opts = opts or {}
  local m, project, err = preview.current_match()
  if not m then
    notify(err)
    return
  end
  local cfg = project.cfg
  local jcfg = cfg.jump or {}
  local open = opts.bang and 'quickfix' or (jcfg.open or 'edit')

  if open == 'quickfix' then
    jump_quickfix(project, m.key)
    return
  end

  local lang
  if opts.lang then
    lang = opts.lang
  elseif jcfg.lang == 'ask' then
    vim.ui.select(resolve.sorted_langs(project), { prompt = 'i18n jump to language:' }, function(choice)
      if choice then
        jump_lang(project, choice, m.key, open)
      end
    end)
    return
  else
    lang = jcfg.lang == 'source' and cfg.source_lang or cfg.preview_lang
  end
  if not lang or not project.langs[lang] then
    notify(('no translation file for "%s" (available: %s)')
      :format(tostring(lang), table.concat(resolve.sorted_langs(project), ', ')), vim.log.levels.WARN)
    return
  end
  jump_lang(project, lang, m.key, open)
end

return M
