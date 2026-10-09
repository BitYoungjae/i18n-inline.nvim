-- Catalog tests: several translation directories in one project (catalogs,
-- wildcards, file_template discovery), which catalogs a file reads (homes,
-- `uses`, the all-catalogs fallback), the "only in <catalog>" status, the
-- audit's scope (nested projects, path excludes) and ignore semantics, and
-- the full-tree health scan. The fixture mirrors the repository that
-- motivated them: per-template catalogs plus a shared component fed by two
-- of them at runtime.
--
-- Loaded by run.lua, which provides the framework (t/eq/ok_) and
-- make_project.

local uv = vim.uv
local api = vim.api

return function(t, eq, ok_, make_project)
  local util = require('i18n-inline.util')
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  local preview = require('i18n-inline.preview')
  local hover = require('i18n-inline.hover')
  local jump = require('i18n-inline.jump')
  local check = require('i18n-inline.check')

  local FM = "formatMessage%s*%(%s*{%s*id%s*:%s*['\"]([^'\"\n]+)['\"]"
  local LANGS = { 'en', 'ko' }

  local function reset_all()
    hover.close()
    config.reset()
    resolve.reset()
    preview._reset()
  end

  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local fh = assert(io.open(path, 'w'))
    fh:write(type(content) == 'table' and vim.json.encode(content) or content)
    fh:close()
  end

  -- A temp project: `cfg` as the project file plus `files` (path -> string
  -- or table, written as JSON).
  local function tree(cfg, files)
    local root = make_project(cfg, {}, '.')
    for path, content in pairs(files) do
      write(root .. '/' .. path, content)
    end
    return vim.fs.normalize(root)
  end

  local function call(id)
    return ("intl.formatMessage({ id: '%s' })\n"):format(id)
  end

  -- The bgpworks-email shape: per-template catalogs, a shared footer
  -- catalog named footer-<lang>.json, and a shared component that gets the
  -- low_stock_* catalogs as props.
  local function email_repo(extra)
    local files = {
      ['src/emails/order/messages/en.json'] = { heading = 'Order', cta = 'Open' },
      ['src/emails/order/messages/ko.json'] = { heading = '주문', cta = '열기' },
      ['src/emails/order/index.tsx'] = call('heading') .. call('cta'),
      ['src/emails/stock_all/messages/en.json'] = { heading = 'All', shortage = 'Short' },
      ['src/emails/stock_all/messages/ko.json'] = { heading = '전체', shortage = '부족' },
      ['src/emails/stock_location/messages/en.json'] = { heading = 'Here', shortage = 'Short' },
      ['src/emails/stock_location/messages/ko.json'] = { heading = '여기', shortage = '부족' },
      ['src/emails/shared/messages/footer-en.json'] = { legal = '(c)' },
      ['src/emails/shared/messages/footer-ko.json'] = { legal = '(c) 한' },
      ['src/emails/shared/components/footer.tsx'] = call('legal'),
      ['src/emails/shared/components/stock.tsx'] = call('heading') .. call('shortage') .. call('nowhere'),
    }
    local cfg = {
      preview_lang = 'ko',
      source_lang = 'en',
      filetypes = { 'typescriptreact' },
      patterns = { FM },
      fallback_style = 'none',
      catalogs = {
        'src/emails/*/messages',
        { dir = 'src/emails/shared/messages', file_template = 'footer-%s.json' },
      },
      check = { extensions = { 'tsx' } },
    }
    for k, v in pairs(extra or {}) do
      cfg[k] = v
    end
    return tree(cfg, files)
  end

  local function labels(catalogs)
    local out = {}
    for i, c in ipairs(catalogs) do
      out[i] = c.label
    end
    return out
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

  -- Audit `buf`'s project; returns the quickfix items and the report lines.
  local function audit(buf)
    vim.fn.setqflist({}, ' ', { title = '' })
    local before = #vim.split(vim.fn.execute('messages'), '\n')
    check.check(buf)
    ok_(vim.wait(5000, function()
      return vim.fn.getqflist({ title = 1 }).title == 'i18n audit'
    end, 20), 'audit never finished')
    local msgs = vim.split(vim.fn.execute('messages'), '\n')
    return vim.fn.getqflist(), vim.list_slice(msgs, before + 1)
  end

  -- :checkhealth output for the cwd's project, as "kind: message" lines.
  local function health(root)
    local out = {}
    local saved = vim.health
    local function rec(kind)
      return function(msg)
        out[#out + 1] = kind .. ': ' .. msg
      end
    end
    vim.health = { start = function() end, ok = rec('ok'), warn = rec('warn'), error = rec('error'), info = rec('info') }
    local buf = api.nvim_create_buf(true, false)
    local prev = api.nvim_get_current_buf()
    api.nvim_set_current_buf(buf)
    local ok, err = pcall(in_dir, root, require('i18n-inline.health').check)
    api.nvim_set_current_buf(prev)
    api.nvim_buf_delete(buf, { force = true })
    vim.health = saved
    ok_(ok, tostring(err))
    return out
  end

  local function find_line(lines, pat)
    for _, l in ipairs(lines) do
      if l:find(pat) then
        return l
      end
    end
    return nil
  end

  -- ===== globs and the tree walk =====

  t('util.path_glob: * and ? stay in a segment, ** spans any number', function()
    local g = util.path_glob('src/*/messages')
    ok_(g('src/order/messages'))
    ok_(not g('src/a/b/messages'))
    ok_(not g('src/order/messages/x'))
    local gg = util.path_glob('src/**/x.tsx')
    ok_(gg('src/x.tsx'))
    ok_(gg('src/a/b/x.tsx'))
    ok_(not gg('lib/x.tsx'))
    ok_(util.path_glob('a?c')('abc'))
    ok_(not util.path_glob('a?c')('a/c'))
    ok_(util.path_glob('a.b-c')('a.b-c')) -- magic characters are literal
    ok_(not util.path_glob('a.b')('axb'))
  end)

  t('util.walk_files: path excludes and nested projects are skipped', function()
    local root = tree({ dir = 'tr' }, {
      ['tr/ko.json'] = {},
      ['src/components/a.tsx'] = '',
      ['src/emails/shared/components/b.tsx'] = '',
      ['src/emails/order/.i18n-inline.json'] = { dir = 'messages' },
      ['src/emails/order/index.tsx'] = '',
      ['lib/components/c.tsx'] = '',
    })
    local files, nested = util.walk_files(root, {
      extensions = { 'tsx' },
      exclude_dirs = { 'src/components' }, -- a path, not every "components"
      project_file = '.i18n-inline.json',
    })
    for i, f in ipairs(files) do
      files[i] = util.relpath(root, f)
    end
    eq(files, { 'lib/components/c.tsx', 'src/emails/shared/components/b.tsx' })
    eq(nested, { root .. '/src/emails/order' })
  end)

  -- ===== config =====

  t('config: catalogs and uses are validated, entry typos reported', function()
    reset_all()
    local ok_cfg = config.merge_project({
      catalogs = { 'a/*/messages', { dir = 'b', file_template = '%s.json', key_style = 'nested', ['//'] = 'note' } },
      uses = { ['src/x.tsx'] = { 'a/*/messages' } },
    })
    ok_(ok_cfg ~= nil, 'valid catalogs rejected')
    local _, e1 = config.merge_project({ catalogs = {} })
    ok_(e1 and e1:match('catalogs'), tostring(e1))
    local _, e2 = config.merge_project({ catalogs = { { file_template = '%s.json' } } })
    ok_(e2 and e2:match('catalogs%[1%]%.dir'), tostring(e2))
    local _, e3 = config.merge_project({ catalogs = { { dir = 'x', key_style = 'deep' } } })
    ok_(e3 and e3:match('key_style'), tostring(e3))
    local _, e4 = config.merge_project({ uses = { ['src/x.tsx'] = 'a' } })
    ok_(e4 and e4:match('uses'), tostring(e4))
    local _, e5 = config.merge_project({ uses = { 'a' } })
    ok_(e5 and e5:match('uses'), tostring(e5))
    eq(config.unknown_keys({ catalogs = { 'a', { dir = 'b', langs = {}, ['//'] = 'x' } } }), { 'catalogs[2].langs' })
  end)

  t('config: the layer that sets dir or catalogs decides', function()
    reset_all()
    config.setup({ catalogs = { 'from-setup' } })
    local m1 = config.merge_project({ dir = 'from-file' })
    eq({ m1.dir, m1.catalogs }, { 'from-file', nil })
    config.setup({ dir = 'from-setup' })
    local m2 = config.merge_project({ catalogs = { 'from-file' } })
    eq({ m2.dir, m2.catalogs }, { nil, { 'from-file' } })
    local m3 = config.merge_project({ preview_lang = 'en' })
    eq(m3.dir, 'from-setup')
    config.reset()
  end)

  -- ===== catalogs =====

  t('catalogs: wildcards expand, a named dir beats a wildcard, templates discover languages', function()
    reset_all()
    local root = email_repo()
    write(root .. '/src/emails/empty/messages/README.md', 'no translations')
    local p = resolve.project_from(root)
    ok_(p ~= nil, 'project not found')
    eq(labels(p.catalogs), { 'order/messages', 'stock_all/messages', 'stock_location/messages', 'shared/messages' })
    local shared = p.catalogs[4]
    eq(shared.cfg.file_template, 'footer-%s.json')
    eq(resolve.sorted_langs(shared), { 'ko', 'en' })
    eq(resolve.ensure_lang(shared, 'ko').legal, '(c) 한')
    eq(p.empty, { 'src/emails/empty/messages' }) -- matched, but no translation files
    eq(p.unmatched, {})
  end)

  t('catalogs: file_template discovery through a language directory', function()
    reset_all()
    local root = tree({ dir = 'translations', file_template = '%s/LC_MESSAGES/messages.po' }, {
      ['translations/ko/LC_MESSAGES/messages.po'] = 'msgid "a"\nmsgstr "가"\n',
      ['translations/ja/LC_MESSAGES/messages.po'] = 'msgid "a"\nmsgstr "あ"\n',
      ['translations/README/notes.txt'] = '',
    })
    local p = resolve.project_from(root)
    eq(resolve.sorted_langs(p.catalogs[1]), { 'ko', 'ja' })
    eq(resolve.value(p.catalogs[1], 'ja', 'a'), 'あ')
  end)

  t('catalogs: an entry that matches nothing is reported, the rest still load', function()
    reset_all()
    local root = tree({ catalogs = { 'missing/dir', 'tr' } }, { ['tr/ko.json'] = { a = 'x' } })
    local p = resolve.project_from(root)
    ok_(p ~= nil, 'project lost to one bad entry')
    eq(p.unmatched, { 'missing/dir' })
    eq(#p.catalogs, 1)
  end)

  t('catalogs_for: home, uses, and the all-catalogs fallback', function()
    reset_all()
    local root = email_repo({
      uses = { ['src/emails/shared/components/stock.tsx'] = { 'src/emails/stock_*/messages' } },
    })
    local p = resolve.project_from(root)
    local function reads(rel)
      return labels(resolve.catalogs_for(p, root .. '/' .. rel))
    end
    eq(reads('src/emails/order/index.tsx'), { 'order/messages' })
    eq(reads('src/emails/order/deep/x.tsx'), { 'order/messages' })
    eq(reads('src/emails/shared/components/footer.tsx'), { 'shared/messages' })
    eq(reads('src/emails/shared/components/stock.tsx'), { 'stock_all/messages', 'stock_location/messages' })
    -- outside every home: all of them, in declaration order
    eq(reads('src/lib/format.ts'), { 'order/messages', 'stock_all/messages', 'stock_location/messages', 'shared/messages' })
  end)

  t('catalogs_for: a home climbs past folders with no other catalog; a uses directory covers its files', function()
    reset_all()
    local root = tree({
      catalogs = { 'apps/web/messages', 'apps/admin/public/locales' },
      uses = { ['packages/ui'] = { 'apps/web/messages' } },
    }, {
      ['apps/web/messages/ko.json'] = {},
      ['apps/admin/public/locales/ko.json'] = {},
    })
    local p = resolve.project_from(root)
    eq(labels(resolve.catalogs_for(p, root .. '/apps/admin/src/page.tsx')), { 'locales' })
    eq(labels(resolve.catalogs_for(p, root .. '/apps/web/src/page.tsx')), { 'messages' })
    eq(labels(resolve.catalogs_for(p, root .. '/packages/ui/button.tsx')), { 'messages' })
  end)

  t('catalogs_for: nested catalogs — the deeper home wins, a root-level catalog serves the rest', function()
    reset_all()
    local root = tree({ catalogs = { 'messages', 'x/messages', 'x/sub/messages' } }, {
      ['messages/ko.json'] = {},
      ['x/messages/ko.json'] = {},
      ['x/sub/messages/ko.json'] = {},
    })
    local p = resolve.project_from(root)
    local function reads(rel)
      return labels(resolve.catalogs_for(p, root .. '/' .. rel))
    end
    eq(reads('src/page.tsx'), { 'messages' })
    eq(reads('x/index.ts'), { 'x/messages' })
    eq(reads('x/sub/a.ts'), { 'sub/messages' })
  end)

  t('catalogs_for: a lone catalog serves the whole project', function()
    reset_all()
    local root = tree({ dir = 'public/locales' }, { ['public/locales/ko.json'] = {} })
    local p = resolve.project_from(root)
    eq(#resolve.catalogs_for(p, root .. '/src/app/page.tsx'), 1)
  end)

  -- ===== lookup =====

  t('find: first catalog with the key wins; a key only another catalog has is "elsewhere"', function()
    reset_all()
    local root = email_repo()
    local p = resolve.project_from(root)
    local view = resolve.view(p, root .. '/src/emails/shared/components/stock.tsx')
    local m = { key = 'shortage' }
    resolve.classify(view, m)
    eq(m.status, 'missing')
    eq(labels(m.elsewhere), { 'stock_all/messages', 'stock_location/messages' })
    local none = { key = 'nowhere' }
    resolve.classify(view, none)
    eq({ none.status, none.elsewhere }, { 'missing', nil })

    local mapped = resolve.view(p, root .. '/src/emails/order/index.tsx')
    local h = { key = 'heading' }
    resolve.classify(mapped, h)
    eq({ h.status, h.value, h.catalog.label }, { 'novalue', '주문', 'order/messages' })
  end)

  t('find: a key only in a catalog\'s source language is a translation gap there', function()
    reset_all()
    local root = email_repo()
    write(root .. '/src/emails/order/messages/en.json', vim.json.encode({ heading = 'Order', cta = 'Open', extra = 'E' }))
    local p = resolve.project_from(root)
    local m = { key = 'extra' }
    resolve.classify(resolve.view(p, root .. '/src/emails/order/index.tsx'), m)
    eq({ m.status, m.in_source, m.catalog.label }, { 'missing', true, 'order/messages' })
  end)

  -- ===== inline, popover, jump =====

  t('preview E2E: "only in <catalog>" inline, values once uses maps the file', function()
    reset_all()
    local root = email_repo()
    local path = root .. '/src/emails/shared/components/stock.tsx'
    local function inline()
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      vim.bo[buf].filetype = 'typescriptreact'
      preview.refresh(buf)
      local out = {}
      for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace('i18n_inline'), 0, -1, { details = true })) do
        out[#out + 1] = vim.trim(mark[4].virt_text[1][1])
      end
      api.nvim_buf_delete(buf, { force = true })
      return out
    end
    -- heading: order/ has it too (declared first); shortage: the stock_* pair
    eq(inline(), { '✗ only in order/messages +2', '✗ only in stock_all/messages +1', '✗ key not found' })

    reset_all()
    write(root .. '/.i18n-inline.json', vim.json.encode({
      preview_lang = 'ko',
      source_lang = 'en',
      filetypes = { 'typescriptreact' },
      patterns = { FM },
      fallback_style = 'none',
      catalogs = { 'src/emails/*/messages', { dir = 'src/emails/shared/messages', file_template = 'footer-%s.json' } },
      uses = { ['src/emails/shared/components/stock.tsx'] = { 'src/emails/stock_*/messages' } },
    }))
    eq(inline(), { '전체', '부족', '✗ key not found' })
  end)

  t('hover/jump E2E: one section per catalog that has the key; jump! lists both', function()
    reset_all()
    local root = email_repo({
      uses = { ['src/emails/shared/components/stock.tsx'] = { 'src/emails/stock_*/messages' } },
    })
    local buf = vim.fn.bufadd(root .. '/src/emails/shared/components/stock.tsx')
    vim.fn.bufload(buf)
    vim.bo[buf].filetype = 'typescriptreact'
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 80, height = 5 })
    api.nvim_win_set_cursor(win, { 1, 6 })
    hover.hover()
    local lines
    for _, w in ipairs(api.nvim_list_wins()) do
      local c = api.nvim_win_get_config(w)
      if c.relative ~= '' and not c.focusable then
        lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(w), 0, -1, false)
      end
    end
    hover.close()
    ok_(lines, 'no popover')
    ok_(vim.tbl_contains(lines, 'stock_all/messages'), vim.inspect(lines))
    ok_(vim.tbl_contains(lines, 'stock_location/messages'), vim.inspect(lines))
    ok_(find_line(lines, '^ko%s+여기$'), vim.inspect(lines))

    jump.jump({ bang = true })
    local files = {}
    for _, it in ipairs(vim.fn.getqflist()) do
      files[#files + 1] = util.relpath(root, api.nvim_buf_get_name(it.bufnr))
    end
    eq(files, {
      'src/emails/stock_all/messages/ko.json',
      'src/emails/stock_all/messages/en.json',
      'src/emails/stock_location/messages/ko.json',
      'src/emails/stock_location/messages/en.json',
    })
    vim.cmd('cclose')
    api.nvim_win_close(win, true)
    api.nvim_buf_delete(buf, { force = true })
  end)

  t('jump E2E: a key only another catalog has opens that catalog, with a warning', function()
    reset_all()
    local root = email_repo()
    local buf = vim.fn.bufadd(root .. '/src/emails/shared/components/stock.tsx')
    vim.fn.bufload(buf)
    vim.bo[buf].filetype = 'typescriptreact'
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 80, height = 5 })
    api.nvim_win_set_cursor(win, { 2, 6 })
    local notes = {}
    local notify = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local ok, err = pcall(jump.jump)
    vim.notify = notify
    ok_(ok, tostring(err))
    eq(util.relpath(root, api.nvim_buf_get_name(0)), 'src/emails/stock_all/messages/ko.json')
    ok_(find_line(notes, 'not in the catalogs this file reads'), vim.inspect(notes))
    api.nvim_win_close(0, true)
    api.nvim_buf_delete(buf, { force = true })
  end)

  -- ===== audit =====

  t('check E2E: one project file audits every catalog; "only in" counted apart', function()
    reset_all()
    local root = email_repo()
    write(root .. '/src/emails/order/messages/en.json', vim.json.encode({ heading = 'Order', cta = 'Open', unusedKey = 'U' }))
    local items, msgs = audit(vim.fn.bufadd(root .. '/src/emails/order/index.tsx'))
    local texts = {}
    for i, it in ipairs(items) do
      texts[i] = it.text
    end
    table.sort(texts)
    eq(texts, {
      'missing key :heading — only in order/messages, stock_all/messages, stock_location/messages; this file reads shared/messages',
      'missing key :nowhere',
      'missing key :shortage — only in stock_all/messages, stock_location/messages; this file reads shared/messages',
      'missing key :unusedKey — present in en',
    })
    ok_(find_line(msgs, '3 missing keys %(2 only in another catalog%), 1 missing translation'), vim.inspect(msgs))
    -- unused per catalog; keys a call reaches only "elsewhere" count as used
    ok_(find_line(msgs, '1 key in "en" of order/messages not referenced by any scan: unusedKey'), vim.inspect(msgs))
    ok_(not find_line(msgs, 'stock_'), vim.inspect(msgs))
  end)

  t('check E2E: check.ignore silences missing keys and gaps, not mismatches', function()
    reset_all()
    local root = tree({
      dir = 'tr',
      preview_lang = 'ko',
      source_lang = 'en',
      patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
      check = { extensions = { 'cljs' }, ignore = { 'runtime.*', 'gap' } },
    }, {
      ['tr/en.json'] = { same = 'A', gap = 'G' },
      ['tr/ko.json'] = { same = 'A' },
      ['src/a.cljs'] = '(tr [:runtime.injected])\n(tr [:runtime.other "x"])\n(tr [:same "B"])\n(tr [:typo])\n',
    })
    local items = audit(vim.fn.bufadd(root .. '/src/a.cljs'))
    local texts = {}
    for i, it in ipairs(items) do
      texts[i] = it.text
    end
    table.sort(texts)
    eq(texts, { 'mismatch :same — code "B" vs ko "A"', 'missing key :typo' })
  end)

  t('check E2E: a root project skips nested projects without exclude_dirs', function()
    reset_all()
    local root = tree({ dir = 'shared', patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' }, check = { extensions = { 'cljs' } } }, {
      ['shared/ko.json'] = { a = 'v' },
      ['src/a.cljs'] = '(tr [:a])\n',
      ['sub/.i18n-inline.json'] = { dir = 'tr' },
      ['sub/tr/ko.json'] = { b = 'w' },
      ['sub/b.cljs'] = '(tr [:b])\n',
    })
    local items, msgs = audit(vim.fn.bufadd(root .. '/src/a.cljs'))
    eq(#items, 0)
    ok_(find_line(msgs, 'skipped 1 nested project'), vim.inspect(msgs))
  end)

  -- ===== health =====

  t('health: scans every file, so a few calls among many files still count', function()
    reset_all()
    local files = {
      ['tr/ko.json'] = { a = 'v' },
      ['src/zz/calls.cljs'] = '(tr [:a])\n',
    }
    for i = 1, 60 do
      files[('src/noise/f%02d.cljs'):format(i)] = '(println "no calls")\n'
    end
    local root = tree({ dir = 'tr', patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' }, check = { extensions = { 'cljs' } } }, files)
    local out = health(root)
    ok_(find_line(out, '^ok: scanned 61 files: 1 calls in 1 files, 1/1 resolve'), table.concat(out, '\n'))
    ok_(not find_line(out, '^warn'), table.concat(out, '\n'))
  end)

  t('health: catalogs listed; keys only another catalog has point at uses', function()
    reset_all()
    local root = email_repo({ uses = { ['src/nothing.tsx'] = { 'no/such/messages' } } })
    local out = health(root)
    ok_(find_line(out, '^ok: 4 catalogs'), table.concat(out, '\n'))
    ok_(find_line(out, '^ok: shared/messages: 2 languages, "ko" 1 key$'), table.concat(out, '\n'))
    ok_(find_line(out, '^warn: 2 calls use keys found only in catalogs their file doesn\'t read: src/emails/shared/components/stock%.tsx %(2%).*`uses`'), table.concat(out, '\n'))
    ok_(find_line(out, '^info: 1 call uses keys no catalog has, e%.g%. nowhere %(src/emails/shared/components/stock%.tsx:3%)'), table.concat(out, '\n'))
    ok_(find_line(out, '^warn: uses%["src/nothing%.tsx"%]: "no/such/messages" matches no catalog'), table.concat(out, '\n'))
    ok_(not find_line(out, 'none resolve'), table.concat(out, '\n'))
  end)

  -- ===== saving =====

  t('saving a translation file in a new wildcard directory adds the catalog', function()
    reset_all()
    local root = email_repo()
    local p = resolve.project_from(root)
    eq(#p.catalogs, 4)
    local new = root .. '/src/emails/invite/messages/ko.json'
    write(new, vim.json.encode({ hi = '안녕' }))
    eq(resolve.project_having_file(new), p)
    eq(labels(p.catalogs)[1], 'invite/messages') -- wildcard matches are sorted
    eq(resolve.value(p.catalogs[1], 'ko', 'hi'), '안녕')
  end)

  t('init: is_setup reports whether setup() ran', function()
    ok_(type(require('i18n-inline').is_setup()) == 'boolean')
  end)
end
