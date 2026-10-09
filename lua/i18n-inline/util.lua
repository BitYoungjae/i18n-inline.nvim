-- Utilities: byte offset <-> (line, col) conversion, rune-safe truncation,
-- display sanitization, file reading, path globs and source-tree walking.

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

function M.has_wildcard(s)
  return s:find('[%*%?]') ~= nil
end

-- One path segment of a glob -> anchored Lua pattern; `*` and `?` never
-- cross a '/'.
local function segment_pattern(seg)
  local escaped = seg:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%0')
  escaped = escaped:gsub('%*', '[^/]*'):gsub('%?', '[^/]')
  return '^' .. escaped .. '$'
end

M.segment_pattern = segment_pattern

-- Path glob -> predicate over '/'-separated relative paths. `*` and `?`
-- match within one segment; a `**` segment matches any number of segments,
-- none included (`src/**/x.tsx` matches `src/x.tsx`).
function M.path_glob(glob)
  local pats = {}
  for seg in glob:gmatch('[^/]+') do
    pats[#pats + 1] = seg == '**' and true or segment_pattern(seg)
  end
  local function match(i, parts, j)
    while i <= #pats do
      if pats[i] == true then
        for k = j, #parts + 1 do
          if match(i + 1, parts, k) then
            return true
          end
        end
        return false
      end
      if j > #parts or not parts[j]:find(pats[i]) then
        return false
      end
      i, j = i + 1, j + 1
    end
    return j > #parts
  end
  return function(path)
    return match(1, vim.split(path, '/', { plain = true, trimempty = true }), 1)
  end
end

-- `path` relative to `root` ('' for root itself), or nil when outside it.
function M.relpath(root, path)
  if path == root then
    return ''
  end
  if path:sub(1, #root + 1) == root .. '/' then
    return path:sub(#root + 2)
  end
  return nil
end

-- Source files under `root` whose extension is in `opts.extensions`.
-- Skipped directories:
--   - `opts.exclude_dirs` entries. A bare name matches at any depth; an
--     entry with a '/' is a path glob from root (`src/generated`,
--     `apps/*/dist`), the way .gitignore reads them.
--   - with `opts.project_file`, every subdirectory holding its own project
--     file: that tree belongs to another project.
-- Sorted; stops early at `opts.limit`. Returns the files and the skipped
-- project directories.
function M.walk_files(root, opts)
  local ext_set = {}
  for _, e in ipairs(opts.extensions or {}) do
    ext_set[e:lower()] = true
  end
  local excl_names, excl_paths = {}, {}
  for _, d in ipairs(opts.exclude_dirs or {}) do
    if d:find('/') then
      excl_paths[#excl_paths + 1] = M.path_glob(d)
    else
      excl_names[d] = true
    end
  end
  local function excluded(name, rel)
    if excl_names[name] then
      return true
    end
    for _, matches in ipairs(excl_paths) do
      if matches(rel) then
        return true
      end
    end
    return false
  end
  local limit = opts.limit or math.huge
  local marker = opts.project_file
  local files, projects = {}, {}
  local function walk(dir, rel)
    local fs = vim.uv.fs_scandir(dir)
    if not fs then
      return
    end
    -- list first: a project file can come after the subdirectories
    local entries = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(fs)
      if not name then
        break
      end
      if marker and rel ~= '' and name == marker and ftype ~= 'directory' then
        projects[#projects + 1] = dir
        return
      end
      entries[#entries + 1] = { name, ftype }
    end
    for _, entry in ipairs(entries) do
      if #files >= limit then
        return
      end
      local name, ftype = entry[1], entry[2]
      local path = dir .. '/' .. name
      if ftype == 'directory' then
        local sub = rel == '' and name or (rel .. '/' .. name)
        if not excluded(name, sub) then
          walk(path, sub)
        end
      elseif ftype == 'file' then
        local ext = name:match('%.([%w]+)$')
        if ext and ext_set[ext:lower()] then
          files[#files + 1] = path
        end
      end
    end
  end
  walk(root, '')
  table.sort(files)
  table.sort(projects)
  return files, projects
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
