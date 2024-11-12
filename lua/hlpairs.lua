local SEARCH_LINE_COUNT = 5
local PAIRS_CACHE_SIZE = 20
local prevent_remark = 0

local function is_empty(a)
  return a == nil or #a == 0
end

local function is_ne(a)
  return a ~= nil and #a ~= 0
end

local function concat(a, b)
  for i, v in pairs(b) do
    table.insert(a, v)
  end
  return a
end

local function csv(str, dlm)
  local a = {}
  local c = ''
  local d = dlm or ','
  for s in string.gmatch(str, '[^' .. d .. ']+') do
    if string.find(s, "\\$") then
      c = s .. dlm
    else
      table.insert(a, c .. s)
      c = ''
    end
  end
  return a
end

local function curpos()
  local cur = vim.api.nvim_win_get_cursor(0)
  return { cur[1], cur[2] + 1 }
end

local function setpos(cur)
  vim.api.nvim_win_set_cursor(0, { cur[1], cur[2] - 1 })
end

local function getline(buf, lnum)
  return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
end

local function getPairParams(text)
  local b_hlpairs = vim.b.hlpairs
  local pair = b_hlpairs.pairs_cache[text]
  if pair then
    return pair
  end
  for i, p in pairs(b_hlpairs.pairs_) do
    if vim.regex(p.s):match_str(text) then
      local k = b_hlpairs.pairs_cache_keys[1]
      if PAIRS_CACHE_SIZE < #b_hlpairs.pairs_cache_keys then
        table.remove(b_hlpairs.pairs_cache_keys, 1)
        b_hlpairs.pairs_cache[k] = nil
      end
      b_hlpairs.pairs_cache[text] = p
      table.insert(b_hlpairs.pairs_cache_keys, text)
      vim.b.hlpairs = b_hlpairs
      return p
    end
  end
  return nil
end

local function toList(v)
  return type(v) == 'string' and csv(v) or v or {}
end

local function onOptionSet()
  local ftpairs = {}
  local ignores = {}
  local ft = vim.o.filetype
  if ft then
    for k, v in pairs(vim.g.hlpairs.filetype) do
      if string.find(',' .. k .. ',', ',' .. ft .. ',') then
        if type(v) == 'table' then
          ftpairs = concat(ftpairs, toList(v.matchpairs))
          ignores = concat(ignores, toList(v.ignores or  ""))
        else
          ftpairs = concat(ftpairs, toList(v))
        end
      end
    end
  end
  ftpairs = concat(ftpairs, toList(vim.g.hlpairs.filetype['*']))
  ftpairs = concat(ftpairs, csv(vim.o.matchpairs))
  local ignores = ',' .. table.concat(ignores, ',') .. ','
  local pairs_ = {}
  for k, sme in pairs(ftpairs) do
    if string.find(ignores, ',' .. sme .. ',') then
      goto continue
    end
    local ary = csv(sme, ':')
    local s_full = ary[1]
    local i = string.find(s_full, [[\%%%(]])
    local s = i and string.sub(s_full, 1, i - 1) or s_full
    local m = #ary == 3 and ary[2] or ""
    local e = ary[#ary]
    table.insert(pairs_, {
      s_full = s_full;
      s = s == '[' and "\\[" or s;
      m = m;
      e = e;
      has_matchstr = string.find(e, "\\[1-9]") or string.find(m, "\\[1-9]");
      has_m =  m ~= "";
    })
    ::continue::
  end
  local start_regexs = {}
  for i, p in pairs(pairs_) do
    table.insert(start_regexs, p.s)
  end
  -- set the new settings
  b_hlpairs = {
    pairs_ = pairs_;
    pairs_cache = {};
    pairs_cache_keys = {};
    start_regex = table.concat(start_regexs, [[\|]]);
  }
  local g_skip = vim.g.hlpairs.skip
  if type(g_skip) == 'table' then
    b_hlpairs.skip = g_skip[ft] or g_skip['*'] or ""
  else
    b_hlpairs.skip = g_skip
  end
  vim.b.hlpairs = b_hlpairs
end

local function toPosItem(s)
  return { s.lnum, s.byteidx + 1, vim.fn.len(s.text) }
end

local function replaceMatchGroup(s, g)
  return string.gsub(s, "\\[1-9]", function (m)
    local i = tonumber(string.sub(m, 2))
    return string.gsub(g[i], [[\]], [[\\]])
  end)
end

local function isSkip(s)
  local cur = curpos()
  setpos({ s.lnum, s.byteidx })
  local result = vim.fn.eval(vim.b.hlpairs.skip)
  setpos(cur)
  return result
end

local function findEnd(buf, max_lnum, s, pair, has_skip)
  -- setup properties
  local byteidx = s.byteidx + vim.fn.len(s.text)
  local s_regex = pair.s
  local e_regex = pair.e
  local m_regex = pair.m
  local has_m = pair.has_m
  if pair.has_matchstr then
    s_regex = string.gsub(s.text, "[\\*.]", "\\%0")
    e_regex = replaceMatchGroup(pair.e, s.submatches)
    if has_m then
      m_regex = replaceMatchGroup(pair.m, s.submatches)
    end
  end
  s_regex_c = vim.regex(s_regex)
  e_regex_c = vim.regex(e_regex)
  m_regex_c = vim.regex(m_regex)
  -- find the end
  local pos_list = {toPosItem(s)}
  local nest = 0
  local offset = s.lnum
  while offset <= max_lnum do
    local matches = vim.fn.matchbufline(
      buf,
      s_regex .. "\\|" .. e_regex .. (has_m and ("\\|" .. m_regex) or ""),
      offset,
      offset + SEARCH_LINE_COUNT - 1
    )
    offset = offset + SEARCH_LINE_COUNT
    for i, ma in pairs(matches) do
      if ma.lnum == s.lnum and ma.byteidx < byteidx then
        goto continue
      end
      if has_skip and isSkip(ma) then
        goto continue
      end
      if e_regex_c:match_str(ma.text) then
        if nest == 0 then
          table.insert(pos_list, toPosItem(ma))
          return pos_list
        else
          nest = nest - 1
          goto continue
        end
      end
      if s_regex_c:match_str(ma.text) then
        nest = nest + 1
        goto continue
      end
      if 0 < nest then
        goto continue
      end
      if has_m and m_regex_c:match_str(ma.text) then
        table.insert(pos_list, toPosItem(ma))
      end
      ::continue::
    end
  end
  return nil
end

local function findPairs(cur)
  -- setup properties
  local buf = vim.fn.bufnr()
  local b_hlpairs = vim.b.hlpairs
  local cur_lnum = cur[1]
  local cur_byteidx = cur[2] - 1
  local min_lnum = math.max(1, cur_lnum - vim.g.hlpairs.limit)
  local max_lnum = cur_lnum + vim.g.hlpairs.limit
  local has_skip = b_hlpairs.skip and b_hlpairs.skip ~= ''
  local offset = cur_lnum
  while min_lnum <= offset do
    -- find the start
    local starts = vim.fn.matchbufline(
      buf,
      b_hlpairs.start_regex,
      math.max(1, offset - SEARCH_LINE_COUNT + 1),
      offset,
      { submatches = true }
    )
    offset = offset - SEARCH_LINE_COUNT
    -- find the end
    for i = #starts, 1, -1 do
      local s = starts[i]
      if cur_lnum == s.lnum and cur_byteidx < s.byteidx then
        goto continue
      end
      if has_skip and isSkip(s) then
        goto continue
      end
      local pair = getPairParams(s.text)
      if not(pair) then
        break
      end
      local pos_list = findEnd(buf, max_lnum, s, pair, has_skip)
      if not(pos_list) then
        goto continue
      end
      local e = pos_list[#pos_list]
      if cur[1] < e[1] or cur[1] == e[1] and cur[2] < e[2] + e[3] then
        if pair.s_full ~= pair.s then
          local p = pos_list[1]
          local t = string.sub(getline(buf, p[1]), p[2] - 1)
          local m = vim.fn.matchstr(t, pair.s_full)
          if m then
            pos_list[1][3] = #m
          end
        end
        return pos_list
      end
      ::continue::
    end
  end
  return {}
end

local function highlightPair()
  timer = nil
  if not(vim.b.hlpairs) then
    onOptionSet()
  end
  local b = vim.api.nvim_get_current_buf()
  if not(vim.w.hlpairs) then
    vim.w.hlpairs = {
      bufnr = b;
      matchid = 0;
      pos = {};
      pairs_ = {};
      mark = {};
    }
  end
  local w_hlpairs = vim.w.hlpairs
  local cur = curpos()
  if 0 < prevent_remark then
    prevent_remark = prevent_remark - 1
  else
    w_hlpairs.mark = { cur[1], cur[2] }
  end
  local new_pos = findPairs(cur)
  if w_hlpairs.pos == new_pos and w_hlpairs.bufnr == b then
    -- nothing update
    return
  end
  w_hlpairs.bufnr = b
  w_hlpairs.pos = new_pos
  if 0 < w_hlpairs.matchid then
    vim.fn.matchdelete(w_hlpairs.matchid)
    w_hlpairs.matchid = 0
  end
  if #new_pos then
    w_hlpairs.matchid = vim.fn.matchaddpos('MatchParen', new_pos)
  end
  vim.w.hlpairs = w_hlpairs
end

local timer = nil
local function onCursorMoved()
  if timer then
    vim.fn.timer_stop(timer)
  end
  timer = vim.fn.timer_start(vim.g.hlpairs.delay, highlightPair)
end

local function merge(a, b)
  if b == nil then
    return a
  end
  for k, v in pairs(b) do
    if type(v) == 'table' then
      a[k] = merge(a[k], v)
    elseif type(k) == 'number' then
      table.insert(a, v)
    else
      a[k] = v
    end
  end
  return a
end

local function getPosList()
  if vim.w.hlpairs ~= nil and is_ne(vim.w.hlpairs.pos) then
    return vim.w.hlpairs.pos
  else
    highlightPair()
    return vim.w.hlpairs.pos
  end
end

-- interfaces
local function jump(flags)
  local f = flags or ''
  local pos_list = getPosList()
  if not(pos_list) or #pos_list == 0 then
    return false
  end
  local p = nil
  local cur = curpos()
  if string.find(f, 'b') then
    for i = #pos_list, 1, -1 do
      local j = pos_list[i]
      if cur[1] > j[1] or cur[1] == j[1] and cur[2] > j[2] then
        p = j
        break
      end
    end
  else
    for i, j in pairs(pos_list) do
      if cur[1] < j[1] or cur[1] == j[1] and cur[2] < j[2] then
        p = j
        break
      end
    end
  end
  if is_empty(p) then
    if f == '' then
      p = pos_list[1]
    else
      return false
    end
  end
  local offset = string.find(f, 'e') and p[3] - 1 or 0 
  prevent_remark = 1
  setpos({ p[1], p[2] + offset })
  return true
end

local function jumpBack()
  jump('b')
end

local function jumpForward()
  jump('fe')
end

local function returnCursor()
  if vim.w.hlpairs and is_ne(vim.w.hlpairs.mark) then
    setpos(vim.w.hlpairs.mark)
  end
end

local function highlightOuter()
  local p = getPosList()
  if is_empty(p) then
    return
  end
  local cur = curpos()
  prevent_remark = 1
  setpos({ p[1][1], p[1][2] - 1 })
  highlightPair()
  setpos(cur)
end

local function textObj(a)
  local p = getPosList()
  if is_empty(p) then
    return
  end
  local sy, sx, sl = unpack(p[1])
  local ey, ex, el = unpack(p[#p])
  if a then
    ex = ex + el - 1
  else
    sx = sx + sl
    ex = ex - 1
    if ex == 0 then
      ey = ey - 1
      ex = len(getline(0, ey))
    end
  end
  local m = vim.api.nvim_get_mode().mode
  if string.match(m, '^[vV]$') then
    vim.cmd('normal! ' .. m)
  else
    m = 'v'
  end
  setpos({ sy, sx })
  vim.cmd('normal! ' .. m)
  setpos({ ey, ex })
end

local function textObjA()
  textObj(true)
end

local function textObjI()
  textObj(false)
end

local function map(mode, prefix, name, callback)
  local p = '<Plug>(hlpairs-' .. name .. ')'
	vim.api.nvim_set_keymap(mode, p, '', { callback = callback, noremap = true })
  if is_ne(vim.g.hlpairs.key) then
    vim.api.nvim_set_keymap(mode, prefix .. vim.g.hlpairs.key, p, {})
  end
end

-- setup
local function setup(terminal, executors)
  -- settings
  local g_hlpairs = {
    key = '%';
    delay = 150;
    limit = 50;
    filetype = {
      vim = [[\<if\>:else\(if\)\?:end,\<for\>:\<endfor\>,while:endwhile,function:endfunction,\<function\>:end,\<try\>:\<\(catch\|finally\)\>:\<endtry\>,augroup .*:augroup END]];
      ruby = [[\<if\>:else\(if\)\?:\<end\>,\<\(function\|do\|class\|if\)\>:\<end\>]];
      lua = [[\<if\>:else\(if\)\?:\<end\>,\<\(function\|do\|if\)\>:\<end\>,\[\[:\]\]] .. ']';
    };
    skip = {
      ruby = [[getline(".") =~ "\\S\\s*if\\s"]];
    };
  }
  g_hlpairs.filetype['html,xml'] = {
    matchpairs = {
      [[\<[a-zA-Z0-9_\:-]\+=":"]],
      [[<\([a-zA-Z0-9\:]\+\)\%([^>]*\)>:</\1>]],
      [[<!-- =-->]]
    };
    ignores = '<:>';
  }
  g_hlpairs.filetype['*'] = [[\w\@<!\w*(:)]]
  g_hlpairs = merge(g_hlpairs, vim.g.hlpairs)
  vim.g.hlpairs = g_hlpairs
  -- autocmd
  vim.api.nvim_create_augroup('hlpairs', { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = 'hlpairs';
    callback = onCursorMoved;
  })
  vim.api.nvim_create_autocmd({ 'OptionSet', 'FileType' }, {
    group = 'hlpairs';
    pattern = {'matchpairs', '*'};
    callback = function()
      vim.b.hlpairs = nil
    end;
  })
  -- mapping
  map('n', '', 'jump', jump)
  map('n', '[', 'back' , jumpBack)
  map('n', ']', 'forward', jumpForward)
  map('n', '<Leader>', 'outer', highlightOuter)
  map('n', '<Space>' , 'return', returnCursor)
  map('o', 'a', 'textobj-a', textObjA)
  map('o', 'i', 'textobj-i', textObjI)
  map('v', 'a', 'textobj-a', textObjA)
  map('v', 'i', 'textobj-i', textObjI)
end

return {
	setup = setup;
  jump = jump;
  jumpBack = jumpBack;
  jumpForward = jumpForward;
  returnCursor = returnCursor;
  highlightOuter = highlightOuter;
  textObjUserMap = textObjUserMap;
  textObj = textObj;
}

