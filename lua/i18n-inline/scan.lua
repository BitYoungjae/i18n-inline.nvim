-- Text scanning: find i18n calls, resolve their keys, and extract the
-- fallback string.
--
-- Pattern contract (per pattern, by capture arity):
--   1 capture  — capture #1 is the translation key (flat-key stacks; the
--                original Clojure contract, unchanged).
--   2 captures — #1 is the call RECEIVER, #2 the key argument. The match is
--                kept only when the receiver is a known namespace binding
--                (key = namespace .. separator .. subkey) or an alias
--                (key = subkey). This is what makes receiver-capturing
--                patterns safe: `require('x')`, `console.error('…')` etc.
--                are dropped by the receiver filter.
--
-- Namespace bindings come from `cfg.namespace_patterns` run as a pre-pass
-- over the same text:
--   2 captures — (variable, namespace literal); binds var → 'ns'
--   1 capture  — (variable); binds var → '' (root namespace)
-- e.g. `const t = useTranslations('error')` binds t → 'error'. Bindings are
-- file-scope and first-binding-wins (a re-bound name is a rarity; the first
-- binding is the stable guess).
--
-- Fallback extraction (`cfg.fallback_style`):
--   'literal' — the next string literal after the match, bounded by the next
--               match start so a following call's key is never swallowed.
--               `"`, `'` and backticks parse; a backtick containing `${` is
--               dynamic and rejected.
--   'prop'    — structured catalogs: search forward for one of
--               `cfg.fallback_props` (`propName: "…"`) within the same
--               bounded region (defineMessages defaultMessage, …).
--   'none'    — no fallback. For identifier-style calls (Flutter's
--               `Tr().key`, gen-l10n accessors) the next string literal is
--               unrelated code, and grabbing it would fabricate drift.
--
-- Match (byte offsets are 1-based):
--   {
--     key    = 'error.retry',           -- resolved key
--     fb     = 'Retry',                 -- unescaped fallback, nil when absent
--     call_s = byte offset where the call starts,
--     call_e = byte offset where the pattern match ends,
--     str_s  = byte offset of the fallback's opening quote,
--     str_e  = byte offset of the fallback's closing quote,
--   }

local M = {}

-- Parse the string literal starting at `start` (a quote character).
-- Returns unescaped content, opening quote offset, closing quote offset,
-- or nil when there is no valid static literal here.
local function parse_string_literal(text, start)
  local quote = text:sub(start, start)
  if quote ~= '"' and quote ~= "'" and quote ~= '`' then
    return nil
  end
  local out = {}
  local i = start + 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '\\' then
      local nxt = text:sub(i + 1, i + 1)
      if nxt == '' then
        return nil
      elseif nxt == 'n' then
        out[#out + 1] = '\n'
      elseif nxt == 't' then
        out[#out + 1] = '\t'
      else
        -- \\, \", \' and anything else keep the escaped character
        out[#out + 1] = nxt
      end
      i = i + 2
    elseif quote == '`' and c == '$' and text:sub(i + 1, i + 1) == '{' then
      return nil -- template literal with interpolation: not static
    elseif c == quote then
      return table.concat(out), start, i
    elseif c == '\n' then
      return nil -- unterminated: not a fallback literal
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return nil
end

M.parse_string_literal = parse_string_literal

-- Pre-pass: collect namespace bindings. Returns { varname = namespace }.
function M.extract_bindings(text, patterns)
  local bindings = {}
  for _, pat in ipairs(patterns or {}) do
    local init = 1
    while true do
      local s, e, name, ns = text:find(pat, init)
      if not s then
        break
      end
      init = e + 1
      if type(name) == 'string' and name ~= '' and bindings[name] == nil then
        bindings[name] = type(ns) == 'string' and ns or ''
      end
    end
  end
  return bindings
end

local function skip_ws(text, j)
  while j <= #text and text:sub(j, j):find('%s') do
    j = j + 1
  end
  return j
end

-- 'literal' fallback within (m.call_e, bound]: skip whitespace and one
-- optional comma (t('k', 'fb')) before the literal.
local function fallback_literal(text, m, bound)
  local j = skip_ws(text, m.call_e + 1)
  if text:sub(j, j) == ',' then
    j = skip_ws(text, j + 1)
  end
  if j <= bound and j <= #text then
    local fb, str_s, str_e = parse_string_literal(text, j)
    if fb then
      m.fb = fb
      m.str_s = str_s
      m.str_e = str_e
    end
  end
end

-- 'prop' fallback: `prop: "value"` within (m.call_e, bound]
local function fallback_prop(text, m, bound, props)
  for _, prop in ipairs(props or {}) do
    local pat = (prop:gsub('%W', '%%%0')) .. '%s*:%s*'
    local init = m.call_e + 1
    while init <= bound do
      local s, e = text:find(pat, init)
      if not s or s > bound then
        break
      end
      local j = skip_ws(text, e + 1)
      local fb, str_s, str_e = parse_string_literal(text, j)
      if fb then
        m.fb = fb
        m.str_s = str_s
        m.str_e = str_e
        return
      end
      init = e + 1
    end
  end
end

-- Resolve the effective key for a match, or nil to drop the match.
-- Receiver precedence: namespace binding first (it shadows aliases), then
-- the alias list ('*' accepts any receiver).
local function resolve_key(recv, sub, bindings, aliases, separator)
  if bindings and bindings[recv] ~= nil then
    local ns = bindings[recv]
    if ns == '' or ns == nil then
      return sub
    end
    return ns .. separator .. sub
  end
  if aliases and (aliases[recv] or aliases['*']) then
    return sub
  end
  return nil
end

function M.scan(text, cfg)
  local patterns = cfg.patterns or {}
  local aliases = nil
  if cfg.aliases then
    aliases = {}
    for _, a in ipairs(cfg.aliases) do
      aliases[a] = true
    end
  end
  local bindings = M.extract_bindings(text, cfg.namespace_patterns)
  local sep = cfg.separator or '.'

  local matches = {}
  local seen = {} -- dedupe across patterns by call start offset
  for _, pat in ipairs(patterns) do
    local init = 1
    while true do
      local s, e, c1, c2 = text:find(pat, init)
      if not s then
        break
      end
      init = e + 1
      if not seen[s] then
        seen[s] = true
        local m
        if c2 ~= nil then
          -- receiver + subkey form
          if c1 == nil or c2 == '' then
            m = nil
          else
            local key = resolve_key(c1, c2, bindings, aliases, sep)
            if key then
              m = { key = key, receiver = c1, subkey = c2, call_s = s, call_e = e }
            end
          end
        elseif c1 ~= nil and c1 ~= '' then
          m = { key = c1, call_s = s, call_e = e }
        end
        if m then
          matches[#matches + 1] = m
        end
      end
    end
  end
  table.sort(matches, function(a, b)
    return a.call_s < b.call_s
  end)

  -- Fallback extraction, each bounded by the next match's start so one
  -- call can never swallow the next call's key literal.
  if cfg.fallback_style ~= 'none' then
    for i, m in ipairs(matches) do
      local bound = (i < #matches and matches[i + 1].call_s or #text + 1) - 1
      if cfg.fallback_style == 'prop' then
        fallback_prop(text, m, bound, cfg.fallback_props)
      else
        fallback_literal(text, m, bound)
      end
    end
  end
  return matches
end

-- Placeholder normalization (R2.5): treat ICU `{name}`, handlebars `{{n}}`
-- and printf (`%s`, `%1$s`, `%.2f`, …) as the same canonical placeholder, so
-- syntax differences between code and file do not read as drift.
function M.normalize_placeholders(s)
  s = s:gsub('%%%%', '\0') -- literal %% → sentinel before the printf pass
  s = s:gsub('%b{}', '{}') -- {{n}} and {n} (balanced braces)
  s = s:gsub('%%[%-#+0-9.]*[$lLhzjt]*[diouxXeEfFgGcsqpqaA]', '{}')
  return (s:gsub('%z', '%%'))
end

-- Classify a match against a translation key table.
-- Returns 'match' | 'mismatch' | 'missing' | 'novalue', the display value,
-- and for 'missing' whether the key exists in the source language (a
-- translation gap rather than an unknown key).
function M.status(m, keys, cfg, source_keys)
  cfg = cfg or {}
  local v = keys and keys[m.key] or nil
  if v == nil or v == vim.NIL then
    if source_keys then
      local sv = source_keys[m.key]
      if sv ~= nil and sv ~= vim.NIL then
        return 'missing', nil, true
      end
    end
    return 'missing', nil
  end
  if type(v) ~= 'string' then
    v = tostring(v)
  end
  if m.fb == nil or cfg.compare == 'none' then
    return 'novalue', v
  end
  local a, b = m.fb, v
  if cfg.normalize == 'placeholders' then
    a, b = M.normalize_placeholders(a), M.normalize_placeholders(b)
  end
  if a == b then
    return 'match', v
  end
  return 'mismatch', v
end

return M
