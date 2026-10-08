-- Utilities: byte offset <-> (line, col) conversion, rune-safe truncation,
-- display sanitization.

local M = {}

-- Start byte offset (1-based) of each line. line_offsets[n] starts line n.
function M.build_line_offsets(text)
  local offsets = { 1 }
  for pos in text:gmatch('()\n') do
    offsets[#offsets + 1] = pos + 1
  end
  return offsets
end

-- Convert a 1-based byte offset to a 0-based (line, col). Binary search.
function M.byte_to_pos(line_offsets, off)
  local lo, hi = 1, #line_offsets
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if line_offsets[mid] <= off then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo - 1, off - line_offsets[lo]
end

-- Truncate to max_runes code points, appending '…' when cut.
function M.truncate(s, max_runes)
  if max_runes <= 0 then
    return ''
  end
  -- byte count <= max_runes implies rune count <= max_runes: skip counting
  if #s <= max_runes then
    return s
  end
  local boundaries = vim.str_utf_pos(s)
  if #boundaries <= max_runes then
    return s
  end
  return s:sub(1, boundaries[max_runes + 1] - 1) .. '…'
end

-- Sanitize a value for single-line display.
function M.display_value(v)
  v = tostring(v)
  v = v:gsub('[\r\n]+', ' ⏎ ')
  v = v:gsub('\t', ' ')
  return v
end

return M
