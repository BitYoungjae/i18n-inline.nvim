-- Translation file formats (R4).
--
-- A format is a registry entry with two functions:
--   decode(raw, cfg) -> flat key->value map  |  nil, err
--   find_line(lines, key, cfg) -> lnum, col, len | nil   (1-based; :I18nJump;
--                                 len = byte length of the token to flash)
-- The decoded map is always FLAT and STRING-VALUED: string key -> string.
-- Numbers and booleans are stringified, JSON nulls and (in flat mode)
-- nested objects are dropped, so consumers index `keys[key]` and get a
-- displayable string or nil — never vim.NIL or a table. Formats with
-- hierarchical data (nested JSON) flatten at decode time using
-- cfg.key_style / cfg.separator, so scan/preview/hover/check never deal
-- with paths.
--
-- Line location is a raw-text search over the file's lines, done at jump
-- time only: the decode cache stores flat maps (positions are gone after
-- flattening, and vim.json.decode never reported them), translation files
-- are small enough that re-reading one is sub-millisecond, and the result
-- is always fresh.
--
-- Adding a format = adding one registry entry; resolve.lua picks it by file
-- extension (or the `format` config key) and the mtime+size cache contract
-- applies unchanged.

local util = require('i18n-inline.util')

local M = {}

-- Leaf value -> display string, or nil for values that are not messages
-- (JSON null decodes to vim.NIL; tables are structure, not values).
local function scalar(v)
  local t = type(v)
  if t == 'string' then
    return v
  elseif t == 'number' or t == 'boolean' then
    return tostring(v)
  end
  return nil
end

-- Flatten a nested table into separator-joined paths.
-- Collision policy (R1.5): when a literal leaf key like "a.b" and a nested
-- path {"a": {"b": …}} produce the same flat key, the path composed from
-- MORE segments (the structural one) wins; ties between equally-deep
-- spellings are inherently ambiguous and resolve arbitrarily. Segment
-- counting makes this deterministic regardless of table iteration order.
local function flatten(tbl, sep, out, segs, prefix, seg_count)
  for k, v in pairs(tbl) do
    local path = prefix == '' and k or (prefix .. sep .. k)
    if type(v) == 'table' then
      flatten(v, sep, out, segs, path, seg_count + 1)
    else
      local prev = segs[path]
      v = scalar(v)
      if v ~= nil and (prev == nil or seg_count > prev) then
        segs[path] = seg_count
        out[path] = v
      end
    end
  end
end

M.flatten = flatten

local function decode_json(raw, cfg)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok then
    return nil, 'invalid JSON: ' .. tostring(decoded)
  end
  if type(decoded) ~= 'table' then
    return nil, 'expected a JSON object at the top level'
  end
  local out = {}
  if cfg.key_style ~= 'nested' then
    -- Flat: top-level scalars only. A nested object here means a
    -- key_style mismatch (:checkhealth reports it); showing it as
    -- "table: 0x…" would be noise, so it reads as missing instead.
    for k, v in pairs(decoded) do
      out[k] = scalar(v)
    end
    return out
  end
  local segs = {}
  flatten(decoded, cfg.separator or '.', out, segs, '', 1)
  return out
end

-- Map every leaf of a pretty-printed JSON object tree to its position,
-- joining the structural path with \1 (unambiguous even when keys contain
-- the separator). Indentation tracks nesting: closing brackets pop every
-- frame at a deeper-or-equal indent, a `key: {` line pushes. Array elements
-- are not indexed (translation catalogs don't address through arrays);
-- leaves inside an array attach to the enclosing object path.
local function json_leaf_positions(lines)
  local out = {}
  local stack = {}
  for lnum, line in ipairs(lines) do
    local indent = #line:match('^%s*')
    if line:match('^%s*[}%]]') then
      while #stack > 0 and stack[#stack].indent >= indent do
        stack[#stack] = nil
      end
    end
    local ind, key, opening = line:match('^(%s*)"([^"]+)"%s*:%s*([%[{]?)')
    if key then
      -- only an object the line leaves open nests the lines below it
      if opening == '{' and line:match('{%s*$') then
        stack[#stack + 1] = { indent = indent, key = key }
      elseif opening == '' then
        local segs = {}
        for _, fr in ipairs(stack) do
          segs[#segs + 1] = fr.key
        end
        segs[#segs + 1] = key
        out[table.concat(segs, '\1')] = { lnum = lnum, col = #ind + 1 }
      end
      -- inline `{…}` or `[…]` values: leaves inside are invisible here and
      -- fall through to the raw-occurrence fallback in json_find_line
    end
  end
  return out
end

-- JSON line lookup: structural path first (nested wins, matching the
-- decode collision policy), then the key as a whole (flat files, literal
-- separator characters inside a key), then a raw first occurrence of the
-- quoted last segment (minified or oddly formatted files still land
-- somewhere useful).
local function json_find_line(lines, key, cfg)
  local positions = json_leaf_positions(lines)
  local segs = vim.split(key, cfg.separator or '.', { plain = true })
  local leaf = segs[#segs]
  if #segs > 1 then
    local pos = positions[table.concat(segs, '\1')]
    if pos then
      return pos.lnum, pos.col, #leaf + 2
    end
  end
  local pos = positions[key]
  if pos then
    return pos.lnum, pos.col, #key + 2
  end
  local pat = '"' .. util.pattern_escape(leaf) .. '"'
  for lnum, line in ipairs(lines) do
    local col = line:find(pat)
    if col then
      return lnum, col, #leaf + 2
    end
  end
  return nil
end

-- Unescape a gettext string literal body: \\, \", \n, \t.
local function po_unescape(s)
  return (
    s:gsub('\\(.)', function(c)
      if c == 'n' then
        return '\n'
      elseif c == 't' then
        return '\t'
      end
      return c
    end)
  )
end

-- Minimal gettext .po parser: msgid/msgstr pairs with continuation lines,
-- plural entries (value = msgstr[0]). Skips the header entry (empty msgid),
-- context-qualified entries (msgctxt — code lookups cannot address them
-- unambiguously), obsolete (`#~`) and fuzzy entries, and untranslated
-- entries (empty msgstr) — those read as missing keys downstream.
local function decode_po(raw, _cfg)
  local out = {}
  -- The entry being read: { id, str, skip }, and where continuation lines
  -- go ('id' | 'str', or nil for parts that are not kept: msgctxt,
  -- msgid_plural, msgstr[n > 0]).
  local entry, mode = nil, nil
  -- A fuzzy flag or msgctxt seen before the next msgid: marks that entry.
  -- Comments come in any number before it (`#,` flags, then `#|` previous
  -- msgids, as msgmerge writes them), so only a msgid consumes it.
  local skip_next = false

  local function flush()
    if entry and not entry.skip and entry.id ~= '' and entry.str and entry.str ~= '' then
      out[entry.id] = entry.str
    end
    entry, mode = nil, nil
  end

  for line in raw:gmatch('[^\r\n]+') do
    if line:match('^%s*#') then
      flush()
      -- flags live on `#,` lines only: "fuzzy" in a translator comment
      -- is just a word
      local flags = line:match('^%s*#,(.*)$')
      if flags and flags:find('%f[%w-]fuzzy%f[^%w-]') then
        skip_next = true
      end
    else
      local body = line:match('^%s*msgid%s+"(.*)"%s*$')
      local ctxt = line:match('^%s*msgctxt%s+')
      local plural = line:match('^%s*msgid_plural%s+')
      local str0 = line:match('^%s*msgstr%s+"(.*)"%s*$')
      local idx, strn = line:match('^%s*msgstr%[(%d+)%]%s+"(.*)"%s*$')
      local cont = line:match('^%s*"(.*)"%s*$') -- continuation: bare quoted line
      if ctxt then
        flush()
        skip_next = true
      elseif body then
        flush() -- a msgid always starts a new entry
        entry, mode = { id = po_unescape(body), skip = skip_next }, 'id'
        skip_next = false
      elseif not entry then -- msgstr or continuation outside an entry
        mode = nil
      elseif plural then
        mode = nil
      elseif str0 then
        entry.str, mode = po_unescape(str0), 'str'
      elseif strn then
        if idx == '0' then -- plural "one" form; other forms ignored
          entry.str, mode = po_unescape(strn), 'str'
        else
          mode = nil
        end
      elseif cont then
        local c = po_unescape(cont)
        if mode == 'id' then
          entry.id = entry.id .. c
        elseif mode == 'str' then
          entry.str = entry.str .. c
        end
      end
    end
  end
  flush()
  return out
end

-- Flutter ARB: JSON with metadata entries (`@@locale`, `@key` descriptors)
-- alongside the real messages. Drop the metadata; messages are flat
-- (gen-l10n getter names are the keys).
local function decode_arb(raw, cfg)
  local out, err = decode_json(raw, cfg)
  if not out then
    return nil, err
  end
  for k in pairs(out) do
    if k:sub(1, 1) == '@' then
      out[k] = nil
    end
  end
  return out
end

-- PO line lookup: the line of the matching msgid, comparing the unescaped
-- msgid including continuation lines (multiline `msgid ""` entries are
-- found too). The flash covers the first line's literal.
local function po_find_line(lines, key, _cfg)
  for lnum, line in ipairs(lines) do
    local body = line:match('^%s*msgid%s+"(.*)"%s*$')
    if body then
      local parts = { body }
      local i = lnum + 1
      while lines[i] do
        local cont = lines[i]:match('^%s*"(.*)"%s*$')
        if not cont then
          break
        end
        parts[#parts + 1] = cont
        i = i + 1
      end
      if po_unescape(table.concat(parts)) == key then
        local col = line:find('"')
        return lnum, col, #body + 2
      end
    end
  end
  return nil
end

local registry = {
  json = { decode = decode_json, find_line = json_find_line, extensions = { 'json' } },
  arb = { decode = decode_arb, find_line = json_find_line, extensions = { 'arb' } },
  po = { decode = decode_po, find_line = po_find_line, extensions = { 'po' } },
}

function M.names()
  local names = {}
  for name in pairs(registry) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- Format for a translation file: explicit cfg.format, else by extension.
function M.for_path(path, cfg)
  local fmt = cfg.format
  if fmt == nil then
    local ext = path:match('%.([%w]+)$')
    ext = ext and ext:lower() or ''
    for name, def in pairs(registry) do
      for _, e in ipairs(def.extensions) do
        if e == ext then
          fmt = name
          break
        end
      end
      if fmt then
        break
      end
    end
  end
  return registry[fmt]
end

M.registry = registry

return M
