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

local util = require('i18n-inline.util')

local M = {}

-- Code point -> UTF-8.
local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

-- Escapes that spell a character by its code: \xHH, \uXXXX (a UTF-16
-- surrogate pair spells one), \u{X…}. `i` is the backslash. Returns the
-- UTF-8 text and the offset just past the escape, or nil when malformed.
local function code_escape(text, i)
  local kind = text:sub(i + 1, i + 1)
  local hex = text:match(kind == 'x' and '^%x%x' or '^%x%x%x%x', i + 2)
  local next_i = hex and i + 2 + #hex
  if kind == 'u' and not hex then
    hex = text:match('^{(%x+)}', i + 2)
    next_i = hex and i + 4 + #hex
  end
  local cp = hex and #hex <= 6 and tonumber(hex, 16)
  if not cp or cp > 0x10FFFF then
    return nil
  end
  if cp >= 0xD800 and cp <= 0xDBFF then
    local low = text:match('^\\u(%x%x%x%x)', next_i)
    local lo = low and tonumber(low, 16)
    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
      cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
      next_i = next_i + 6
    end
  end
  return utf8_char(cp), next_i
end

local ESCAPES = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f', v = '\v', ['0'] = '\0' }

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
      local char, next_i
      if nxt == 'u' or nxt == 'x' then
        char, next_i = code_escape(text, i)
      end
      if nxt == '' then
        return nil
      elseif char then
        out[#out + 1] = char
        i = next_i
      else
        -- \\, \", \' and anything else keep the escaped character
        out[#out + 1] = ESCAPES[nxt] or nxt
        i = i + 2
      end
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

-- Patterns already reported as malformed.
local reported = {}

-- Call fn(s, e, c1, c2) for every match of `pat` in `text`. An empty match
-- moves on by one byte (it would be found again forever). A malformed
-- pattern is reported once and matches nothing: Lua only notices when the
-- matcher reaches the bad part, so validating the config cannot catch it.
local function each_match(text, pat, fn)
  local init = 1
  while init <= #text + 1 do
    local ok, s, e, c1, c2 = pcall(string.find, text, pat, init)
    if not ok then
      if not reported[pat] then
        reported[pat] = true
        local msg = tostring(s):gsub('^.-:%d+: ', '')
        util.notify(('invalid pattern %s: %s'):format(pat, msg), vim.log.levels.WARN)
      end
      return
    end
    if not s then
      return
    end
    init = math.max(e, s) + 1
    fn(s, e, c1, c2)
  end
end

-- Pre-pass: collect namespace bindings. Returns { varname = namespace }.
function M.extract_bindings(text, patterns)
  local bindings = {}
  for _, pat in ipairs(patterns or {}) do
    each_match(text, pat, function(_, _, name, ns)
      if type(name) == 'string' and name ~= '' and bindings[name] == nil then
        bindings[name] = type(ns) == 'string' and ns or ''
      end
    end)
  end
  return bindings
end

local function skip_ws(text, j)
  while j <= #text and text:sub(j, j):find('%s') do
    j = j + 1
  end
  return j
end

-- Set m's fallback from the literal at `j` when it is a whole argument:
-- what follows ends it (`,` `)` `]` `}`), or the next call starts. In
-- `t('k', 'a' + b)` the literal is only part of an expression.
local function take_literal(text, m, j, bound)
  local fb, str_s, str_e = parse_string_literal(text, j)
  if not fb then
    return false
  end
  local k = skip_ws(text, str_e + 1)
  if k <= bound and k <= #text and not text:sub(k, k):find('[,%)%]}]') then
    return false
  end
  m.fb, m.str_s, m.str_e = fb, str_s, str_e
  return true
end

-- 'literal' fallback within (m.call_e, bound]: skip whitespace and one
-- optional comma (t('k', 'fb')) before the literal.
local function fallback_literal(text, m, bound)
  local j = skip_ws(text, m.call_e + 1)
  if text:sub(j, j) == ',' then
    j = skip_ws(text, j + 1)
  end
  if j <= bound and j <= #text then
    take_literal(text, m, j, bound)
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
      if take_literal(text, m, skip_ws(text, e + 1), bound) then
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
  local aliases = cfg.aliases and util.set(cfg.aliases)
  local bindings = M.extract_bindings(text, cfg.namespace_patterns)
  local sep = cfg.separator or '.'

  local matches = {}
  local seen = {} -- dedupe across patterns by call start offset
  for _, pat in ipairs(patterns) do
    each_match(text, pat, function(s, e, c1, c2)
      if seen[s] then
        return
      end
      seen[s] = true
      local m
      if c2 ~= nil then
        -- receiver + subkey form
        if c1 ~= nil and c2 ~= '' then
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
    end)
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

-- Compare a match's fallback with the key's value (a string from a decoded
-- key table). Returns 'match' | 'mismatch' | 'novalue' (no fallback, or
-- compare = 'none') and the value.
function M.compare(m, v, cfg)
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

-- Classify a match against a translation key table (a decoded, flat
-- key -> string map; see formats.lua).
-- Returns 'match' | 'mismatch' | 'missing' | 'novalue', the display value,
-- and for 'missing' whether the key exists in the source language (a
-- translation gap rather than an unknown key). resolve.classify is the
-- catalog-aware version the plugin itself uses.
function M.status(m, keys, cfg, source_keys)
  local v = keys and keys[m.key]
  if v == nil then
    if source_keys and source_keys[m.key] ~= nil then
      return 'missing', nil, true
    end
    return 'missing', nil
  end
  return M.compare(m, v, cfg or {})
end

return M
