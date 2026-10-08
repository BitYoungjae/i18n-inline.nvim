-- Text scanning: find i18n calls with the configured patterns and extract
-- the key plus the fallback string literal.
--
-- Pattern contract:
--   - capture #1 is the translation key (a string)
--   - the next string literal after the end of the match is parsed as the
--     fallback (when present; otherwise only the key lookup is possible)
--
-- Returned match (byte offsets are 1-based):
--   {
--     key    = 'common-button-confirm',
--     fb     = 'Confirm',          -- unescaped fallback, nil when absent
--     call_s = byte offset where the call starts,
--     call_e = byte offset where the key ends,
--     str_s  = byte offset of the opening quote,   -- only when fb exists
--     str_e  = byte offset of the closing quote,   -- only when fb exists
--   }

local M = {}

-- Parse the string literal starting at `start` (either quote character).
-- Returns unescaped content, opening quote offset, closing quote offset,
-- or nil when there is no valid literal here.
local function parse_string_literal(text, start)
  local quote = text:sub(start, start)
  if quote ~= '"' and quote ~= "'" then
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

function M.scan(text, patterns)
  local matches = {}
  local seen = {} -- dedupe across patterns by call start offset
  for _, pat in ipairs(patterns) do
    local init = 1
    while true do
      local s, e, key = text:find(pat, init)
      if not s then
        break
      end
      init = e + 1
      if not seen[s] then
        seen[s] = true
        local m = { key = key, call_s = s, call_e = e }
        -- Skip whitespace after the match, then parse the fallback literal
        local j = e + 1
        while j <= #text and text:sub(j, j):find('%s') do
          j = j + 1
        end
        if j <= #text then
          local fb, str_s, str_e = parse_string_literal(text, j)
          if fb then
            m.fb = fb
            m.str_s = str_s
            m.str_e = str_e
          end
        end
        matches[#matches + 1] = m
      end
    end
  end
  table.sort(matches, function(a, b)
    return a.call_s < b.call_s
  end)
  return matches
end

-- Classify a match against a translation key table.
-- Returns 'match' | 'mismatch' | 'missing' | 'novalue' (no fallback to
-- compare), plus the display value.
function M.status(m, keys)
  local v = keys and keys[m.key] or nil
  if v == nil or v == vim.NIL then
    return 'missing', nil
  end
  if type(v) ~= 'string' then
    v = tostring(v)
  end
  if m.fb == nil then
    return 'novalue', v
  end
  if v == m.fb then
    return 'match', v
  end
  return 'mismatch', v
end

return M
