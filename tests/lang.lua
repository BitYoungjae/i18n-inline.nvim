-- Language switch tests (:I18nLang): what the inline text shows in another
-- language, the per-project session scope, the picker, what follows the
-- switch (popover order, jump target) and what doesn't (the audit).
--
-- Loaded by run.lua, which provides the framework (t/eq/ok_),
-- make_project, and the repository root (to source plugin/).

local api = vim.api

return function(t, eq, ok_, make_project, plugin_dir)
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  local preview = require('i18n-inline.preview')
  local hover = require('i18n-inline.hover')
  local jump = require('i18n-inline.jump')
  local check = require('i18n-inline.check')
  local lang = require('i18n-inline.lang')

  local CLJ = { '%(tr%s*%[%s*:([%w%.%-_/]+)' }

  local function reset_all()
    hover.close()
    config.reset()
    resolve.reset()
    preview._reset()
  end

  -- The code defaults are English: `drift` disagrees with en.json, `gap`
  -- has no Korean translation yet.
  local function project(extra)
    local cfg = { dir = 'tr', preview_lang = 'en', source_lang = 'en', patterns = CLJ }
    for k, v in pairs(extra or {}) do
      cfg[k] = v
    end
    return make_project(cfg, {
      en = { ok = 'Save', drift = 'Delete all', gap = 'Archive' },
      ko = { ok = '저장', drift = '모두 삭제' },
      ja = { ok = '保存', drift = 'すべて削除', gap = 'アーカイブ' },
    })
  end

  local LINES = { '(tr [:ok "Save"])', '(tr [:drift "Delete"])', '(tr [:gap "Archive"])' }

  -- A buffer for `path`, rendered and shown in a window (current).
  local function open(path, lines)
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, path)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines or LINES)
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 80, height = 5 })
    return buf, win
  end

  local function close(...)
    for _, id in ipairs({ ... }) do
      if api.nvim_win_is_valid(id) then
        api.nvim_win_close(id, true)
      end
    end
  end

  local function wipe(...)
    for _, b in ipairs({ ... }) do
      if api.nvim_buf_is_valid(b) then
        api.nvim_buf_delete(b, { force = true })
      end
    end
  end

  -- Inline texts in row order, and their highlight groups.
  local function inline(buf)
    local ns = api.nvim_get_namespaces()['i18n_inline']
    local texts, hls = {}, {}
    for _, mk in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if mk[4].virt_text then
        texts[#texts + 1] = mk[4].virt_text[1][1]
        hls[#hls + 1] = mk[4].virt_text[1][2]
      end
    end
    return texts, hls
  end

  -- Run fn with notifications captured; returns the messages.
  local function notes(fn)
    local msgs, orig = {}, vim.notify
    vim.notify = function(msg)
      msgs[#msgs + 1] = msg
    end
    local ok, err = pcall(fn)
    vim.notify = orig
    if not ok then
      error(err, 0)
    end
    return msgs
  end

  t('lang E2E: another language shows its values; ≠ only in preview_lang', function()
    reset_all()
    local root = project()
    local buf, win = open(root .. '/src/x.cljs')
    local texts, hls = inline(buf)
    eq(texts, { '  Save', '  ≠ Delete all', '  Archive' })
    eq(hls[2], 'I18nInlineMismatch')

    local msgs = notes(function()
      lang.lang('ko')
    end)
    eq(msgs, { '[i18n-inline] preview language: ko (≠ marks show in en only)' })
    texts, hls = inline(buf)
    -- Korean next to an English default is no drift; the gap is
    eq(texts, { '  저장', '  모두 삭제', '  ✗ missing in ko' })
    eq(hls, { 'I18nInlineValue', 'I18nInlineValue', 'I18nInlineMissing' })
    eq(preview.state(buf).lang, 'ko')

    msgs = notes(function()
      lang.lang('en')
    end)
    eq(msgs, { '[i18n-inline] preview language: en (configured)' })
    eq((inline(buf)), { '  Save', '  ≠ Delete all', '  Archive' })
    close(win)
    wipe(buf)
  end)

  t('lang: show=problems in another language shows only its gaps', function()
    reset_all()
    local root = project({ show = 'problems' })
    local buf, win = open(root .. '/src/x.cljs')
    eq((inline(buf)), { '  ≠ Delete all' })
    notes(function()
      lang.lang('ko')
    end)
    eq((inline(buf)), { '  ✗ missing in ko' })
    close(win)
    wipe(buf)
  end)

  t('lang: compare=none leaves the ≠ note out of the message', function()
    reset_all()
    local root = project({ compare = 'none' })
    local buf, win = open(root .. '/src/x.cljs')
    eq(
      notes(function()
        lang.lang('ja')
      end),
      { '[i18n-inline] preview language: ja' }
    )
    close(win)
    wipe(buf)
  end)

  t("lang: the switch covers the project's buffers, not another project's", function()
    reset_all()
    local root, other = project(), project()
    local a, wa = open(root .. '/src/a.cljs')
    local b, wb = open(root .. '/src/b.cljs')
    local c, wc = open(other .. '/src/c.cljs')
    api.nvim_set_current_win(wa)
    notes(function()
      lang.lang('ja')
    end)
    eq((inline(a))[1], '  保存')
    eq((inline(b))[1], '  保存')
    eq((inline(c))[1], '  Save')

    -- a buffer opened later, and the project rebuilt (its file saved)
    local d, wd = open(root .. '/src/d.cljs')
    eq((inline(d))[1], '  保存')
    resolve.reset()
    preview.refresh(a)
    eq((inline(a))[1], '  保存')
    close(wa, wb, wc, wd)
    wipe(a, b, c, d)
  end)

  t('lang: the picker keeps a stable order and marks current and configured', function()
    reset_all()
    local root = project()
    local buf, win = open(root .. '/src/x.cljs')

    local orig = vim.ui.select
    local items, labels, prompt
    local function pick(choice)
      vim.ui.select = function(list, opts, on_choice)
        items, prompt, labels = list, opts.prompt, {}
        for i, item in ipairs(list) do
          labels[i] = opts.format_item(item)
        end
        on_choice(choice)
      end
      local ok, err = pcall(notes, lang.lang)
      vim.ui.select = orig
      if not ok then
        error(err, 0)
      end
    end

    pick('ja')
    eq(prompt, 'i18n preview language:')
    eq(items, { 'en', 'ja', 'ko' })
    eq(labels, { 'en (current, configured)', 'ja', 'ko' })
    eq((inline(buf))[1], '  保存')

    pick(nil) -- cancelled: nothing changes
    eq(items, { 'en', 'ja', 'ko' })
    eq(labels, { 'en (configured)', 'ja (current)', 'ko' })
    eq((inline(buf))[1], '  保存')

    -- an unknown language is refused with the ones there are
    local msgs = notes(function()
      lang.lang('xx')
    end)
    eq(msgs, { '[i18n-inline] no translation file for "xx" (available: en, ja, ko)' })
    eq((inline(buf))[1], '  保存')
    close(win)
    wipe(buf)
  end)

  t('lang: one language means nothing to pick', function()
    reset_all()
    local root = make_project({ dir = 'tr', preview_lang = 'en', patterns = CLJ }, { en = { ok = 'Save' } })
    local buf, win = open(root .. '/src/x.cljs')
    local orig, asked = vim.ui.select, false
    vim.ui.select = function()
      asked = true
    end
    local ok, msgs = pcall(notes, lang.lang)
    vim.ui.select = orig
    ok_(ok, tostring(msgs))
    ok_(not asked, 'picker opened for a single language')
    eq(msgs, { '[i18n-inline] no other language to preview (only "en")' })
    close(win)
    wipe(buf)
  end)

  t('lang: the popover lists the shown language first, ≠ stays on preview_lang; jump opens the shown one', function()
    reset_all()
    local root = project()
    local buf, win = open(root .. '/src/x.cljs')
    notes(function()
      lang.lang('ko')
    end)
    api.nvim_win_set_cursor(win, { 2, 3 }) -- the drift call
    hover.hover()

    local float
    for _, w in ipairs(api.nvim_list_wins()) do
      local relative = api.nvim_win_get_config(w).relative
      if relative ~= '' and relative ~= 'editor' then
        float = w
      end
    end
    ok_(float, 'no popover')
    local fbuf = api.nvim_win_get_buf(float)
    local rows = api.nvim_buf_get_lines(fbuf, 0, -1, false)
    eq({ rows[3], rows[4], rows[5] }, { 'ko  모두 삭제', 'en  Delete all', 'ja  すべて削除' })
    local marked = {}
    local hns = api.nvim_get_namespaces()['i18n_inline_hover']
    for _, mk in ipairs(api.nvim_buf_get_extmarks(fbuf, hns, 0, -1, { details = true })) do
      if mk[4].hl_group == 'I18nInlineMismatch' then
        marked[#marked + 1] = rows[mk[2] + 1]:match('^%S+')
      end
    end
    eq(marked, { 'en' })
    hover.close()

    jump.jump()
    ok_(api.nvim_buf_get_name(0):match('tr/ko%.json$') ~= nil, api.nvim_buf_get_name(0))
    local jbuf = api.nvim_get_current_buf()
    close(win)
    wipe(buf, jbuf)
  end)

  t('lang: a buffer whose catalogs lack the language keeps preview_lang', function()
    reset_all()
    local root = make_project({
      preview_lang = 'en',
      patterns = CLJ,
      catalogs = { 'a/messages', 'b/messages' },
    }, {}, '.')
    for path, keys in pairs({
      ['a/messages/en.json'] = { k = 'A' },
      ['a/messages/ja.json'] = { k = 'エー' },
      ['b/messages/en.json'] = { k = 'B' },
    }) do
      vim.fn.mkdir(vim.fs.dirname(root .. '/' .. path), 'p')
      local fh = assert(io.open(root .. '/' .. path, 'w'))
      fh:write(vim.json.encode(keys))
      fh:close()
    end
    local a, wa = open(root .. '/a/x.cljs', { '(tr [:k "A"])' })
    notes(function()
      lang.lang('ja')
    end)
    eq((inline(a)), { '  エー' })

    local b, wb
    local msgs = notes(function()
      b, wb = open(root .. '/b/y.cljs', { '(tr [:k "B"])' })
    end)
    eq(msgs, {})
    eq((inline(b)), { '  B' })
    eq(preview.state(b).lang, 'en')
    msgs = notes(function()
      lang.lang('ja')
    end)
    eq(msgs, { '[i18n-inline] no translation file for "ja" (available: en)' })
    close(wa, wb)
    wipe(a, b)
  end)

  t('lang: the audit keeps comparing in preview_lang', function()
    reset_all()
    local root = project({ check = { extensions = { 'cljs' } } })
    vim.fn.mkdir(root .. '/src', 'p')
    local fh = assert(io.open(root .. '/src/x.cljs', 'w'))
    fh:write(table.concat(LINES, '\n') .. '\n')
    fh:close()
    local buf, win = open(root .. '/src/x.cljs')
    notes(function()
      lang.lang('ko')
    end)

    vim.fn.setqflist({}, ' ')
    notes(function()
      check.check(buf)
      ok_(
        vim.wait(5000, function()
          return #vim.fn.getqflist() > 0
        end, 20),
        'quickfix never filled'
      )
    end)
    local texts = {}
    for _, item in ipairs(vim.fn.getqflist()) do
      texts[#texts + 1] = item.text
    end
    ok_(vim.tbl_contains(texts, 'mismatch :drift — code "Delete" vs en "Delete all"'), vim.inspect(texts))
    close(win)
    wipe(buf)
  end)

  t('lang: :I18nLang completes and switches; keymaps.lang maps buffer-locally', function()
    reset_all()
    vim.g.loaded_i18n_inline = nil
    vim.cmd.source(vim.fn.fnameescape(plugin_dir .. '/plugin/i18n-inline.lua'))
    local root = project({ keymaps = { lang = '<leader>il' } })
    local buf, win = open(root .. '/src/x.cljs')
    eq(vim.fn.getcompletion('I18nLang ', 'cmdline'), { 'en', 'ja', 'ko' })
    eq(vim.fn.getcompletion('I18nLang k', 'cmdline'), { 'ko' })
    notes(function()
      vim.cmd('I18nLang ja')
    end)
    eq((inline(buf))[1], '  保存')

    local map = vim.fn.maparg('<leader>il', 'n', false, true)
    eq(map.buffer, 1)
    eq(map.rhs, '<Plug>(i18n-inline-lang)')
    close(win)
    wipe(buf)
  end)
end
