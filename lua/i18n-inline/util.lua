-- Utilities: byte offset <-> (line, col) conversion, rune-safe truncation,
-- display sanitization, file reading and source-tree walking.

local M = {}

function M.notify(msg, level)
  vim.notify('[i18n-inline] ' .. msg, level or vim.log.levels.INFO)
end

-- Absolute, normalized path. Deliberately not vim.fn.expand: it would
-- interpret `%`, `#` and `<cfile>` inside real file names.
function M.abspath(p)
  return vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(p), ':p'))
end

-- Whole file contents, or nil when unreadable.
function M.read_file(path)
  local fh = io.open(path, 'r')
  if not fh then
    return nil
  end
  local raw = fh:read('*a')
  fh:close()
  return raw
end

-- Source files under `root` whose extension is in `extensions`, skipping
-- directories named in `exclude_dirs`. Sorted; stops early at `limit`.
function M.walk_files(root, extensions, exclude_dirs, limit)
  local ext_set = {}
  for _, e in ipairs(extensions or {}) do
    ext_set[e:lower()] = true
  end
  local excl_set = {}
  for _, d in ipairs(exclude_dirs or {}) do
    excl_set[d] = true
  end
  limit = limit or math.huge
  local files = {}
  local function walk(dir)
    local fs = vim.uv.fs_scandir(dir)
    if not fs then
      return
    end
    while #files < limit do
      local name, ftype = vim.uv.fs_scandir_next(fs)
      if not name then
        break
      end
      local path = dir .. '/' .. name
      if ftype == 'directory' then
        if not excl_set[name] then
          walk(path)
        end
      elseif ftype == 'file' then
        local ext = name:match('%.([%w]+)$')
        if ext and ext_set[ext:lower()] then
          files[#files + 1] = path
        end
      end
    end
  end
  walk(root)
  table.sort(files)
  return files
end

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

-- Single-line, truncated, double-quoted rendering for messages. Not `%q`:
-- Lua's %q escapes a newline as backslash + a real newline, which breaks
-- quickfix text.
function M.quote(v, max_runes)
  return '"' .. M.truncate(M.display_value(v), max_runes or 60) .. '"'
end

return M
