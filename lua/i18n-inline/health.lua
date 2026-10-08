-- :checkhealth i18n-inline

local config = require('i18n-inline.config')
local resolve = require('i18n-inline.resolve')

local M = {}

function M.check()
  vim.health.start('i18n-inline.nvim')

  local v = vim.version()
  if v.major == 0 and v.minor >= 10 then
    vim.health.ok(('Neovim %d.%d.%d'):format(v.major, v.minor, v.patch))
  else
    vim.health.error('Neovim 0.10+ is required (vim.uv API)')
  end

  local cfg = config.get()
  if #cfg.patterns > 0 then
    vim.health.ok(
      ('%d extraction patterns, filetypes: %s'):format(#cfg.patterns, table.concat(cfg.filetypes, ', '))
    )
  else
    vim.health.error('patterns is empty')
  end

  local cwd = vim.uv.cwd() or '.'
  local project = resolve.project_from(cwd)
  if not project then
    vim.health.warn(('no translation project found from %s (check `dir` or add a %s)'):format(cwd, cfg.project_file))
    return
  end

  if project.config_file then
    vim.health.ok(('project config: %s'):format(project.config_file))
  else
    vim.health.ok(('translation directory: %s (no %s, using setup defaults)'):format(project.dir, cfg.project_file))
  end

  local langs = {}
  for lang in pairs(project.langs) do
    langs[#langs + 1] = lang
  end
  table.sort(langs)
  vim.health.ok(('languages: %s'):format(table.concat(langs, ', ')))

  local keys, err = resolve.ensure_lang(project, project.cfg.preview_lang)
  if keys then
    local n = 0
    for _ in pairs(keys) do
      n = n + 1
    end
    vim.health.ok(('preview language "%s": %d keys loaded'):format(project.cfg.preview_lang, n))
  else
    vim.health.error(err or ('failed to load preview language "%s"'):format(project.cfg.preview_lang))
  end
end

return M
