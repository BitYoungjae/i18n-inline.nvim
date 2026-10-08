-- Translation file formats (R4).
--
-- A format is a registry entry with one function:
--   decode(raw, cfg) -> flat key->value map  |  nil, err
-- The returned map is always FLAT: string key -> scalar value. Formats with
-- hierarchical data (nested JSON) flatten here using cfg.key_style /
-- cfg.separator, so scan/preview/hover/check never deal with paths.
--
-- Adding a format = adding one registry entry; resolve.lua picks it by file
-- extension (or the `format` config key) and the mtime+size cache contract
-- applies unchanged.

local M = {}

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
      if prev == nil or seg_count > prev then
        segs[path] = seg_count
        out[path] = v
      end
    end
  end
end

M.flatten = flatten

local function decode_json(raw, cfg)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= 'table' then
    return nil, 'failed to parse JSON'
  end
  if cfg.key_style ~= 'nested' then
    return decoded
  end
  local out, segs = {}, {}
  flatten(decoded, cfg.separator or '.', out, segs, '', 1)
  return out
end

-- Unescape a gettext string literal body: \\, \", \n, \t.
local function po_unescape(s)
  return (s:gsub('\\(.)', function(c)
    if c == 'n' then
      return '\n'
    elseif c == 't' then
      return '\t'
    end
    return c
  end))
end

-- Minimal gettext .po parser: msgid/msgstr pairs with continuation lines,
-- plural entries (value = msgstr[0]). Skips the header entry (empty msgid),
-- context-qualified entries (msgctxt — code lookups cannot address them
-- unambiguously), obsolete (`#~`) and fuzzy entries, and untranslated
-- entries (empty msgstr) — those read as missing keys downstream.
local function decode_po(raw, _cfg)
  local out = {}
  local msgid, msgstr, mode = nil, nil, nil -- mode: 'id' | 'plural' | 'str'
  local in_entry, skip_current, skip_next = false, false, false

  -- Records the finished entry (if valid and not skipped) and resets state.
  -- `skip_next` carries a fuzzy/msgctxt marker set BEFORE the entry started
  -- (comment lines precede msgid; msgctxt precedes msgid) into the entry
  -- that is about to begin.
  local function flush()
    if in_entry and not skip_current and msgid and msgstr and msgid ~= '' and msgstr ~= '' then
      out[msgid] = msgstr
    end
    msgid, msgstr, mode = nil, nil, nil
    in_entry = false
    skip_current = skip_next
    skip_next = false
  end

  for line in raw:gmatch('[^\r\n]+') do
    if line:match('^%s*#') then
      -- Comment lines (#, #., #~ …) end the previous entry. Obsolete lines
      -- carry `#~ msgid`/`#~ msgstr` which never match the patterns below,
      -- so they contribute nothing; fuzzy marks the entry that follows.
      flush()
      if line:match('fuzzy') then
        skip_next, in_entry = true, true
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
        skip_next, in_entry = true, true
      elseif body then
        flush() -- a msgid always starts a new entry
        in_entry = true
        msgid, mode = po_unescape(body), 'id'
      elseif plural then
        mode = 'plural'
      elseif str0 then
        msgstr, mode = po_unescape(str0), 'str'
      elseif strn then
        if idx == '0' then -- plural "one" form; other forms ignored
          msgstr, mode = po_unescape(strn), 'str'
        end
      elseif cont then
        local c = po_unescape(cont)
        if mode == 'id' and msgid then
          msgid = msgid .. c
        elseif mode == 'str' and msgstr then
          msgstr = msgstr .. c
        end
      end
    end
  end
  flush()
  return out
end

local registry = {
  json = { decode = decode_json, extensions = { 'json' } },
  po = { decode = decode_po, extensions = { 'po' } },
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
