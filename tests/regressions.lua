-- Regression tests for the review pass: one test per defect found and
-- reproduced before fixing (see DESIGN.md "Review pass" for the list).
--
-- Loaded by run.lua, which provides the framework (t/eq/ok_) and
-- make_project; `plugin_dir` is the repository root (for sourcing
-- plugin/i18n-inline.lua).

local uv = vim.uv
local api = vim.api

return function(t, eq, ok_, make_project, plugin_dir)
  local scan = require('i18n-inline.scan')
  local formats = require('i18n-inline.formats')
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  local preview = require('i18n-inline.preview')
  local hover = require('i18n-inline.hover')
  local jump = require('i18n-inline.jump')
  local check = require('i18n-inline.check')

  local CLJ = { '%(tr%s*%[%s*:([%w%.%-_/]+)' }

  local function reset_all()
    hover.close()
    config.reset()
    resolve.reset()
    preview._reset()
  end

  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local fh = assert(io.open(path, 'w'))
    fh:write(content)
    fh:close()
  end

  -- A listed buffer named `path` holding `lines`, shown in a fresh window.
  local function open_buf(path, lines, ft)
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, path)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = ft
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 80, height = 5 })
    return buf, win
  end

  local function floats()
    local n = 0
    for _, w in ipairs(api.nvim_list_wins()) do
      local c = api.nvim_win_get_config(w)
      if c.relative ~= '' and not c.focusable then
        n = n + 1
      end
    end
    return n
  end

  -- Run fn with cwd = dir, restoring cwd even when fn fails.
  local function in_dir(dir, fn)
    local prev = uv.cwd()
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local ok, err = pcall(fn)
    vim.cmd.cd(vim.fn.fnameescape(prev))
    if not ok then
      error(err, 0)
    end
  end

  local function wipe(...)
    for _, b in ipairs({ ... }) do
      if api.nvim_buf_is_valid(b) then
        api.nvim_buf_delete(b, { force = true })
      end
    end
  end

  -- ===== project resolution =====

  t('regression: relative dir resolves against the project file, not a nearer same-named dir', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'root' } })
    write(root .. '/src/tr/ko.json', '{"a":"nested"}')
    local p = resolve.project_from(root .. '/src')
    eq(p.catalogs[1].dir, vim.fs.normalize(root .. '/tr'))
    eq(resolve.ensure_lang(p.catalogs[1], 'ko').a, 'root')
  end)

  t('regression: setup-only dir walk-up skips files with the dir name', function()
    reset_all()
    config.setup({ dir = 'tr' })
    local root = make_project(nil, { ko = { a = 'v' } })
    write(root .. '/sub/tr', 'not a directory')
    local p = resolve.project_from(root .. '/sub')
    ok_(p ~= nil, 'project not found')
    eq(p.catalogs[1].dir, vim.fs.normalize(root .. '/tr'))
  end)

  t('regression: languages restricts discovered files', function()
    reset_all()
    local root = make_project({ dir = 'tr', languages = { 'ko', 'en' }, patterns = CLJ }, {
      ko = {},
      en = {},
      ja = {},
    })
    local p = resolve.project_from(root)
    eq(resolve.sorted_langs(p.catalogs[1]), { 'ko', 'en' })
  end)

  t('regression: unnamed buffer resolves from cwd itself', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = {} })
    local buf = api.nvim_create_buf(true, false)
    local found
    in_dir(root, function()
      found = resolve.project_for(buf) ~= nil
    end)
    wipe(buf)
    ok_(found, 'project in cwd not found for an unnamed buffer')
  end)

  t('regression: sorted_langs puts preview, then source, then alphabetical', function()
    reset_all()
    local root = make_project({ dir = 'tr', preview_lang = 'ko', source_lang = 'en', patterns = CLJ }, {
      ja = {},
      en = {},
      ko = {},
      de = {},
    })
    eq(resolve.sorted_langs(resolve.project_from(root).catalogs[1]), { 'ko', 'en', 'de', 'ja' })
  end)

  -- ===== formats / decode contract =====

  t('regression: decoded maps are string-valued (numbers, nulls, flat-mode objects)', function()
    local raw = '{"n": 3, "b": true, "z": null, "s": "x", "obj": {"k": "v"}}'
    eq(formats.registry.json.decode(raw, { key_style = 'flat' }), { n = '3', b = 'true', s = 'x' })
    eq(
      formats.registry.json.decode(raw, { key_style = 'nested', separator = '.' }),
      { n = '3', b = 'true', s = 'x', ['obj.k'] = 'v' }
    )
  end)

  -- ===== config =====

  t('regression: empty lists are valid (namespace_patterns, aliases) and clear presets', function()
    reset_all()
    local cfg, err = config.merge_project({ preset = 'next-intl', namespace_patterns = {}, aliases = {} })
    ok_(cfg ~= nil, err)
    eq(#cfg.namespace_patterns, 0)
    eq(#cfg.aliases, 0)
  end)

  t('regression: type errors and unknown keys are reported', function()
    reset_all()
    local _, e1 = config.merge_project({ position = 'right_align' })
    ok_(e1 and e1:match('position'), tostring(e1))
    local _, e2 = config.merge_project({ max_len = '60' })
    ok_(e2 and e2:match('max_len must be a number'), tostring(e2))
    local _, e3 = config.merge_project({ preview_lang = { 'ko' } })
    ok_(e3 and e3:match('preview_lang must be a string'), tostring(e3))
    eq(config.unknown_keys({ preview_language = 'ko', dir = 'x', check = { ignored = {} }, ['$schema'] = 'x', ['//'] = 'note' }), {
      'check.ignored',
      'preview_language',
    })
  end)

  -- ===== presets =====

  t('regression: gettext keys keep apostrophes and the other quote style', function()
    reset_all()
    local cfg = config.merge_project({ preset = 'gettext' })
    local keys = {}
    for _, m in ipairs(scan.scan([[_("Don't panic"); _('Say "hi"'); _("plain")]], cfg)) do
      keys[#keys + 1] = m.key
    end
    eq(keys, { "Don't panic", 'Say "hi"', 'plain' })
  end)

  -- ===== cursor-aware match lookup =====

  t('regression: hover/jump pick the call under the cursor column', function()
    reset_all()
    local root = make_project({ preset = 'next-intl', dir = 'm', preview_lang = 'ko' }, {
      ko = { a = 'A', b = 'B' },
    }, 'm')
    local line = "const t = useTranslations(); <p>{t('a')} {t('b')}</p>"
    local buf, win = open_buf(root .. '/x.tsx', { line }, 'typescriptreact')
    preview.refresh(buf)
    local col_b = line:find("t%('b'%)") - 1
    local col_a = line:find("t%('a'%)") - 1
    eq(preview.match_at(buf, 0, col_b + 2).key, 'b') -- inside t('b')
    eq(preview.match_at(buf, 0, col_a).key, 'a')
    eq(preview.match_at(buf, 0, #line - 1).key, 'b') -- after both: nearest
    eq(preview.match_at(buf, 0, 0).key, 'a') -- before both: nearest
    api.nvim_win_set_cursor(win, { 1, col_b + 2 })
    local m = preview.current_match()
    eq(m.key, 'b')
    api.nvim_win_close(win, true)
    wipe(buf)
  end)

  t('regression: current_match re-scans a buffer edited since the last refresh', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'A', b = 'B' } })
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "A"])' }, 'clojure')
    preview.refresh(buf)
    -- edit without a refresh (the debounce window)
    api.nvim_buf_set_lines(buf, 0, 0, false, { '(tr [:b "B"])' })
    api.nvim_win_set_cursor(win, { 1, 3 })
    local m = preview.current_match()
    eq(m and m.key, 'b')
    api.nvim_win_close(win, true)
    wipe(buf)
  end)

  -- ===== hover =====

  t('regression: a second hover replaces the first popover (no leak)', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'A' } })
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "A"])' }, 'clojure')
    preview.refresh(buf)
    api.nvim_win_set_cursor(win, { 1, 3 })
    local base = floats()
    hover.hover()
    hover.hover()
    eq(floats() - base, 1)
    api.nvim_exec_autocmds('CursorMoved', {})
    eq(floats() - base, 0)
    api.nvim_win_close(win, true)
    wipe(buf)
  end)

  t('regression: hover mismatch highlight follows normalize like the inline status', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ, normalize = 'placeholders' }, {
      ko = { a = '{{n}} items', b = 'other' },
    })
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "{n} items"])', '(tr [:b "code"])' }, 'clojure')
    preview.refresh(buf)
    local function label_hl(row)
      api.nvim_win_set_cursor(win, { row, 3 })
      hover.hover()
      local hl
      for _, w in ipairs(api.nvim_list_wins()) do
        local c = api.nvim_win_get_config(w)
        if c.relative ~= '' and not c.focusable then
          local ns = api.nvim_get_namespaces()['i18n_inline_hover']
          local marks = api.nvim_buf_get_extmarks(api.nvim_win_get_buf(w), ns, 0, -1, { details = true })
          hl = marks[1] and marks[1][4].hl_group
        end
      end
      hover.close()
      return hl
    end
    eq(label_hl(1), 'Comment') -- placeholder-only difference: not drift
    eq(label_hl(2), 'I18nInlineMismatch')
    api.nvim_win_close(win, true)
    wipe(buf)
  end)

  -- ===== keymaps =====

  t('regression: keymaps come back after the buffer is cleared and re-resolved', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ, keymaps = { hover = '<leader>Zh' } }, { ko = { a = 'v' } })
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "v"])' }, 'clojure')
    local mapped = function()
      return vim.fn.maparg('<leader>Zh', 'n') ~= ''
    end
    preview.refresh(buf)
    ok_(mapped(), 'not mapped initially')
    vim.bo[buf].filetype = 'text'
    preview.refresh(buf)
    ok_(not mapped(), 'still mapped after leaving the filetype')
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)
    ok_(mapped(), 'not re-mapped after re-resolve')
    api.nvim_win_close(win, true)
    wipe(buf)
  end)

  -- ===== jump =====

  t('regression: jump.open = "tab" opens the file in a new tab', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ, jump = { open = 'tab' } }, { ko = { a = 'v' } })
    write(root .. '/tr/ko.json', '{\n  "a": "v"\n}\n')
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "v"])' }, 'clojure')
    preview.refresh(buf)
    api.nvim_win_set_cursor(win, { 1, 3 })
    local tabs = #api.nvim_list_tabpages()
    jump.jump()
    eq(#api.nvim_list_tabpages(), tabs + 1)
    ok_(api.nvim_buf_get_name(0):match('tr/ko%.json$'), api.nvim_buf_get_name(0))
    eq(api.nvim_win_get_cursor(0), { 2, 2 })
    local target = api.nvim_get_current_buf()
    vim.cmd('tabclose')
    api.nvim_win_close(win, true)
    wipe(buf, target)
  end)

  t('regression: jump locates the key in the loaded (unsaved) buffer text', function()
    reset_all()
    -- `[locale]`: a file-pattern character class if a lookup ever goes
    -- through bufnr()-style pattern matching
    local root = make_project({ dir = '[locale]', patterns = CLJ }, { ko = { a = 'v' } }, '[locale]')
    write(root .. '/[locale]/ko.json', '{\n  "a": "v"\n}\n')
    local tbuf = vim.fn.bufadd(root .. '/[locale]/ko.json')
    vim.fn.bufload(tbuf)
    api.nvim_buf_set_lines(tbuf, 1, 1, false, { '  "new1": "x",', '  "new2": "y",' }) -- unsaved
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "v"])' }, 'clojure')
    preview.refresh(buf)
    api.nvim_win_set_cursor(win, { 1, 3 })
    jump.jump()
    eq(api.nvim_get_current_buf(), tbuf)
    eq(api.nvim_win_get_cursor(0), { 4, 2 })
    api.nvim_win_close(win, true)
    wipe(tbuf)

    -- target not loaded, but a buffer matching `[locale]` as a pattern is:
    -- its lines must not be used
    local decoy = vim.fn.bufadd(root .. '/l/ko.json')
    vim.fn.bufload(decoy)
    api.nvim_buf_set_lines(decoy, 0, -1, false, { '{', '', '', '', '', '  "a": "decoy"', '}' })
    win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 80, height = 5 })
    api.nvim_win_set_cursor(win, { 1, 3 })
    jump.jump()
    ok_(api.nvim_buf_get_name(0):match('%[locale%]/ko%.json$'), api.nvim_buf_get_name(0))
    eq(api.nvim_win_get_cursor(0), { 2, 2 })
    local opened = api.nvim_get_current_buf()
    api.nvim_win_close(win, true)
    wipe(buf, decoy, opened)
  end)

  t('regression: the jump flash stays on the translation buffer', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'v' } })
    write(root .. '/tr/ko.json', '{\n  "a": "v"\n}\n')
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "v"])', '(tr [:a "v"])' }, 'clojure')
    preview.refresh(buf)
    api.nvim_win_set_cursor(win, { 1, 3 })
    jump.jump()
    local target = api.nvim_get_current_buf()
    local ns = api.nvim_get_namespaces()['i18n_inline_flash']
    local marks = api.nvim_buf_get_extmarks(target, ns, 0, -1, { details = true })
    eq(#marks, 1)
    eq({ marks[1][2], marks[1][3], marks[1][4].end_col }, { 1, 2, 5 }) -- `"a"`
    -- back to the code within the flash: nothing lingers in that window
    vim.cmd('buffer ' .. buf)
    eq(#vim.fn.getmatches(), 0)
    eq(#api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)
    api.nvim_win_close(win, true)
    wipe(buf, target)
  end)

  t('regression: a broken translation file reports the decoder error', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'v' }, de = { a = 'w' } })
    write(root .. '/tr/de.json', '{ broken')
    local project = resolve.project_from(root)
    local keys, err = resolve.ensure_lang(project.catalogs[1], 'de')
    eq(keys, nil)
    ok_(err:find('invalid JSON: ', 1, true), err) -- was "…: empty table"
    ok_(resolve.ensure_lang(project.catalogs[1], 'ko'), 'ko should still load')
  end)

  -- ===== audit =====

  t('regression: quickfix text stays single-line for multi-line fallbacks', function()
    reset_all()
    local root = make_project({
      dir = 'tr',
      patterns = CLJ,
      check = { extensions = { 'cljs' } },
    }, { ko = { a = 'file' } })
    write(root .. '/src/a.cljs', '(tr [:a "line1\\nline2"])\n')
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/probe.cljs')
    vim.fn.setqflist({}, ' ')
    check.check(buf)
    ok_(vim.wait(5000, function()
      return #vim.fn.getqflist() >= 1
    end, 20), 'quickfix never filled')
    local text = vim.fn.getqflist()[1].text
    ok_(not text:find('\n'), 'newline in quickfix text: ' .. text)
    ok_(text:find('line1 ⏎ line2', 1, true), text)
    vim.cmd('cclose')
    wipe(buf)
  end)

  t('regression: headless audits list every unused key in :messages', function()
    reset_all()
    local keys = {}
    for i = 1, 12 do
      keys[('k%02d'):format(i)] = 'v'
    end
    local root = make_project({
      dir = 'tr',
      patterns = CLJ,
      check = { extensions = { 'cljs' } },
    }, { ko = keys })
    write(root .. '/src/a.cljs', '(tr [:k01 "v"])\n')
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/probe.cljs')
    vim.cmd('messages clear')
    check.check(buf)
    local msgs
    ok_(vim.wait(5000, function()
      msgs = vim.fn.execute('messages')
      return msgs:find('not referenced', 1, true) ~= nil
    end, 20), 'no unused-key message')
    ok_(msgs:find('11 keys in "ko"', 1, true), msgs)
    ok_(msgs:find('k12', 1, true) and not msgs:find('…', 1, true), msgs) -- was cut at ten
    vim.cmd('cclose')
    wipe(buf)
  end)

  -- ===== autocmd wiring (setup + plugin file) =====

  t('regression: saving a translation file opened by a relative name refreshes other buffers', function()
    reset_all()
    require('i18n-inline').setup({ debounce_ms = 1 })
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'old' } })
    write(root .. '/tr/ko.json', '{\n  "a": "old"\n}\n')
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "old"])' }, 'clojure')
    local tbuf, ebuf
    local ok, err = pcall(in_dir, root, function()
      preview.refresh(buf)
      eq(preview.match_at(buf, 0).status, 'match')

      vim.cmd('split tr/ko.json') -- relative name: <afile> is relative too
      tbuf = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(tbuf, 1, 2, false, { '  "a": "new"' })
      vim.cmd('silent write')
      eq(preview.match_at(buf, 0).value, 'new')

      -- a language file added later is picked up when saved
      vim.cmd('silent split tr/en.json')
      ebuf = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(ebuf, 0, -1, false, { '{"a": "EN"}' })
      vim.cmd('silent write')
      eq(resolve.value(preview.state(buf).project.catalogs[1], 'en', 'a'), 'EN')
    end)
    pcall(api.nvim_del_augroup_by_name, 'i18n-inline')
    pcall(api.nvim_win_close, win, true)
    vim.cmd('silent! only')
    wipe(buf, tbuf or buf, ebuf or buf)
    if not ok then
      error(err, 0)
    end
  end)

  t('regression: commands work without setup(); :I18nJump completion filters', function()
    reset_all()
    vim.g.loaded_i18n_inline = nil
    vim.cmd.source(vim.fn.fnameescape(plugin_dir .. '/plugin/i18n-inline.lua'))
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'A' }, en = { a = 'A' }, ja = {} })
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "A"])' }, 'clojure')
    eq(vim.fn.getcompletion('I18nJump e', 'cmdline'), { 'en' })
    eq(vim.fn.getcompletion('I18nJump ', 'cmdline'), { 'ko', 'en', 'ja' })
    -- no setup(), no prior refresh: hover resolves on demand
    api.nvim_win_set_cursor(win, { 1, 3 })
    local base = floats()
    vim.cmd('I18nHover')
    eq(floats() - base, 1)
    hover.close()
    api.nvim_win_close(win, true)
    wipe(buf)
    ok_(vim.fn.hlexists('I18nInlineMismatch') == 1, 'highlight group not defined')
  end)

  -- ===== extmark bookkeeping =====

  local function marks(buf)
    return api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace('i18n_inline'), 0, -1, { details = true })
  end

  t('regression: :edit! re-reading a buffer keeps one set of marks', function()
    reset_all()
    require('i18n-inline').setup({ debounce_ms = 1 })
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'A', b = 'B' } })
    write(root .. '/x.cljs', '(tr [:a "A"])\n(tr [:b "other"])\n')
    local ok, err = pcall(function()
      vim.cmd('silent edit ' .. vim.fn.fnameescape(root .. '/x.cljs'))
      local buf = api.nvim_get_current_buf()
      preview.refresh(buf)
      local before = #marks(buf)
      eq(before, 3) -- two values + one mismatch underline
      for _ = 1, 2 do
        -- BufUnload fires and the state goes, but the buffer's marks stay
        vim.cmd('silent edit!')
        eq(#marks(buf), 0, 'marks left behind by the unloaded state')
        preview.refresh(buf)
        eq(#marks(buf), before)
      end
    end)
    pcall(api.nvim_del_augroup_by_name, 'i18n-inline')
    vim.cmd('silent! %bwipeout!')
    if not ok then
      error(err, 0)
    end
  end)

  t('regression: a fresh state clears marks it does not track', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'A' } })
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "A"])' }, 'clojure')
    preview.refresh(buf)
    preview._reset() -- state lost without its marks (a module reload, …)
    preview.refresh(buf)
    eq(#marks(buf), 1)
    api.nvim_win_close(win, true)
    wipe(buf)
  end)

  t('regression: a match ending on the newline renders at the line end', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = { '%(tr%s*%[%s*:([%w%-]+)%s' } }, { ko = { a = 'A' } })
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a', '])' }, 'clojure')
    preview.refresh(buf) -- raised "Invalid 'col': out of range"
    local ms = marks(buf)
    eq(#ms, 1)
    eq({ ms[1][2], ms[1][3] }, { 0, 7 })
    api.nvim_win_close(win, true)
    wipe(buf)
  end)

  t('regression: turning underline_mismatch off removes drawn underlines', function()
    reset_all()
    local root = make_project({ dir = 'tr', patterns = CLJ }, { ko = { a = 'A' } })
    local buf, win = open_buf(root .. '/x.cljs', { '(tr [:a "other"])' }, 'clojure')
    preview.refresh(buf)
    eq(#marks(buf), 2)
    preview.state(buf).project.cfg.underline_mismatch = false
    preview.refresh(buf)
    local ms = marks(buf)
    eq(#ms, 1)
    ok_(ms[1][4].virt_text ~= nil, 'the value mark should stay')
    api.nvim_win_close(win, true)
    wipe(buf)
  end)

  -- ===== po =====

  t('regression: po fuzzy flag survives #| lines; plural forms stay apart', function()
    local po = table.concat({
      '#: app.py:1',
      '#, fuzzy, python-format',
      '#| msgid "Old"',
      'msgid "New"',
      'msgstr "stale"',
      '',
      'msgid "one"',
      'msgid_plural "many"',
      'msgstr[0] "하나"',
      'msgstr[1] ""',
      '"여럿"',
      '',
      '# a translator note on fuzzy matching',
      'msgid "Logic"',
      'msgstr "로직"',
    }, '\n')
    local out = formats.registry.po.decode(po, {})
    eq(out['New'], nil)
    eq(out['one'], '하나')
    eq(out['Logic'], '로직')
  end)
  -- ===== scan robustness =====

  t('regression: a pattern matching the empty string terminates', function()
    local ms = scan.scan(' (tr [:a "x"])', { patterns = { ':?([%w-]*)' } })
    ok_(#ms > 0)
  end)

  t('regression: a malformed pattern is skipped, the others still match', function()
    local notified = {}
    local orig = vim.notify
    vim.notify = function(msg)
      notified[#notified + 1] = msg
    end
    local ok, ms = pcall(scan.scan, '(tr [:a "x"])', { patterns = { '%(tr %[:([%w-]+', CLJ[1] } })
    scan.scan('(tr [:a "x"])', { patterns = { '%(tr %[:([%w-]+' } })
    vim.notify = orig
    ok_(ok, tostring(ms))
    eq(#ms, 1)
    eq(ms[1].key, 'a')
    eq(#notified, 1) -- once per pattern, not once per scan
    ok_(notified[1]:find('unfinished capture', 1, true), notified[1])
  end)

  -- ===== json jump =====

  t('regression: json find_line follows the structure to the right key', function()
    local lines = {
      '{',
      '  "Home": {',
      '    "title": "홈",',
      '    "g": { "h": "x" },',
      '    "after": "y"',
      '  },',
      '  "Billing": {',
      '    "title": "결제"',
      '  }',
      '}',
    }
    local find = formats.registry.json.find_line
    eq({ find(lines, 'Billing.title', { separator = '.' }) }, { 8, 5, 7 })
    -- an inline object opens no level for the lines after it
    eq({ find(lines, 'Home.after', { separator = '.' }) }, { 5, 5, 7 })
  end)
end
