-- Test runner (run from the repository root):
--   nvim --headless -u NORC +'luafile tests/run.lua'
-- Set I18N_SMOKE_REPO=/path/to/repo to also scan a real repository.
-- Note: plain `nvim -l` mode lacks quickfix APIs, so --headless is required
-- for the check() end-to-end test.

local src = debug.getinfo(1, 'S').source
local here = src:match('^@?(.*)/[^/]+$') or '.'
package.path = here .. '/../lua/?.lua;' .. here .. '/../lua/?/init.lua;' .. package.path

local uv = vim.uv
local api = vim.api

-- ===== tiny framework =====

local passed, failed = 0, 0
local failures = {}

local function t(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print(('  ok   %s'):format(name))
  else
    failed = failed + 1
    failures[#failures + 1] = { name = name, err = err }
    print(('  FAIL %s\n       %s'):format(name, err))
  end
end

local function eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(('%s\n  expected: %s\n  actual:   %s'):format(msg or 'not equal', vim.inspect(expected), vim.inspect(actual)))
  end
end

local function ok_(cond, msg)
  if not cond then
    error(msg or 'assertion failed')
  end
end

-- ===== temp project fixtures =====

local tmp_roots = {}

-- Create a temp project: <root>/.i18n-inline.json, <root>/tr/*.json, and
-- returns the root. `project_cfg` may be nil to skip the project file.
local function make_project(project_cfg, langs)
  local root = vim.fn.tempname() .. '-i18ntest-' .. tostring(#tmp_roots + 1)
  uv.fs_mkdir(root, 493)
  uv.fs_mkdir(root .. '/tr', 493)
  tmp_roots[#tmp_roots + 1] = root

  for lang, content in pairs(langs) do
    local fh = assert(io.open(('%s/tr/%s.json'):format(root, lang), 'w'))
    fh:write(vim.json.encode(content))
    fh:close()
  end
  if project_cfg then
    local fh = assert(io.open(root .. '/.i18n-inline.json', 'w'))
    fh:write(vim.json.encode(project_cfg))
    fh:close()
  end
  return root
end

-- ===== module loads =====

t('modules load', function()
  for _, m in ipairs({ 'config', 'util', 'scan', 'resolve', 'preview', 'hover', 'check' }) do
    ok_(type(require('i18n-inline.' .. m)) == 'table', 'failed to load i18n-inline.' .. m)
  end
end)

-- ===== util =====

t('util.build_line_offsets / byte_to_pos', function()
  local util = require('i18n-inline.util')
  local text = 'ab\ncde\nf'
  eq(util.build_line_offsets(text), { 1, 4, 8 })
  eq({ util.byte_to_pos({ 1, 4, 8 }, 1) }, { 0, 0 })
  eq({ util.byte_to_pos({ 1, 4, 8 }, 3) }, { 0, 2 })
  eq({ util.byte_to_pos({ 1, 4, 8 }, 4) }, { 1, 0 })
  eq({ util.byte_to_pos({ 1, 4, 8 }, 7) }, { 1, 3 })
  eq({ util.byte_to_pos({ 1, 4, 8 }, 8) }, { 2, 0 })
  eq({ util.byte_to_pos({ 1 }, 1) }, { 0, 0 })
end)

t('util.truncate respects rune boundaries', function()
  local util = require('i18n-inline.util')
  eq(util.truncate('hello', 10), 'hello')
  eq(util.truncate('hello', 3), 'hel…')
  local ko = '무료 체험 기간' -- 3-byte runes, third rune is a space
  eq(util.truncate(ko, 3), '무료 …')
  eq(util.truncate(ko, 100), ko)
  eq(util.truncate('a😀b', 2), 'a😀…') -- 4-byte rune must not split
  eq(util.truncate('abc', 0), '')
end)

t('util.display_value sanitizes control characters', function()
  local util = require('i18n-inline.util')
  eq(util.display_value('a\nb'), 'a ⏎ b')
  eq(util.display_value('a\r\nb'), 'a ⏎ b')
  eq(util.display_value('a\tb'), 'a b')
  eq(util.display_value(42), '42')
end)

-- ===== scan =====

local SAMPLE = table.concat({
  '(def a (tr [:k-match "Confirm"]))',
  '(def b (tr [:k-multiline',
  '              "spans lines"]))',
  '(def c (tr-release [:k-release "release"]))',
  '(def d (i18n/tr-release [:k-alias "alias"]))',
  '(transient [:not-i18n "nope"])',
  '(traverse [:also-not "nope"])',
  '(def e (tr [:k-nofb]))',
  '(def f (tr [:k-esc "quote \\" inside"]))',
  '(def g (tr [:k-params "{n} items"] {:n 3}))',
}, '\n')

t('scan finds all call variants and rejects false positives', function()
  local scan = require('i18n-inline.scan')
  local patterns = {
    '%(tr%s*%[%s*:([%w%.%-_/]+)',
    '%(tr%-release%s*%[%s*:([%w%.%-_/]+)',
    '%(i18n/tr%s*%[%s*:([%w%.%-_/]+)',
    '%(i18n/tr%-release%s*%[%s*:([%w%.%-_/]+)',
  }
  local ms = scan.scan(SAMPLE, patterns)
  local keys = {}
  for _, m in ipairs(ms) do
    keys[#keys + 1] = m.key
  end
  table.sort(keys)
  eq(keys, { 'k-alias', 'k-esc', 'k-match', 'k-multiline', 'k-nofb', 'k-params', 'k-release' })
end)

t('scan parses multiline fallback and escapes', function()
  local scan = require('i18n-inline.scan')
  local ms = scan.scan(SAMPLE, { '%(tr%s*%[%s*:([%w%.%-_/]+)' })
  local by_key = {}
  for _, m in ipairs(ms) do
    by_key[m.key] = m
  end
  eq(by_key['k-multiline'].fb, 'spans lines')
  eq(by_key['k-esc'].fb, 'quote " inside')
  eq(by_key['k-nofb'].fb, nil)
  eq(by_key['k-params'].fb, '{n} items')
end)

t('scan.parse_string_literal single quotes and unterminated', function()
  local scan = require('i18n-inline.scan')
  local content, s, e = scan.parse_string_literal("t('it\\'s', 1)", 3)
  eq(content, "it's")
  eq(s, 3)
  eq(e, 9)
  ok_(scan.parse_string_literal('no quote', 1) == nil)
  ok_(scan.parse_string_literal('"unterminated\n', 1) == nil)
end)

t('scan.status classification', function()
  local scan = require('i18n-inline.scan')
  local keys = { same = 'v', diff = 'x', num = 7 }
  eq({ scan.status({ key = 'same', fb = 'v' }, keys) }, { 'match', 'v' })
  eq({ scan.status({ key = 'diff', fb = 'y' }, keys) }, { 'mismatch', 'x' })
  eq({ scan.status({ key = 'absent', fb = 'y' }, keys) }, { 'missing', nil })
  eq({ scan.status({ key = 'diff' }, keys) }, { 'novalue', 'x' })
  eq({ scan.status({ key = 'num', fb = '7' }, keys) }, { 'match', '7' })
  eq({ scan.status({ key = 'same', fb = 'v' }, nil) }, { 'missing', nil })
end)

-- ===== config =====

t('config.merge_project overrides and validates', function()
  local config = require('i18n-inline.config')
  config.reset()
  local merged, err = config.merge_project({ dir = 'x', preview_lang = 'en' })
  ok_(merged ~= nil, err)
  eq(merged.dir, 'x')
  eq(merged.preview_lang, 'en')
  eq(merged.prefix, '  ') -- default survives

  local _, err2 = config.merge_project({ patterns = { 42 } })
  ok_(err2:match('patterns') ~= nil, 'expected validation error, got: ' .. tostring(err2))

  local _, err3 = config.merge_project({ file_template = '%s.json' })
  ok_(err3:match('languages') ~= nil)
end)

-- ===== resolve + project file =====

t('resolve: project file discovered and merged', function()
  local resolve = require('i18n-inline.resolve')
  resolve.reset()
  local root = make_project({ dir = 'tr', preview_lang = 'ko' }, {
    ko = { hello = '안녕' },
    en = { hello = 'Hello' },
  })
  local project = resolve.project_from(root .. '/src/app/core.cljs')
  ok_(project ~= nil, 'project not found')
  eq(project.dir, vim.fs.normalize(root .. '/tr'))
  eq(project.cfg.preview_lang, 'ko')

  local keys = resolve.ensure_lang(project, 'ko')
  eq(keys.hello, '안녕')
  local en = resolve.ensure_lang(project, 'en')
  eq(en.hello, 'Hello')

  -- missing language file
  local _, err = resolve.ensure_lang(project, 'fr')
  ok_(err:match('fr') ~= nil)
end)

t('resolve: falls back to setup dir without project file', function()
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  config.setup({ dir = 'tr', preview_lang = 'ko' })
  resolve.reset()
  local root = make_project(nil, { ko = { k = 'v' } })
  local project = resolve.project_from(root .. '/deep/nested/file.cljs')
  ok_(project ~= nil)
  eq(project.root, vim.fs.normalize(root))
  ok_(project.config_file == nil)
  config.reset()
end)

t('resolve: no dir anywhere -> nil project', function()
  local resolve = require('i18n-inline.resolve')
  local config = require('i18n-inline.config')
  config.reset()
  resolve.reset()
  local root = make_project(nil, {}) -- no project file, dir default nil
  ok_(resolve.project_from(root .. '/a/b.cljs') == nil)
end)

-- ===== preview E2E (real buffer, real extmarks) =====

t('preview: renders virtual text with per-status styling', function()
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  local preview = require('i18n-inline.preview')
  config.reset()
  resolve.reset()
  preview._reset()

  local root = make_project({ dir = 'tr', preview_lang = 'ko', patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' } }, {
    ko = {
      ['p-match'] = '동일',
      ['p-diff'] = '파일 값',
      ['p-missing'] = nil,
      ['p-nofb'] = '값 있음',
    },
  })

  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, root .. '/src/app.cljs')
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    '(tr [:p-match "동일"])',
    '(tr [:p-diff',
    '     "코드 값"])',
    '(tr [:p-missing "코드 값"])',
    '(tr [:p-nofb])',
  })
  vim.bo[buf].filetype = 'clojure'

  preview.refresh(buf)

  local st = preview.state(buf)
  ok_(st and st.matches, 'no state')
  eq(#st.matches, 4)

  local by_key = {}
  for _, m in ipairs(st.matches) do
    by_key[m.key] = m
  end
  eq(by_key['p-match'].status, 'match')
  eq(by_key['p-diff'].status, 'mismatch')
  eq(by_key['p-missing'].status, 'missing')
  eq(by_key['p-nofb'].status, 'novalue')

  -- multiline call: key row 1, fallback closes row 2
  eq(by_key['p-diff'].row_start, 1)
  eq(by_key['p-diff'].row_end, 2)

  local ns = api.nvim_get_namespaces()['i18n_inline']
  local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })

  local virt = {}
  local underlines = 0
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.virt_text then
      virt[#virt + 1] = { row = m[2], text = d.virt_text[1][1], hl = d.virt_text[1][2] }
    end
    if d.hl_group then
      underlines = underlines + 1
    end
  end
  eq(#virt, 4)
  table.sort(virt, function(a, b)
    return a.row < b.row
  end)
  eq(virt[1].text, '  동일')
  eq(virt[1].hl, 'Comment')
  eq(virt[2].text, '  ≠ 파일 값')
  eq(virt[2].hl, 'DiagnosticWarn')
  eq(virt[3].text, '  ✗ key not found')
  eq(virt[3].hl, 'DiagnosticError')
  eq(virt[4].text, '  값 있음')
  eq(underlines, 1) -- only the mismatch gets underlined

  api.nvim_buf_delete(buf, { force = true })
end)

t('preview: text change re-renders with stable mark count', function()
  local preview = require('i18n-inline.preview')
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  config.reset()
  resolve.reset()
  preview._reset()

  local root = make_project({ dir = 'tr', patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' } }, {
    ko = { a = 'va', b = 'vb', c = 'vc' },
  })
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, root .. '/src/x.cljs')
  api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:a "va"])', '(tr [:b "vb"])' })
  vim.bo[buf].filetype = 'clojure'
  preview.refresh(buf)

  local ns = api.nvim_get_namespaces()['i18n_inline']
  local count = function()
    local ms = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local n = 0
    for _, m in ipairs(ms) do
      if m[4].virt_text then
        n = n + 1
      end
    end
    return n
  end
  eq(count(), 2)

  api.nvim_buf_set_lines(buf, 0, 1, false, {}) -- remove first call
  preview.refresh(buf)
  eq(count(), 1)
  api.nvim_buf_delete(buf, { force = true })
end)

-- ===== hover E2E =====

t('hover: popover lists every language', function()
  local preview = require('i18n-inline.preview')
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  local hover = require('i18n-inline.hover')
  config.reset()
  resolve.reset()
  preview._reset()

  local root = make_project({ dir = 'tr', preview_lang = 'ko', patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' } }, {
    ko = { h = '확인' },
    en = { h = 'Confirm' },
    ja = { h = '確認' },
  })
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, root .. '/src/h.cljs')
  api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:h "확인"])', '(tr [:h2 "다른"]))' })
  vim.bo[buf].filetype = 'clojure'
  preview.refresh(buf)

  local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 60, height = 5 })
  api.nvim_win_set_cursor(win, { 1, 3 })

  local hover_ok, hover_err = pcall(hover.hover)

  -- Neovim 0.12 normalizes relative='cursor' to 'win' in the window config,
  -- so identify the popover by its content instead.
  local float_win, float_content
  for _, w in ipairs(api.nvim_list_wins()) do
    local cfgw = api.nvim_win_get_config(w)
    if cfgw.relative ~= '' and cfgw.relative ~= 'editor' then
      local wbuf = api.nvim_win_get_buf(w)
      local wlines = table.concat(api.nvim_buf_get_lines(wbuf, 0, -1, false), '\n')
      if wlines:match('fallback:') then
        float_win, float_content = w, wlines
      end
    end
  end

  -- cleanup first, so a failure here cannot poison later tests
  if float_win and api.nvim_win_is_valid(float_win) then
    api.nvim_win_close(float_win, true)
  end
  api.nvim_win_close(win, true)
  api.nvim_buf_delete(buf, { force = true })

  ok_(hover_ok, tostring(hover_err))
  ok_(float_win ~= nil, 'no floating window opened')
  ok_(float_content ~= nil and float_content:match('Confirm') ~= nil,
    'en value missing:\n' .. tostring(float_content))
  ok_(float_content ~= nil and float_content:match('確認') ~= nil,
    'ja value missing:\n' .. tostring(float_content))
  ok_(float_content ~= nil and float_content:match('fallback:') ~= nil)
end)

-- ===== check E2E =====

t('check: audit fills quickfix with mismatches', function()
  local preview = require('i18n-inline.preview')
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  local check = require('i18n-inline.check')
  config.reset()
  resolve.reset()
  preview._reset()

  local root = make_project({
    dir = 'tr',
    preview_lang = 'ko',
    patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
    check = { extensions = { 'cljs' } },
  }, {
    ko = { good = 'ok', bad = 'file', gone = 'unused', ['never-used'] = 'x' },
  })
  -- source file with a match, a mismatch, and a missing key
  local srcdir = root .. '/src'
  uv.fs_mkdir(srcdir, 493)
  local fh = assert(io.open(srcdir .. '/a.cljs', 'w'))
  fh:write('(tr [:good "ok"])\n(tr [:bad "code"])\n(tr [:nope "whatever"])\n')
  fh:close()

  -- a buffer inside the project so project_for works
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, srcdir .. '/probe.cljs')
  api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:good "ok"])' })
  vim.bo[buf].filetype = 'clojure'

  check.check(buf)
  local done = vim.wait(5000, function()
    return #vim.fn.getqflist() >= 2
  end, 50)
  ok_(done, 'quickfix never filled')

  local items = vim.fn.getqflist()
  eq(#items, 2)
  table.sort(items, function(a, b)
    return a.text < b.text
  end)
  -- 'mismatch …' sorts before 'missing key …'
  ok_(items[1].text:match('mismatch :bad') ~= nil, items[1].text)
  ok_(items[2].text:match('missing key :nope') ~= nil, items[2].text)
  ok_(items[1].lnum >= 1)

  api.nvim_buf_delete(buf, { force = true })
end)

-- ===== real-repo smoke (optional) =====

local smoke_repo = os.getenv('I18N_SMOKE_REPO')
if smoke_repo and smoke_repo ~= '' then
  t(('smoke: scan real repo %s'):format(smoke_repo), function()
    local scan = require('i18n-inline.scan')
    local util = require('i18n-inline.util')
    local repo = smoke_repo

    local files = {}
    local function walk(d)
      local fs = uv.fs_scandir(d)
      if not fs then
        return
      end
      while true do
        local name, ftype = uv.fs_scandir_next(fs)
        if not name then
          break
        end
        local p = d .. '/' .. name
        if ftype == 'directory' then
          walk(p)
        elseif name:match('%.cljs$') then
          files[#files + 1] = p
        end
      end
    end
    walk(repo .. '/src/cljs')

    local fh = assert(io.open(repo .. '/src/tr/cljs/ko.json'))
    local ko = vim.json.decode(fh:read('*a'))
    fh:close()

    local patterns = {
      '%(tr%s*%[%s*:([%w%.%-_/]+)',
      '%(tr%-release%s*%[%s*:([%w%.%-_/]+)',
      '%(i18n/tr%s*%[%s*:([%w%.%-_/]+)',
      '%(i18n/tr%-release%s*%[%s*:([%w%.%-_/]+)',
    }

    local t0 = uv.hrtime()
    local total, mismatch, missing = 0, 0, 0
    for _, f in ipairs(files) do
      local fh2 = io.open(f, 'r')
      if fh2 then
        local text = fh2:read('*a')
        fh2:close()
        for _, m in ipairs(scan.scan(text, patterns)) do
          total = total + 1
          local status = scan.status(m, ko)
          if status == 'mismatch' then
            mismatch = mismatch + 1
          elseif status == 'missing' then
            missing = missing + 1
          end
        end
      end
    end
    local ms = (uv.hrtime() - t0) / 1e6
    print(('       scanned %d files: %d calls, %d mismatches, %d missing (%.0f ms)')
      :format(#files, total, mismatch, missing, ms))
    ok_(total > 1000, ('too few matches: %d'):format(total))
    ok_(mismatch > 0, 'expected some mismatches in the real repo')
    ok_(ms < 10000, 'scan too slow')
  end)
end

-- ===== summary =====

print(('\n%d passed, %d failed'):format(passed, failed))
for _, root in ipairs(tmp_roots) do
  -- best-effort cleanup of temp dirs
  os.execute(('rm -rf %s'):format(vim.fn.shellescape(root)))
end
os.exit(failed > 0 and 1 or 0)
