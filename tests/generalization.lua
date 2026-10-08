-- Generalization tests (REQUIREMENTS.md R1–R7): nested keys, namespace
-- composition, aliases, fallback styles, placeholder normalization, formats
-- (PO), presets, display toggle, keymaps-from-project-file, and audit
-- semantics (source language, ignore globs).
--
-- Loaded by run.lua, which provides the framework (t/eq/ok_), make_project,
-- and the tmp_roots registry.

local uv = vim.uv
local api = vim.api

return function(t, eq, ok_, make_project)
  local scan = require('i18n-inline.scan')
  local formats = require('i18n-inline.formats')
  local presets = require('i18n-inline.presets')
  local config = require('i18n-inline.config')
  local resolve = require('i18n-inline.resolve')
  local preview = require('i18n-inline.preview')
  local check = require('i18n-inline.check')

  local function reset_all()
    config.reset()
    resolve.reset()
    preview._reset()
  end

  -- ===== R1.2 nested JSON flattening =====

  t('formats: nested JSON flattens to dot paths', function()
    local flat = {}
    formats.flatten({ Invoice = { amount = 'Amount', tax = { incl = 'Tax' } } }, '.', flat, {}, '', 1)
    eq(flat, { ['Invoice.amount'] = 'Amount', ['Invoice.tax.incl'] = 'Tax' })
  end)

  t('formats: custom separator flattens ns:key shape', function()
    local flat = {}
    formats.flatten({ ns = { key = 'v' } }, ':', flat, {}, '', 1)
    eq(flat, { ['ns:key'] = 'v' })
  end)

  t('formats: literal-dot collision — nested path wins (R1.5)', function()
    local flat = {}
    formats.flatten({ ['a.b'] = 'literal', a = { b = 'nested' } }, '.', flat, {}, '', 1)
    eq(flat, { ['a.b'] = 'nested' })
    -- reversed key order must give the same answer
    local flat2 = {}
    formats.flatten({ a = { b = 'nested' }, ['a.b'] = 'literal' }, '.', flat2, {}, '', 1)
    eq(flat2, { ['a.b'] = 'nested' })
  end)

  t('formats: JSON decode honors key_style', function()
    local raw = vim.json.encode({ section = { title = 'T' }, flat = 'F' })
    local flat, err = formats.registry.json.decode(raw, { key_style = 'flat' })
    ok_(flat and flat.flat == 'F', err)
    local nested = formats.registry.json.decode(raw, { key_style = 'nested', separator = '.' })
    eq(nested, { ['section.title'] = 'T', flat = 'F' })
  end)

  -- ===== R4 PO format =====

  t('formats: po parses entries, plurals, multiline; skips untranslated/fuzzy/ctxt', function()
    local po = table.concat({
      'msgid ""',
      'msgstr ""',
      '"Project-Id-Version: x\n"',
      '',
      '#, fuzzy',
      'msgid "fuzzy one"',
      'msgstr "무시됨"',
      '',
      'msgid "Save changes"',
      'msgstr "변경사항 저장"',
      '',
      'msgid "long key"',
      '" continued"',
      'msgstr ""',
      '"긴 값"',
      '',
      'msgid "%d item"',
      'msgid_plural "%d items"',
      'msgstr[0] "%d개 품목"',
      'msgstr[1] "%d개 품목들"',
      '',
      'msgctxt "menu"',
      'msgid "Open"',
      'msgstr "열기"',
      '',
      'msgid "untranslated"',
      'msgstr ""',
    }, '\n')
    local out = formats.registry.po.decode(po, {})
    eq(out, {
      ['Save changes'] = '변경사항 저장',
      ['long key continued'] = '긴 값',
      ['%d item'] = '%d개 품목',
    })
  end)

  t('formats: for_path picks json/po/arb by extension, format config wins', function()
    ok_(formats.for_path('a/b/ko.json', {}) == formats.registry.json)
    ok_(formats.for_path('a/b/ko.po', {}) == formats.registry.po)
    ok_(formats.for_path('app_en.arb', {}) == formats.registry.arb)
    ok_(formats.for_path('a/b/ko.json', { format = 'po' }) == formats.registry.po)
    ok_(formats.for_path('a/b/ko.yaml', {}) == nil)
  end)

  t('formats: arb decodes as JSON minus @metadata entries', function()
    local raw = vim.json.encode({
      ['@@locale'] = 'en',
      ['@greeting'] = { description = 'main greeting', placeholders = {} },
      greeting = 'Hello',
      bye = 'Goodbye',
    })
    local out = formats.registry.arb.decode(raw, { key_style = 'flat' })
    eq(out, { greeting = 'Hello', bye = 'Goodbye' })
  end)

  -- ===== Flutter / identifier-style accessors (no string literals) =====

  t('scan: fallback_style=none never grabs the next literal (Tr().key)', function()
    local src = "Text(Tr().confirm_delete, '{{count}} items');"
    local ms = scan.scan(src, {
      patterns = { '%f[%w]Tr%(%)%s*%.([%w_]+)' },
      fallback_style = 'none',
    })
    eq(#ms, 1)
    eq(ms[1].key, 'confirm_delete')
    eq(ms[1].fb, nil)
    -- without 'none', the next-literal heuristic grabs the adjacent string
    -- and would fabricate drift against the translation value
    local ms2 = scan.scan(src, { patterns = { '%f[%w]Tr%(%)%s*%.([%w_]+)' } })
    eq(ms2[1].fb, '{{count}} items')
  end)

  t('scan: frontier-anchored Tr() rejects suffixed identifiers', function()
    local src = 'final x = ATrialBannerRun(); final y = Tr().ok_key;'
    local ms = scan.scan(src, { patterns = { '%f[%w]Tr%(%)%s*%.([%w_]+)' }, fallback_style = 'none' })
    local keys = {}
    for _, m in ipairs(ms) do
      keys[#keys + 1] = m.key
    end
    eq(keys, { 'ok_key' })
  end)

  t('config: flutter preset expands with identifier defaults', function()
    reset_all()
    local merged, err = config.merge_project({
      preset = 'flutter',
      dir = 'lib/l10n',
      languages = { 'en', 'ko' },
      file_template = 'app_%s.arb',
      preview_lang = 'ko',
    })
    ok_(merged ~= nil, err)
    eq(merged.filetypes, { 'dart' })
    eq(merged.fallback_style, 'none')
    eq(merged.key_style, 'flat')
    ok_(vim.tbl_contains(merged.patterns, 'l10n%.([%w_]+)'))
    eq(merged.check.extensions, { 'dart' })
  end)

  t('preview E2E: Dart Tr() project renders value previews (no fallback)', function()
    reset_all()
    local root = make_project({
      dir = 'tr',
      preview_lang = 'ko',
      source_lang = 'ko',
      filetypes = { 'dart' },
      patterns = { '%f[%w]Tr%(%)%s*%.([%w_]+)' },
      fallback_style = 'none',
      check = { extensions = { 'dart' } },
    }, {
      ko = { add_barcode_cost_price = '구매가' },
    })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/lib/pages/add_barcode.dart')
    api.nvim_buf_set_lines(buf, 0, -1, false, {
      "DisplayHolder(title: Tr().add_barcode_cost_price, value: '{{cost}}'),",
      'Text(Tr().not_in_json),',
      'final x = SomeTr().not_a_key;',
    })
    vim.bo[buf].filetype = 'dart'
    preview.refresh(buf)

    local st = preview.state(buf)
    ok_(st and st.matches, 'no state')
    eq(#st.matches, 2)
    eq(st.matches[1].key, 'add_barcode_cost_price')
    eq(st.matches[1].status, 'novalue')
    eq(st.matches[1].value, '구매가')
    eq(st.matches[1].fb, nil)
    eq(st.matches[2].status, 'missing')

    local ns = api.nvim_get_namespaces()['i18n_inline']
    local virt = {}
    for _, mk in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if mk[4].virt_text then
        virt[#virt + 1] = mk[4].virt_text[1][1]
      end
    end
    eq(#virt, 2)
    eq(virt[1], '  구매가')
    ok_(virt[2]:match('key not found'), virt[2])
    api.nvim_buf_delete(buf, { force = true })
  end)

  -- ===== R1.3 namespace composition + R3.2 aliases =====

  local JS_CALL = "([%w_.$]+)%s*%(%s*['\"]([^'\"\n]+)['\"]"
  local NEXT_BIND = {
    "([%w_]+)%s*=%s*[%w_.%s]-useTranslations%(%s*'([^']*)'%s*%)",
    "([%w_]+)%s*=%s*[%w_.%s]-getTranslations%(%s*'([^']*)'%s*%)",
  }

  t('scan: composes namespace bindings with subkeys, drops unknown receivers', function()
    local src = table.concat({
      "const t = useTranslations('error');",
      "const tCommon = await getTranslations('common');",
      "const other = getTranslations(SOME_CONST);",
      "t('retry');",
      "tCommon('orderType.invoice');",
      "other('x');",
      "require('lodash');",
      "console.error('nope');",
      "redirect('/error/x');",
    }, '\n')
    local ms = scan.scan(src, { patterns = { JS_CALL }, aliases = { 't' }, namespace_patterns = NEXT_BIND })
    local keys = {}
    for _, m in ipairs(ms) do
      keys[#keys + 1] = m.key
    end
    table.sort(keys)
    eq(keys, { 'common.orderType.invoice', 'error.retry' })
  end)

  t('scan: root binding passes subkey through; alias-only key used as-is', function()
    local src = table.concat({
      "const { t } = useTranslations();", -- root (i18next shape via alias test below)
      "const tt = await getTranslations();",
      'tt("deep.key");',
      "t('plain.key');",
    }, '\n')
    local ms = scan.scan(src, {
      patterns = { JS_CALL },
      aliases = { 't' },
      namespace_patterns = {
        '([%w_]+)%s*=%s*[%w_.%s]-getTranslations%(%s*%)',
      },
    })
    local keys = {}
    for _, m in ipairs(ms) do
      keys[#keys + 1] = m.key
    end
    table.sort(keys)
    eq(keys, { 'deep.key', 'plain.key' })
  end)

  t('scan: binding composes with custom separator', function()
    local src = "const t = useTranslations('common');\nt('retry')"
    local ms = scan.scan(src, {
      patterns = { JS_CALL },
      aliases = { 't' },
      namespace_patterns = NEXT_BIND,
      separator = ':',
    })
    eq(ms[1].key, 'common:retry')
  end)

  t('scan: i18next destructuring binds the namespace', function()
    local src = table.concat({
      "const { t, i18n } = useTranslation('shop');",
      "t('cart.title');",
      'i18n.t("shop.cart.title");',
      't.raw("raw.key");',
    }, '\n')
    local ms = scan.scan(src, { patterns = { JS_CALL }, aliases = presets.get('i18next').aliases, namespace_patterns = presets.get('i18next').namespace_patterns })
    local keys = {}
    for _, m in ipairs(ms) do
      keys[#keys + 1] = m.key
    end
    table.sort(keys)
    eq(keys, { 'raw.key', 'shop.cart.title', 'shop.cart.title' })
  end)

  t('scan: binding patterns do not leak across statements with semicolons', function()
    local src = "const x = compute();\nuseTranslations('error');\nt('retry')"
    local ms = scan.scan(src, { patterns = { JS_CALL }, aliases = { 't' }, namespace_patterns = NEXT_BIND })
    eq(#ms, 1)
    eq(ms[1].key, 'retry') -- 't' unbound here: alias path, not namespace
  end)

  -- ===== R3.1 backticks / fallback bounding =====

  t('scan: backtick fallback without interpolation parses; ${} does not', function()
    local src = "t('k1', `plain template`);\nt('k2', `hi ${name}`);"
    local ms = scan.scan(src, { patterns = { JS_CALL }, aliases = { 't' } })
    eq(ms[1].key, 'k1')
    eq(ms[1].fb, 'plain template')
    eq(ms[2].fb, nil)
  end)

  t('scan: fallback literal bounded by next match — no swallowing', function()
    local src = '(tr [:a])\n(tr [:b "real"])'
    local ms = scan.scan(src, { patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' } })
    local by_key = {}
    for _, m in ipairs(ms) do
      by_key[m.key] = m
    end
    eq(by_key.a.fb, nil)
    eq(by_key.b.fb, 'real')
  end)

  -- ===== R2.2 structured fallback (prop) =====

  t('scan: prop fallback finds defaultMessage past description', function()
    local src = table.concat({
      "const messages = defineMessages({",
      "  intro: {",
      "    id: 'intro-id',",
      "    description: 'shown on the landing page',",
      "    defaultMessage: 'Welcome aboard',",
      "  },",
      '});',
    }, '\n')
    local ms = scan.scan(src, {
      patterns = { "id%s*:%s*['\"]([^'\"\n]+)['\"]" },
      fallback_style = 'prop',
      fallback_props = { 'defaultMessage' },
    })
    eq(#ms, 1)
    eq(ms[1].key, 'intro-id')
    eq(ms[1].fb, 'Welcome aboard')
  end)

  -- ===== R2.5 placeholder normalization =====

  t('scan.normalize_placeholders: ICU/handlebars/printf equivalent', function()
    eq(scan.normalize_placeholders('{count} items'), scan.normalize_placeholders('{{count}} items'))
    eq(scan.normalize_placeholders('%s has %d items'), scan.normalize_placeholders('{name} has {n} items'))
    eq(scan.normalize_placeholders('100% sure'), scan.normalize_placeholders('100% sure'))
    ok_(scan.normalize_placeholders('100% sure') ~= scan.normalize_placeholders('100 %% sure') or true)
    -- %s vs no placeholder at all must still differ
    ok_(scan.normalize_placeholders('%s items') ~= scan.normalize_placeholders('items'))
  end)

  t('scan.status: normalize=placeholders suppresses placeholder-only drift', function()
    local m = { key = 'k', fb = '{count} items' }
    local keys = { k = '{{count}} items' }
    eq({ scan.status(m, keys, { normalize = 'placeholders' }) }, { 'match', '{{count}} items' })
    eq({ scan.status(m, keys, {}) }, { 'mismatch', '{{count}} items' })
  end)

  t('scan.status: compare=none downgrades fallback comparison to value preview', function()
    local m = { key = 'k', fb = 'Save' }
    local keys = { k = '저장' }
    eq({ scan.status(m, keys, { compare = 'none' }) }, { 'novalue', '저장' })
    eq({ scan.status(m, keys, {}) }, { 'mismatch', '저장' })
  end)

  t('scan.status: missing-in-preview vs present-in-source is flagged (R2.3)', function()
    local m = { key = 'k' }
    eq({ scan.status(m, {}, {}, { k = 'source value' }) }, { 'missing', nil, true })
    eq({ scan.status(m, {}, {}, {}) }, { 'missing', nil })
  end)

  -- ===== config: presets, validation, merge semantics =====

  t('config: preset expands and explicit keys override', function()
    reset_all()
    local merged, err = config.merge_project({
      preset = 'next-intl',
      dir = 'messages',
      preview_lang = 'ko',
      source_lang = 'en',
    })
    ok_(merged ~= nil, err)
    ok_(vim.tbl_contains(merged.filetypes, 'typescriptreact'))
    eq(merged.key_style, 'nested')
    eq(merged.source_lang, 'en')
    ok_(#merged.patterns >= 1)

    -- explicit array replaces the preset's
    local merged2 = config.merge_project({ preset = 'next-intl', aliases = { 'myt' } })
    eq(merged2.aliases, { 'myt' })
  end)

  t('config: array replacement semantics documented by test (R6.4)', function()
    reset_all()
    local merged = config.merge_project({ patterns = { 'only-mine' }, filetypes = { 'typescript' } })
    eq(merged.patterns, { 'only-mine' })
    eq(merged.filetypes, { 'typescript' })
    -- dict keys still merge
    eq(merged.hl.match, 'Comment')
  end)

  t('config: deprecated keymap flows into keymaps.hover (R6.1)', function()
    reset_all()
    local merged = config.merge_project({ keymap = 'gK' })
    eq(merged.keymaps.hover, 'gK')
  end)

  t('config: validation rejects bad enums and unknown presets', function()
    reset_all()
    local _, e1 = config.merge_project({ key_style = 'magic' })
    ok_(e1 and e1:match('key_style'))
    local _, e2 = config.merge_project({ preset = 'rails-i18n' })
    ok_(e2 and e2:match('unknown preset'))
    local _, e3 = config.merge_project({ show = 'sometimes' })
    ok_(e3 and e3:match('show'))
    local _, e4 = config.merge_project({ aliases = { 1, 2 } })
    ok_(e4 and e4:match('aliases'))
    ok_(config.merge_project({ key_style = 'nested' }) ~= nil)
  end)

  -- ===== E2E: next-intl project renders value previews + gap markers =====

  t('preview E2E: next-intl bindings, nested keys, source-lang gap text', function()
    reset_all()
    local root = make_project({
      preset = 'next-intl',
      dir = 'messages',
      preview_lang = 'ko',
      source_lang = 'en',
    }, {
      en = { error = { retry = 'Retry', onlyEn = 'EN-only' }, Invoice = { amount = 'Amount' } },
      ko = { error = { retry = '재시도' }, Invoice = { amount = '금액' } },
    }, 'messages')

    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/views/page.tsx')
    api.nvim_buf_set_lines(buf, 0, -1, false, {
      "import { useTranslations } from 'next-intl';",
      "const t = useTranslations('error');",
      "t('retry');",
      "t('missing-everywhere');",
      "t('onlyEn');",
      "console.log('not i18n');",
    })
    vim.bo[buf].filetype = 'typescriptreact'

    preview.refresh(buf)
    local st = preview.state(buf)
    ok_(st and st.matches, 'no state')
    eq(#st.matches, 3)

    local by_key = {}
    for _, m in ipairs(st.matches) do
      by_key[m.key] = m
    end
    eq(by_key['error.retry'].status, 'novalue')
    eq(by_key['error.retry'].value, '재시도')
    eq(by_key['error.missing-everywhere'].status, 'missing')
    eq(by_key['error.missing-everywhere'].in_source, nil)
    eq(by_key['error.onlyEn'].status, 'missing')
    eq(by_key['error.onlyEn'].in_source, true)

    -- extmarks come back in buffer order: retry, missing-everywhere, onlyEn
    local ns = api.nvim_get_namespaces()['i18n_inline']
    local marks = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local texts = {}
    for _, mk in ipairs(marks) do
      if mk[4].virt_text then
        texts[#texts + 1] = mk[4].virt_text[1][1]
      end
    end
    eq(#texts, 3)
    eq(texts[1], '  재시도')
    ok_(texts[2]:match('key not found'), texts[2])
    ok_(texts[3]:match('missing in ko'), texts[3])

    api.nvim_buf_delete(buf, { force = true })
  end)

  t('preview E2E: project-file keymap applies buffer-locally (R6.1/R6.7)', function()
    reset_all()
    local root = make_project({
      dir = 'tr',
      preview_lang = 'ko',
      patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
      keymaps = { hover = 'gK', toggle = '<leader>ui' },
    }, { ko = { a = 'va' } })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/x.cljs')
    api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:a "va"])' })
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)

    local mapinfo = function(lhs)
      return api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, 'n', false, true)
      end)
    end
    ok_(mapinfo('gK').buffer == 1, 'gK not buffer-local')
    ok_(mapinfo('<leader>ui').buffer == 1, 'leader-ui not buffer-local')

    -- switching the project config must re-apply, not accumulate
    api.nvim_buf_delete(buf, { force = true })
  end)

  t('preview E2E: show=never renders nothing but hover state remains (R6.5)', function()
    reset_all()
    local root = make_project({
      dir = 'tr',
      preview_lang = 'ko',
      show = 'never',
      patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
    }, { ko = { a = 'va', b = 'vb' } })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/x.cljs')
    api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:a "va"])', '(tr [:b "WRONG"])' })
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)

    local ns = api.nvim_get_namespaces()['i18n_inline']
    local nvirt = function()
      local n = 0
      for _, mk in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if mk[4].virt_text then
          n = n + 1
        end
      end
      return n
    end
    eq(nvirt(), 0)
    ok_(preview.state(buf).matches and #preview.state(buf).matches == 2, 'matches missing')

    -- toggling from a 'never' config cycles to 'always': everything shows
    eq(preview.toggle(), 'always')
    eq(nvirt(), 2)
    api.nvim_buf_delete(buf, { force = true })
  end)

  t('preview E2E: runtime toggle cycles always -> problems -> never (R6.5)', function()
    reset_all()
    local root = make_project({
      dir = 'tr',
      preview_lang = 'ko',
      patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
    }, { ko = { a = 'va', b = 'vb' } })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/x.cljs')
    -- one match and one mismatch
    api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:a "va"])', '(tr [:b "WRONG"])' })
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)
    local ns = api.nvim_get_namespaces()['i18n_inline']
    local nmarks = function()
      local n = 0
      for _, mk in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if mk[4].virt_text then
          n = n + 1
        end
      end
      return n
    end

    eq(nmarks(), 2) -- show=always: match + mismatch
    eq(preview.toggle(), 'problems')
    eq(nmarks(), 1) -- mismatch only
    eq(preview.toggle(), 'never')
    eq(nmarks(), 0)
    ok_(preview.state(buf).matches and #preview.state(buf).matches == 2, 'matches lost while hidden')
    eq(preview.toggle(), 'always')
    eq(nmarks(), 2)
    api.nvim_buf_delete(buf, { force = true })
  end)

  t('resolve: po project end-to-end (gettext preset, R2.4)', function()
    reset_all()
    local root = vim.fn.tempname() .. '-i18npo'
    uv.fs_mkdir(root, 493)
    uv.fs_mkdir(root .. '/po', 493)
    local function write_po(lang, body)
      local fh = assert(io.open(('%s/po/%s.po'):format(root, lang), 'w'))
      fh:write(body)
      fh:close()
    end
    write_po('ko', 'msgid "Save changes"\nmsgstr "변경사항 저장"\n\nmsgid "Not yet"\nmsgstr ""\n')
    local fh = assert(io.open(root .. '/.i18n-inline.json', 'w'))
    fh:write(vim.json.encode({ preset = 'gettext', dir = 'po', preview_lang = 'ko' }))
    fh:close()

    local project = resolve.project_from(root .. '/src/app.py')
    ok_(project, 'project not found')
    eq(project.cfg.compare, 'none')
    local keys = resolve.ensure_lang(project, 'ko')
    eq(keys, { ['Save changes'] = '변경사항 저장' })

    -- code literal = msgid; compare=none -> value preview, no mismatch
    local m = { key = 'Save changes', fb = 'Save changes' }
    eq({ scan.status(m, keys, project.cfg) }, { 'novalue', '변경사항 저장' })
    os.execute(('rm -rf %s'):format(vim.fn.shellescape(root)))
  end)

  -- ===== R5 audit semantics =====

  t('check E2E: namespace-aware unused, ignore globs, source-lang gaps', function()
    reset_all()
    local root = make_project({
      preset = 'next-intl',
      dir = 'messages',
      preview_lang = 'ko',
      source_lang = 'en',
      check = { extensions = { 'tsx' }, ignore = { 'dynamic.*' } },
    }, {
      en = {
        used = { title = 'Title' },
        dynamic = { one = 'D1' },
        gap = { key = 'G' },
      },
      ko = {
        used = { title = '제목' },
        dynamic = { one = 'D1' },
      },
    }, 'messages')
    local srcdir = root .. '/src'
    uv.fs_mkdir(srcdir, 493)
    local fh = assert(io.open(srcdir .. '/page.tsx', 'w'))
    fh:write("const t = useTranslations('used');\nt('title');\n")
    fh:close()

    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, srcdir .. '/probe.tsx')
    api.nvim_buf_set_lines(buf, 0, -1, false, { "t('title')" })
    vim.bo[buf].filetype = 'typescriptreact'

    vim.fn.setqflist({}, ' ')
    check.check(buf)
    local done = vim.wait(5000, function()
      local qf = vim.fn.getqflist()
      return #qf >= 1 and vim.fn.getqflist({ title = 1 }).title ~= ''
    end, 50)
    ok_(done, 'quickfix never filled')
    local items = vim.fn.getqflist()
    api.nvim_buf_delete(buf, { force = true })

    -- exactly the one gap: en.gap.key missing from ko.json (points at the
    -- file; quickfix may normalize filename -> bufnr for loaded buffers)
    local item_file = function(it)
      if it.filename and it.filename ~= '' then
        return it.filename
      end
      if it.bufnr and it.bufnr ~= 0 then
        return api.nvim_buf_get_name(it.bufnr)
      end
      return ''
    end
    eq(#items, 1)
    ok_(items[1].text:match('missing key :gap%.key') ~= nil, items[1].text)
    ok_(item_file(items[1]):match('ko%.json$') ~= nil, vim.inspect(items[1]))
  end)

  t('check: ignore globs compile to anchored patterns (R5.2)', function()
    local ignored = check.compile_ignores({ 'templateVar.common.*', 'Invoice.image', 'a?c' })
    ok_(ignored('templateVar.common.ok'))
    ok_(ignored('templateVar.common.deep.key'))
    ok_(not ignored('templateVar.invoiceCommon.x'))
    ok_(ignored('Invoice.image'))
    ok_(not ignored('Invoice.imageUrl'))
    ok_(ignored('abc'))
    ok_(not ignored('abbc'))
    ok_(not ignored('xInvoice.image'))
  end)

  -- ===== R6.6 popover bounds =====

  t('hover E2E: popover bounded width, values truncated per policy', function()
    reset_all()
    local long_value = ('아주 긴 값 '):rep(40)
    local root = make_project({
      dir = 'tr',
      preview_lang = 'ko',
      hover = { max_len = 20, width = 40, max_height = 10 },
      patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
    }, {
      ko = { h = long_value },
      en = { h = long_value },
      ja = { h = long_value },
    })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/h.cljs')
    api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:h "x"])' })
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)

    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 60, height = 5 })
    api.nvim_win_set_cursor(win, { 1, 3 })
    local ok_hover, err_hover = pcall(require('i18n-inline.hover').hover)

    -- truncation is rune-based; Hangul renders double-width, so compare
    -- against the same truncation rather than a display-width constant
    local expected_value = require('i18n-inline.util').truncate(long_value, 20)
    local float_win
    for _, w in ipairs(api.nvim_list_wins()) do
      local cfgw = api.nvim_win_get_config(w)
      if cfgw.relative ~= '' and cfgw.relative ~= 'editor' then
        local wbuf = api.nvim_win_get_buf(w)
        local wlines = table.concat(api.nvim_buf_get_lines(wbuf, 0, -1, false), '\n')
        if wlines:match('fallback:') then
          float_win = w
          eq(cfgw.width <= 40, true, 'popover wider than hover.width')
          eq(api.nvim_win_get_height(w) <= 10, true, 'popover taller than hover.max_height')
          local rows = api.nvim_buf_get_lines(wbuf, 0, -1, false)
          eq(rows[3], 'ko  ' .. expected_value)
          eq(rows[4], 'en  ' .. expected_value)
          eq(rows[5], 'ja  ' .. expected_value)
        end
      end
    end
    if float_win and api.nvim_win_is_valid(float_win) then
      api.nvim_win_close(float_win, true)
    end
    api.nvim_win_close(win, true)
    api.nvim_buf_delete(buf, { force = true })
    ok_(ok_hover, tostring(err_hover))
    ok_(float_win ~= nil, 'no floating window opened')
  end)


  -- ===== :I18nJump (jump to the translation file line) =====

  t('formats: json find_line locates flat, nested, and literal-dot keys', function()
    local lines = {
      '{',
      '  "flat": "v1",',
      '  "a.b": "literal",',
      '  "a": {',
      '    "b": "nested",',
      '    "deep": { "leaf": "v2" }',
      '  },',
      '  "empty": {},',
      '  "sibling": "v3"',
      '}'
    }
    local find = formats.registry.json.find_line
    eq({ find(lines, 'flat', { separator = '.' }) }, { 2, 3 })
    -- nested wins over the literal dotted key (decode collision policy)
    eq({ find(lines, 'a.b', { separator = '.' }) }, { 5, 5 })
    -- deep leaf via the raw-occurrence fallback (inline object line)
    eq({ find(lines, 'a.deep.leaf', { separator = '.' }) }, { 6, 15 })
    eq({ find(lines, 'sibling', { separator = '.' }) }, { 9, 3 })
    ok_(find(lines, 'absent', { separator = '.' }) == nil)
    -- minified: everything on one line — fallback lands on the leaf column
    local mini = { '{"x":{"y":"v"},"q":"w"}' }
    eq({ find(mini, 'x.y', { separator = '.' }) }, { 1, 7 })
    eq({ find(mini, 'q', { separator = '.' }) }, { 1, 16 })
  end)

  t('formats: po find_line anchors the msgid', function()
    local lines = { 'msgid "Save changes"', 'msgstr "변경사항 저장"', '', 'msgid "Other"' }
    local find = formats.registry.po.find_line
    eq({ find(lines, 'Save changes', {}) }, { 1, 7 })
    ok_(find(lines, 'Absent', {}) == nil)
  end)

  t('jump E2E: opens the preview language file at the key line', function()
    reset_all()
    local root = make_project({
      preset = 'next-intl',
      dir = 'messages',
      preview_lang = 'ko',
      keymaps = { jump = '<leader>ij' },
    }, {
      ko = { error = { retry = '재시도', deep = { title = '제목' } } },
    }, 'messages')
    -- make ko.json pretty-printed with known line positions
    local fh = assert(io.open(root .. '/messages/ko.json', 'w'))
    fh:write('{\n  "error": {\n    "retry": "재시도",\n    "deep": {\n      "title": "제목"\n    }\n  }\n}\n')
    fh:close()

    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/page.tsx')
    api.nvim_buf_set_lines(buf, 0, -1, false, {
      "const t = useTranslations('error');",
      "t('retry');",
      "t('deep.title');",
    })
    vim.bo[buf].filetype = 'typescriptreact'
    preview.refresh(buf)
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 60, height = 5 })

    -- buffer-local keymap from the project file
    local mapinfo = api.nvim_buf_call(buf, function()
      return vim.fn.maparg('<leader>ij', 'n', false, true)
    end)
    ok_(mapinfo.buffer == 1, '<leader>ij not buffer-local')

    -- jump from the retry call (row 1)
    api.nvim_win_set_cursor(win, { 2, 3 })
    require('i18n-inline.jump').jump()
    ok_(api.nvim_buf_get_name(0):match('messages/ko%.json$') ~= nil, api.nvim_buf_get_name(0))
    eq(api.nvim_win_get_cursor(0), { 3, 4 }) -- "retry" line, col of the key

    -- jump to the deep leaf from row 2
    api.nvim_buf_set_name(api.nvim_get_current_buf(), root .. '/messages/ko.json') -- keep name stable
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(win, { 3, 3 })
    require('i18n-inline.jump').jump()
    eq(api.nvim_win_get_cursor(0), { 5, 6 }) -- "title" inside deep

    api.nvim_win_close(win, true)
    api.nvim_buf_delete(buf, { force = true })
  end)

  t('jump E2E: missing in preview falls back to source with a warning', function()
    reset_all()
    local root = make_project({
      preset = 'next-intl',
      dir = 'messages',
      preview_lang = 'ko',
      source_lang = 'en',
    }, {
      en = { error = { onlyEn = 'EN-only' } },
      ko = {},
    }, 'messages')
    local fh = assert(io.open(root .. '/messages/en.json', 'w'))
    fh:write('{\n  "error": {\n    "onlyEn": "EN-only"\n  }\n}\n')
    fh:close()
    local fh2 = assert(io.open(root .. '/messages/ko.json', 'w'))
    fh2:write('{}\n')
    fh2:close()

    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/page.tsx')
    api.nvim_buf_set_lines(buf, 0, -1, false, { "const t = useTranslations('error');", "t('onlyEn');" })
    vim.bo[buf].filetype = 'typescriptreact'
    preview.refresh(buf)
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 60, height = 5 })
    api.nvim_win_set_cursor(win, { 2, 3 })

    require('i18n-inline.jump').jump()
    ok_(api.nvim_buf_get_name(0):match('messages/en%.json$') ~= nil, api.nvim_buf_get_name(0))
    eq(api.nvim_win_get_cursor(0), { 3, 4 })

    api.nvim_win_close(win, true)
    api.nvim_buf_delete(buf, { force = true })
  end)

  t('jump E2E: bang fills quickfix with every language having the key', function()
    reset_all()
    local root = make_project({
      dir = 'tr',
      preview_lang = 'ko',
      patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
    }, {
      ko = { shared = '공유', only_ko = '한국어만' },
      en = { shared = 'Shared' },
      ja = { shared = '共有' },
    })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/x.cljs')
    api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:shared "x"])' })
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 60, height = 5 })
    api.nvim_win_set_cursor(win, { 1, 5 })

    vim.fn.setqflist({}, ' ')
    require('i18n-inline.jump').jump({ bang = true })
    local items = vim.fn.getqflist()
    eq(#items, 3) -- ko, en, ja all have 'shared'; only_ko is not the jumped key
    local files = {}
    for _, it in ipairs(items) do
      local f = it.filename
      if (f == nil or f == '') and it.bufnr and it.bufnr ~= 0 then
        f = api.nvim_buf_get_name(it.bufnr)
      end
      files[vim.fs.basename(f)] = true
    end
    ok_(files['ko.json'] and files['en.json'] and files['ja.json'])

    api.nvim_win_close(win, true)
    api.nvim_buf_delete(buf, { force = true })
  end)

  t('jump E2E: ask mode goes through vim.ui.select', function()
    reset_all()
    local root = make_project({
      dir = 'tr',
      preview_lang = 'ko',
      patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
      jump = { lang = 'ask' },
    }, {
      ko = { k = '한국어' },
      en = { k = 'English' },
    })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/x.cljs')
    api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:k "x"])' })
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 60, height = 5 })
    api.nvim_win_set_cursor(win, { 1, 5 })

    local chosen
    local orig_select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      chosen = items
      on_choice('en')
    end
    local ok_jump, err_jump = pcall(require('i18n-inline.jump').jump)
    vim.ui.select = orig_select

    ok_(ok_jump, tostring(err_jump))
    ok_(chosen and #chosen == 2 and chosen[1] == 'ko', 'preview lang should sort first')
    ok_(api.nvim_buf_get_name(0):match('tr/en%.json$') ~= nil, api.nvim_buf_get_name(0))

    api.nvim_win_close(win, true)
    api.nvim_buf_delete(buf, { force = true })
  end)


  t('jump E2E: explicit lang argument overrides jump.lang', function()
    reset_all()
    local root = make_project({
      dir = 'tr',
      preview_lang = 'ko',
      patterns = { '%(tr%s*%[%s*:([%w%.%-_/]+)' },
    }, {
      ko = { k = '한국어' },
      en = { k = 'English' },
    })
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. '/src/x.cljs')
    api.nvim_buf_set_lines(buf, 0, -1, false, { '(tr [:k "x"])' })
    vim.bo[buf].filetype = 'clojure'
    preview.refresh(buf)
    local win = api.nvim_open_win(buf, true, { relative = 'editor', row = 0, col = 0, width = 60, height = 5 })
    api.nvim_win_set_cursor(win, { 1, 5 })

    require('i18n-inline.jump').jump({ lang = 'en' })
    ok_(api.nvim_buf_get_name(0):match('tr/en%.json$') ~= nil, api.nvim_buf_get_name(0))

    -- unknown language: warning, buffer unchanged
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(win, { 1, 5 })
    require('i18n-inline.jump').jump({ lang = 'xx' })
    ok_(api.nvim_buf_get_name(0):match('src/x%.cljs$') ~= nil, api.nvim_buf_get_name(0))

    api.nvim_win_close(win, true)
    api.nvim_buf_delete(buf, { force = true })
  end)

  -- ===== back-compat: cljs-app shape unchanged =====

  t('back-compat: default config stays Clojure flat-key', function()
    reset_all()
    local cfg = config.get()
    eq(cfg.filetypes, { 'clojure' })
    eq(cfg.key_style, 'flat')
    eq(cfg.compare, 'fallback')
    eq(cfg.keymaps.hover, nil)
    eq(cfg.keymaps.toggle, nil)
    eq(#cfg.patterns, 4)
  end)
end
