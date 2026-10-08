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

local M = {}

local function notify(msg, level)
  vim.notify('[i18n-inline] ' .. msg, level or vim.log.levels.INFO)
end

local function read_lines(path)
  local fh = io.open(path, 'r')
  if not fh then
    return nil
  end
  local lines = {}
  for l in fh:lines() do
    lines[#lines + 1] = l
  end
  fh:close()
  return lines
end

-- lnum/col of `key` in `lang`'s file, or nil when the file has no line for
-- it (the key may still exist — minified files, unusual formatting).
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

local function flash(lnum, col, len)
  local ok, mid = pcall(vim.fn.matchaddpos, 'IncSearch', { { lnum, col, len } })
  if ok then
    local win = api.nvim_get_current_win()
    vim.defer_fn(function()
      pcall(vim.fn.matchdelete, mid, win)
    end, 800)
  end
end

local function open_at(open, path, lnum, col, key)
  vim.cmd(('%s %s'):format(open == 'edit' and 'edit' or open, vim.fn.fnameescape(path)))
  api.nvim_win_set_cursor(0, { lnum, math.max(0, col - 1) })
  vim.cmd('normal! zz')
  flash(lnum, col, #key + 2) -- include the quotes
end

-- Jump to one language, with the missing->source fallback.
local function jump_lang(project, lang, key, open)
  local cfg = project.cfg
  local keys = resolve.ensure_lang(project, lang)
  if keys and keys[key] ~= nil and keys[key] ~= vim.NIL then
    local lnum, col = locate(project, lang, key)
    if lnum then
      open_at(open, project.langs[lang], lnum, col, key)
      return
    end
    -- Key exists but no line was located (minified/unusual file): open at top.
    open_at(open, project.langs[lang], 1, 1, key)
    notify(('opened %s — could not locate the line for %s'):format(vim.fs.basename(project.langs[lang]), key))
    return
  end

  -- Missing in the target: point at the source of truth when possible.
  local src = cfg.source_lang
  if src and src ~= lang then
    local skeys = resolve.ensure_lang(project, src)
    if skeys and skeys[key] ~= nil and skeys[key] ~= vim.NIL then
      local lnum, col = locate(project, src, key)
      open_at(open, project.langs[src], lnum or 1, col or 1, key)
      notify(('missing in %s — showing %s'):format(lang, src), vim.log.levels.WARN)
      return
    end
  end
  notify(('key %s not found in %s'):format(key, lang), vim.log.levels.WARN)
end

-- Quickfix variant: one item per language that has the key.
local function jump_quickfix(project, key)
  local items, missing = {}, {}
  local langs = {}
  for lang in pairs(project.langs) do
    langs[#langs + 1] = lang
  end
  table.sort(langs)
  for _, lang in ipairs(langs) do
    local keys = resolve.ensure_lang(project, lang)
    local value = keys and keys[key] or nil
    if value == vim.NIL then
      value = nil
    end
    if value == nil then
      missing[#missing + 1] = lang
    else
      local lnum, col = locate(project, lang, key)
      items[#items + 1] = {
        filename = project.langs[lang],
        lnum = lnum or 1,
        col = col or 1,
        text = key,
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

---@param opts table|nil { bang = boolean } — bang forces the quickfix variant
function M.jump(opts)
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local m = preview.match_at(buf, row)
  if not m then
    notify('no i18n call under the cursor')
    return
  end

  local st = preview.state(buf)
  local project = st and st.project
  if not project then
    notify('no translation project for this buffer', vim.log.levels.WARN)
    return
  end
  local cfg = project.cfg
  local jcfg = cfg.jump or {}
  local open = opts.bang and 'quickfix' or (jcfg.open or 'edit')

  if open == 'quickfix' then
    jump_quickfix(project, m.key)
    return
  end

  local lang_mode = jcfg.lang or 'preview'
  if lang_mode == 'ask' then
    local langs = {}
    for lang in pairs(project.langs) do
      langs[#langs + 1] = lang
    end
    table.sort(langs, function(a, b)
      if a == cfg.preview_lang then
        return true
      end
      if b == cfg.preview_lang then
        return false
      end
      return a < b
    end)
    vim.ui.select(langs, { prompt = 'i18n jump to language:' }, function(choice)
      if choice then
        jump_lang(project, choice, m.key, open)
      end
    end)
    return
  end

  local lang = lang_mode == 'source' and cfg.source_lang or cfg.preview_lang
  if not lang or not project.langs[lang] then
    notify(('no translation file for jump.lang=%s'):format(tostring(lang)), vim.log.levels.WARN)
    return
  end
  jump_lang(project, lang, m.key, open)
end

return M
