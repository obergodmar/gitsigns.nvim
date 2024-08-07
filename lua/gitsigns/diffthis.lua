local async = require('gitsigns.async')
local manager = require('gitsigns.manager')
local message = require('gitsigns.message')
local util = require('gitsigns.util')
local Status = require('gitsigns.status')

local cache = require('gitsigns.cache').cache
local dprint = require('gitsigns.debug.log').dprint
local throttle_by_id = require('gitsigns.debounce').throttle_by_id

local api = vim.api

local M = {}

--- @async
--- @param bufnr integer
--- @param dbufnr integer
--- @param base string?
local function bufread(bufnr, dbufnr, base)
  local bcache = assert(cache[bufnr])
  base = util.norm_base(base)
  local text --- @type string[]
  if base == bcache.git_obj.revision then
    text = assert(bcache.compare_text)
  else
    local err
    text, err = bcache.git_obj:get_show_text(base)
    if err then
      error(err, 2)
    end
    async.scheduler()
    if not api.nvim_buf_is_valid(bufnr) then
      return
    end
  end

  vim.bo[dbufnr].fileformat = vim.bo[bufnr].fileformat
  vim.bo[dbufnr].filetype = vim.bo[bufnr].filetype
  vim.bo[dbufnr].bufhidden = 'wipe'

  local modifiable = vim.bo[dbufnr].modifiable
  vim.bo[dbufnr].modifiable = true
  Status:update(dbufnr, { head = base })

  util.set_lines(dbufnr, 0, -1, text)

  vim.bo[dbufnr].modifiable = modifiable
  vim.bo[dbufnr].modified = false
  require('gitsigns.attach').attach(dbufnr, nil, 'BufReadCmd')
end

--- @param bufnr integer
--- @param dbufnr integer
--- @param base string?
--- @param _callback? fun()
local bufwrite = async.create(3, function(bufnr, dbufnr, base, _callback)
  local bcache = assert(cache[bufnr])
  local buftext = util.buf_lines(dbufnr)
  base = util.norm_base(base)
  bcache.git_obj:stage_lines(buftext)
  async.scheduler()
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[dbufnr].modified = false
  -- If diff buffer base matches the git_obj revision then also update the
  -- signs.
  if base == bcache.git_obj.revision then
    bcache.compare_text = buftext
    manager.update(bufnr)
  end
end)

--- @async
--- Create a gitsigns buffer for a certain revision of a file
--- @param bufnr integer
--- @param base string?
--- @return string? buf Buffer name
local function create_show_buf(bufnr, base)
  local bcache = assert(cache[bufnr])
  base = util.norm_base(base)

  local bufname = bcache:get_rev_bufname(base)

  if util.bufexists(bufname) then
    return bufname
  end

  local dbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(dbuf, bufname)

  local ok, err = pcall(bufread, bufnr, dbuf, base)
  if not ok then
    message.error(err --[[@as string]])
    async.scheduler()
    api.nvim_buf_delete(dbuf, { force = true })
    return
  end

  -- allow editing the index revision
  if not bcache.git_obj.revision then
    vim.bo[dbuf].buftype = 'acwrite'

    api.nvim_create_autocmd('BufReadCmd', {
      group = 'gitsigns',
      buffer = dbuf,
      callback = function()
        async.run(bufread, bufnr, dbuf, base)
      end,
    })

    api.nvim_create_autocmd('BufWriteCmd', {
      group = 'gitsigns',
      buffer = dbuf,
      callback = function()
        bufwrite(bufnr, dbuf, base)
      end,
    })
  else
    vim.bo[dbuf].buftype = 'nowrite'
    vim.bo[dbuf].modifiable = false
  end

  return bufname
end

--- @class Gitsigns.DiffthisOpts
--- @field vertical boolean
--- @field split string

--- @async
--- @param base string?
--- @param opts? Gitsigns.DiffthisOpts
local function diffthis_rev(base, opts)
  local bufnr = api.nvim_get_current_buf()

  local bufname = create_show_buf(bufnr, base)
  if not bufname then
    return
  end

  opts = opts or {}

  vim.cmd(table.concat({
    'keepalt',
    opts.split or 'aboveleft',
    opts.vertical and 'vertical' or '',
    'diffsplit',
    bufname,
  }, ' '))
end

--- @param base string?
--- @param opts Gitsigns.DiffthisOpts
--- @param _callback? fun()
M.diffthis = async.create(2, function(base, opts, _callback)
  if vim.wo.diff then
    return
  end

  local bufnr = api.nvim_get_current_buf()
  local bcache = cache[bufnr]
  if not bcache then
    return
  end

  local cwin = api.nvim_get_current_win()
  if not base and bcache.git_obj.has_conflicts then
    diffthis_rev(':2', opts)
    api.nvim_set_current_win(cwin)
    opts.split = 'belowright'
    diffthis_rev(':3', opts)
  else
    diffthis_rev(base, opts)
  end
  api.nvim_set_current_win(cwin)
end)

--- @param bufnr integer
--- @param base string
--- @param _callback? fun()
M.show = async.create(2, function(bufnr, base, _callback)
  __FUNC__ = 'show'
  local bufname = create_show_buf(bufnr, base)
  if not bufname then
    dprint('No bufname for revision ' .. base)
    return
  end

  dprint('bufname ' .. bufname)
  vim.cmd.edit(bufname)
end)

--- @param bufnr integer
--- @return boolean
local function should_reload(bufnr)
  if not vim.bo[bufnr].modified then
    return true
  end
  local response --- @type string?
  while not vim.tbl_contains({ 'O', 'L' }, response) do
    response = async.wait(2, vim.ui.input, {
      prompt = 'Warning: The git index has changed and the buffer was changed as well. [O]K, (L)oad File:',
    })
  end
  return response == 'L'
end

-- This function needs to be throttled as there is a call to vim.ui.input
--- @param bufnr integer
--- @param _callback? fun()
M.update = throttle_by_id(async.create(1, function(bufnr, _callback)
  if not vim.wo.diff then
    return
  end

  -- Note this will be the bufname for the currently set base
  -- which are the only ones we want to update
  local bufname = assert(cache[bufnr]):get_rev_bufname()

  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(w) then
      local b = api.nvim_win_get_buf(w)
      local bname = api.nvim_buf_get_name(b)
      local is_fugitive_diff_window = vim.startswith(bname, 'fugitive://')
        and vim.fn.exists('*FugitiveParse')
        and vim.fn.FugitiveParse(bname)[1] ~= ':'
      if bname == bufname or is_fugitive_diff_window then
        if should_reload(b) then
          api.nvim_buf_call(b, function()
            vim.cmd.doautocmd('BufReadCmd')
            vim.cmd.diffthis()
          end)
        end
      end
    end
  end
end))

return M
