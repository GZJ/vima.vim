let s:save_cpo = &cpoptions
set cpoptions&vim

let s:sessions = {}

function! s:notify(message, ...) abort
  execute 'echohl ' .. (get(a:000, 0, v:false) ? 'ErrorMsg' : 'WarningMsg')
  echomsg 'vima: ' .. a:message
  echohl None
endfunction

function! s:clear(bufnr) abort
  if !bufexists(a:bufnr) | return | endif
  call prop_remove({'types': ['VimaDelete', 'VimaAdd'], 'bufnr': a:bufnr, 'all': v:true})
  silent! execute 'sign unplace * group=Vima buffer=' .. a:bufnr
endfunction

function! s:expand_tabs(text, bufnr, start_width) abort
  let parts = []
  let width = a:start_width
  let tabstop = getbufvar(a:bufnr, '&tabstop')
  for char in split(a:text, '\zs')
    if char ==# "\t"
      let spaces_needed = tabstop - (width % tabstop)
      call add(parts, repeat(' ', spaces_needed))
      let width += spaces_needed
    else
      call add(parts, char)
      let width += strdisplaywidth(char)
    endif
  endfor
  return join(parts, '')
endfunction

function! s:lines_size(lines) abort
  let size = max([0, len(a:lines) - 1])
  for text in a:lines | let size += strlen(text) | endfor
  return size
endfunction

function! s:limit_error(lines) abort
  if g:vima_max_lines > 0 && len(a:lines) > g:vima_max_lines
    return printf('buffer has %d lines; limit is %d', len(a:lines), g:vima_max_lines)
  endif
  let size = s:lines_size(a:lines)
  if g:vima_max_file_size > 0 && size > g:vima_max_file_size
    return printf('buffer is %d bytes; limit is %d', size, g:vima_max_file_size)
  endif
  return ''
endfunction

function! s:buffer_hash(lines) abort
  return sha256(string(len(a:lines)) .. "\n" .. join(a:lines, "\n"))
endfunction

function! s:finish_change(change, changes) abort
  if empty(a:change) || (empty(a:change.removed) && empty(a:change.added)) | return | endif
  let identity = a:change.old_start .. "\n" .. join(a:change.removed, "\n") .. "\n--vima--\n" .. join(a:change.added, "\n")
  let a:change.key = sha256(identity)
  call add(a:changes, a:change)
endfunction

function! s:parse(lines) abort
  let changes = []
  let change = {}
  let old_cursor = -1
  let new_cursor = -1

  for text in a:lines
    let match = matchlist(text, '^@@ -\(\d\+\)\%(,\d*\)\? +\(\d\+\)\%(,\d*\)\? @@')
    if !empty(match)
      call s:finish_change(change, changes)
      let change = {}
      let old_cursor = str2nr(match[1])
      let new_cursor = str2nr(match[2])
    elseif old_cursor >= 0
      let marker = strpart(text, 0, 1)
      if marker ==# ' '
        call s:finish_change(change, changes)
        let change = {}
        let old_cursor += 1
        let new_cursor += 1
      elseif marker ==# '-'
        if empty(change)
          let change = {'old_start': old_cursor, 'new_start': new_cursor, 'removed': [], 'added': []}
        endif
        call add(change.removed, strpart(text, 1))
        let old_cursor += 1
      elseif marker ==# '+'
        if empty(change)
          let change = {'old_start': old_cursor, 'new_start': new_cursor, 'removed': [], 'added': []}
        endif
        call add(change.added, strpart(text, 1))
        let new_cursor += 1
      endif
    endif
  endfor
  call s:finish_change(change, changes)
  return changes
endfunction

function! s:systemlist(args) abort
  return systemlist(join(map(copy(a:args), {_, value -> shellescape(value)}), ' '))
endfunction

function! s:external_diff(baseline, current) abort
  if !executable(g:vima_git)
    return {'changes': [], 'error': 'Vim diff() is unavailable and Git was not found'}
  endif
  let baseline_path = tempname()
  let current_path = tempname()
  let status = -1
  let output = []
  try
    call writefile(a:baseline, baseline_path, 'b')
    call writefile(a:current, current_path, 'b')
    let output = s:systemlist([g:vima_git, 'diff', '--no-index', '--no-ext-diff', '--no-color', '--unified=3', '--', baseline_path, current_path])
    let status = v:shell_error
  finally
    call delete(baseline_path)
    call delete(current_path)
  endtry
  if status != 0 && status != 1
    return {'changes': [], 'error': 'Git diff failed'}
  endif
  return {'changes': s:parse(output), 'error': ''}
endfunction

function! s:buffer_diff(baseline, current) abort
  let use_internal = exists('*diff')
        \ && (g:vima_internal_diff_max_lines <= 0 || len(a:current) <= g:vima_internal_diff_max_lines)
        \ && (g:vima_internal_diff_max_file_size <= 0 || s:lines_size(a:current) <= g:vima_internal_diff_max_file_size)
  if use_internal
    try
      let output = diff(a:baseline, a:current, {'output': 'unified', 'context': 3})
      return {'changes': s:parse(split(output, "\n", v:true)), 'error': ''}
    catch
      return s:external_diff(a:baseline, a:current)
    endtry
  endif
  return s:external_diff(a:baseline, a:current)
endfunction

function! s:pending(bufnr, current) abort
  let session = s:sessions[a:bufnr]
  let result = s:buffer_diff(session.baseline, a:current)
  if result.error !=# '' | return result | endif
  if g:vima_max_changes > 0 && len(result.changes) > g:vima_max_changes
    return {'changes': [], 'error': printf('diff has %d changes; limit is %d', len(result.changes), g:vima_max_changes)}
  endif
  let pending = []
  for change in result.changes
    if !has_key(session.accepted, change.key) | call add(pending, change) | endif
  endfor
  let session.changes = pending
  return {'changes': pending, 'error': ''}
endfunction

function! s:render(bufnr, changes) abort
  call s:clear(a:bufnr)
  let info = getbufinfo(a:bufnr)
  if empty(info) | return | endif
  let last_line = info[0].linecount
  let sign_id = 1

  " Place real-line decorations first so an automatic sign column is included
  " in the window text offset used by virtual deleted lines.
  for change in a:changes
    if !empty(change.added)
      for lnum in range(change.new_start, change.new_start + len(change.added) - 1)
        if lnum < 1 || lnum > last_line | continue | endif
        call prop_add(lnum, 1, {'bufnr': a:bufnr, 'type': 'VimaAdd', 'length': strlen(getbufline(a:bufnr, lnum)[0])})
        if g:vima_show_signs
          execute printf('sign place %d line=%d name=VimaAdd group=Vima buffer=%d', sign_id, lnum, a:bufnr)
          let sign_id += 1
        endif
      endfor
    endif
  endfor

  let prefix_width = strdisplaywidth(g:vima_delete_prefix)

  for change in a:changes
    if empty(change.removed) | continue | endif
    " Prefer attaching deleted text below the preceding context line. This
    " keeps signs attached to real added lines instead of letting Vim display
    " an added-line sign on the first virtual deletion above that line.
    if change.new_start > 1
      let anchor = min([change.new_start - 1, last_line]) | let align = 'below'
    elseif change.new_start >= 1
      let anchor = 1 | let align = 'above'
    else
      let anchor = 1 | let align = 'above'
    endif
    " Above-line text properties are displayed in insertion order.
    for deleted_line in change.removed
      call prop_add(anchor, 0, {
            \ 'bufnr': a:bufnr,
            \ 'type': 'VimaDelete',
            \ 'text': g:vima_delete_prefix .. s:expand_tabs(deleted_line, a:bufnr, prefix_width),
            \ 'text_align': align,
            \ 'text_wrap': 'truncate',
            \ })
    endfor
  endfor
endfunction

function! vima#refresh(bufnr) abort
  if !bufexists(a:bufnr) || !has_key(s:sessions, a:bufnr) | return | endif
  let session = s:sessions[a:bufnr]
  let current = getbufline(a:bufnr, 1, '$')
  let error = s:limit_error(current)
  if error !=# ''
    call s:clear(a:bufnr)
    let session.changes = []
    if get(session, 'last_error', '') !=# error
      call s:notify(error .. '; rendering is suspended')
      let session.last_error = error
    endif
    return
  endif
  let result = s:pending(a:bufnr, current)
  if result.error !=# ''
    call s:clear(a:bufnr)
    let session.changes = []
    if get(session, 'last_error', '') !=# result.error
      call s:notify(result.error)
      let session.last_error = result.error
    endif
    return
  endif
  let session.last_error = ''
  call s:render(a:bufnr, result.changes)
endfunction

function! s:current_change(bufnr) abort
  if !has_key(s:sessions, a:bufnr) || empty(s:sessions[a:bufnr].changes) | return {} | endif
  let cursor = line('.')
  for change in s:sessions[a:bufnr].changes
    if !empty(change.added)
      let first = max([1, change.new_start])
      let final = first + len(change.added) - 1
      if cursor >= first && cursor <= final | return change | endif
    else
      let anchor = max([1, min([change.new_start, line('$')])])
      if cursor == anchor | return change | endif
    endif
  endfor
  return {}
endfunction

function! s:set_buffer(bufnr, lines) abort
  let replacement = empty(a:lines) ? [''] : copy(a:lines)
  let old_length = len(getbufline(a:bufnr, 1, '$'))
  call setbufline(a:bufnr, 1, replacement)
  if old_length > len(replacement) | call deletebufline(a:bufnr, len(replacement) + 1, old_length) | endif
endfunction

function! s:replace_change(bufnr, change) abort
  let lines = getbufline(a:bufnr, 1, '$')
  let index = max([0, a:change.new_start - 1])
  if !empty(a:change.added)
    call remove(lines, index, index + len(a:change.added) - 1)
  endif
  call extend(lines, copy(a:change.removed), index)
  call s:set_buffer(a:bufnr, lines)
endfunction

function! s:restore_change(bufnr, change) abort
  let lines = getbufline(a:bufnr, 1, '$')
  let index = max([0, a:change.new_start - 1])
  if !empty(a:change.removed)
    call remove(lines, index, index + len(a:change.removed) - 1)
  endif
  call extend(lines, copy(a:change.added), index)
  call s:set_buffer(a:bufnr, lines)
endfunction

function! s:push_action(session, action) abort
  call add(a:session.history, a:action)
  let a:session.redo = []
  while g:vima_history_limit >= 0 && len(a:session.history) > g:vima_history_limit
    call remove(a:session.history, 0)
  endwhile
endfunction

function! s:set_accepted(session, keys, value) abort
  for key in a:keys
    if a:value
      let a:session.accepted[key] = v:true
    elseif has_key(a:session.accepted, key)
      call remove(a:session.accepted, key)
    endif
  endfor
endfunction

function! vima#allow(bufnr) abort
  let change = s:current_change(a:bufnr)
  if empty(change) | call s:notify('no pending change') | return | endif
  let session = s:sessions[a:bufnr]
  let hash = s:buffer_hash(getbufline(a:bufnr, 1, '$'))
  let session.accepted[change.key] = v:true
  call s:push_action(session, {'kind': 'allow', 'keys': [change.key], 'before_hash': hash, 'after_hash': hash})
  call vima#refresh(a:bufnr)
endfunction

function! vima#reject(bufnr) abort
  let change = s:current_change(a:bufnr)
  if empty(change) | call s:notify('no pending change') | return | endif
  let session = s:sessions[a:bufnr]
  let before_hash = s:buffer_hash(getbufline(a:bufnr, 1, '$'))
  let changes = [deepcopy(change)]
  call s:replace_change(a:bufnr, change)
  call s:push_action(session, {
        \ 'kind': 'reject',
        \ 'changes': changes,
        \ 'before_hash': before_hash,
        \ 'after_hash': s:buffer_hash(getbufline(a:bufnr, 1, '$')),
        \ })
  call vima#refresh(a:bufnr)
endfunction

function! vima#allow_all(bufnr) abort
  if !has_key(s:sessions, a:bufnr) | return | endif
  let session = s:sessions[a:bufnr]
  let keys = []
  for change in session.changes
    let session.accepted[change.key] = v:true
    call add(keys, change.key)
  endfor
  if !empty(keys)
    let hash = s:buffer_hash(getbufline(a:bufnr, 1, '$'))
    call s:push_action(session, {'kind': 'allow', 'keys': keys, 'before_hash': hash, 'after_hash': hash})
  endif
  call vima#refresh(a:bufnr)
endfunction

function! vima#reject_all(bufnr) abort
  if !has_key(s:sessions, a:bufnr) | return | endif
  let session = s:sessions[a:bufnr]
  if empty(session.changes) | return | endif
  let changes = deepcopy(session.changes)
  let before_hash = s:buffer_hash(getbufline(a:bufnr, 1, '$'))
  for change in reverse(copy(changes)) | call s:replace_change(a:bufnr, change) | endfor
  call s:push_action(session, {
        \ 'kind': 'reject',
        \ 'changes': changes,
        \ 'before_hash': before_hash,
        \ 'after_hash': s:buffer_hash(getbufline(a:bufnr, 1, '$')),
        \ })
  call vima#refresh(a:bufnr)
endfunction

function! vima#undo(bufnr) abort
  let session = get(s:sessions, a:bufnr, {})
  let action = !empty(session) && !empty(session.history) ? session.history[-1] : {}
  let current_hash = s:buffer_hash(getbufline(a:bufnr, 1, '$'))
  if !empty(action) && current_hash ==# action.after_hash
    if action.kind ==# 'allow'
      call s:set_accepted(session, action.keys, v:false)
    else
      for change in action.changes | call s:restore_change(a:bufnr, change) | endfor
    endif
    call remove(session.history, -1)
    call add(session.redo, action)
  else
    silent! undo
  endif
  call vima#refresh(a:bufnr)
endfunction

function! vima#redo(bufnr) abort
  let session = get(s:sessions, a:bufnr, {})
  let action = !empty(session) && !empty(session.redo) ? session.redo[-1] : {}
  let current_hash = s:buffer_hash(getbufline(a:bufnr, 1, '$'))
  if !empty(action) && current_hash ==# action.before_hash
    if action.kind ==# 'allow'
      call s:set_accepted(session, action.keys, v:true)
    else
      for change in reverse(copy(action.changes)) | call s:replace_change(a:bufnr, change) | endfor
    endif
    call remove(session.redo, -1)
    call add(session.history, action)
  else
    silent! redo
  endif
  call vima#refresh(a:bufnr)
endfunction

function! s:valid_lhs(lhs) abort
  return type(a:lhs) == v:t_string && a:lhs !=# '' && a:lhs !~# '[[:space:]|]'
endfunction

function! s:install_mappings(bufnr, session) abort
  if bufnr() != a:bufnr | return | endif
  let specs = [
        \ ['allow', '<Plug>(VimaAllow)'],
        \ ['reject', '<Plug>(VimaReject)'],
        \ ['undo', '<Plug>(VimaUndo)'],
        \ ['redo', '<Plug>(VimaRedo)'],
        \ ]
  for spec in specs
    let lhs = get(g:vima_mappings, spec[0], '')
    if !s:valid_lhs(lhs) || has_key(a:session.installed_maps, lhs) | continue | endif
    let current = maparg(lhs, 'n', v:false, v:true)
    let a:session.saved_maps[lhs] = !empty(current) && get(current, 'buffer', 0) ? current : {}
    execute 'nmap <silent><buffer> ' .. lhs .. ' ' .. spec[1]
    let a:session.installed_maps[lhs] = spec[1]
  endfor
endfunction

function! s:restore_mappings(bufnr, session) abort
  if bufnr() != a:bufnr | return | endif
  for [lhs, plug] in items(get(a:session, 'installed_maps', {}))
    let current = maparg(lhs, 'n', v:false, v:true)
    if !empty(current) && get(current, 'buffer', 0) && get(current, 'rhs', '') ==# plug
      silent! execute 'nunmap <buffer> ' .. lhs
      let saved = get(a:session.saved_maps, lhs, {})
      if !empty(saved) | call mapset('n', v:false, saved) | endif
    endif
  endfor
  let a:session.installed_maps = {}
  let a:session.saved_maps = {}
endfunction

function! vima#settle(bufnr) abort
  if bufnr() != a:bufnr || !has_key(s:sessions, a:bufnr) | return | endif
  let session = s:sessions[a:bufnr]
  let winid = win_getid()
  if !has_key(session.windows, string(winid))
    let session.windows[string(winid)] = &l:wrap
  endif
  setlocal nowrap
endfunction

function! s:restore_windows(bufnr, session) abort
  for [winid_text, saved_wrap] in items(get(a:session, 'windows', {}))
    let winid = str2nr(winid_text)
    let info = getwininfo(winid)
    if !empty(info) && info[0].bufnr == a:bufnr
      " Do not overwrite an explicit user change made while Vima was active.
      call win_execute(winid, 'if !&l:wrap | let &l:wrap = ' .. string(saved_wrap) .. ' | endif')
    endif
  endfor
  let a:session.windows = {}
endfunction

function! s:prepare_buffer(bufnr) abort
  if !bufloaded(a:bufnr) || bufname(a:bufnr) ==# ''
    return {'lines': [], 'error': 'a named, loaded file buffer is required'}
  endif
  if getbufvar(a:bufnr, '&buftype') !=# '' || !getbufvar(a:bufnr, '&modifiable') || getbufvar(a:bufnr, '&binary')
    return {'lines': [], 'error': 'a modifiable text buffer is required'}
  endif
  let lines = getbufline(a:bufnr, 1, '$')
  let error = s:limit_error(lines)
  if error !=# ''
    return {'lines': [], 'error': error .. '; Vima was not enabled'}
  endif
  return {'lines': lines, 'error': ''}
endfunction

function! s:git_baseline(bufnr) abort
  if !executable(g:vima_git)
    return {'lines': [], 'error': 'cannot read Git baseline: Git was not found'}
  endif
  let file = fnamemodify(bufname(a:bufnr), ':p')
  let lines = s:systemlist([g:vima_git, '-C', fnamemodify(file, ':h'), 'show', ':./' .. fnamemodify(file, ':t')])
  if v:shell_error != 0
    return {'lines': [], 'error': 'cannot read Git index baseline; the file must be tracked at stage 0'}
  endif
  if empty(lines) | let lines = [''] | endif
  let error = s:limit_error(lines)
  if error !=# ''
    return {'lines': [], 'error': 'Git baseline ' .. error .. '; Vima was not enabled'}
  endif
  return {'lines': lines, 'error': ''}
endfunction

function! s:begin_review(bufnr, baseline, mode) abort
  let session = get(s:sessions, a:bufnr, {})
  if empty(session)
    let session = {'timer': -1, 'saved_maps': {}, 'installed_maps': {}, 'windows': {}}
    let s:sessions[a:bufnr] = session
    call s:install_mappings(a:bufnr, session)
  elseif session.timer != -1
    call timer_stop(session.timer)
    let session.timer = -1
  endif
  let session.baseline = a:baseline
  let session.baseline_mode = a:mode
  let session.accepted = {}
  let session.changes = []
  let session.history = []
  let session.redo = []
  let session.last_error = ''
  call setbufvar(a:bufnr, 'vima_attached', v:true)
  call vima#settle(a:bufnr)
  call vima#refresh(a:bufnr)
  return v:true
endfunction

function! vima#enable(bufnr) abort
  let current = s:prepare_buffer(a:bufnr)
  if current.error !=# '' | call s:notify(current.error) | return v:false | endif
  let baseline = s:git_baseline(a:bufnr)
  if baseline.error !=# '' | call s:notify(baseline.error) | return v:false | endif
  return s:begin_review(a:bufnr, baseline.lines, 'git')
endfunction

function! vima#start(bufnr) abort
  let baseline = s:prepare_buffer(a:bufnr)
  if baseline.error !=# '' | call s:notify(baseline.error) | return v:false | endif
  return s:begin_review(a:bufnr, baseline.lines, 'buffer')
endfunction

function! vima#disable(bufnr) abort
  if !has_key(s:sessions, a:bufnr) | return | endif
  let session = s:sessions[a:bufnr]
  if session.timer != -1 | call timer_stop(session.timer) | let session.timer = -1 | endif
  call s:restore_mappings(a:bufnr, session)
  call s:restore_windows(a:bufnr, session)
  call remove(s:sessions, a:bufnr)
  call setbufvar(a:bufnr, 'vima_attached', v:false)
  call s:clear(a:bufnr)
endfunction

function! s:timer_refresh(bufnr, timer) abort
  if has_key(s:sessions, a:bufnr)
    let s:sessions[a:bufnr].timer = -1
    call vima#refresh(a:bufnr)
  endif
endfunction

function! vima#schedule(bufnr) abort
  if !has_key(s:sessions, a:bufnr) | return | endif
  if s:sessions[a:bufnr].timer != -1 | call timer_stop(s:sessions[a:bufnr].timer) | endif
  let s:sessions[a:bufnr].timer = timer_start(max([0, g:vima_debounce]), function('s:timer_refresh', [a:bufnr]))
endfunction

function! vima#reload(bufnr) abort
  if !has_key(s:sessions, a:bufnr) | return vima#enable(a:bufnr) | endif
  let session = s:sessions[a:bufnr]
  let session.accepted = {}
  let session.changes = []
  let session.history = []
  let session.redo = []
  let session.last_error = ''
  if session.timer != -1 | call timer_stop(session.timer) | let session.timer = -1 | endif
  call vima#refresh(a:bufnr)
endfunction

function! vima#reset(bufnr) abort
  if !has_key(s:sessions, a:bufnr) | return vima#start(a:bufnr) | endif
  let baseline = getbufline(a:bufnr, 1, '$')
  let error = s:limit_error(baseline)
  if error !=# '' | call s:notify(error .. '; baseline was not reset') | return | endif
  let session = s:sessions[a:bufnr]
  let session.baseline = baseline
  let session.accepted = {}
  let session.changes = []
  let session.history = []
  let session.redo = []
  let session.last_error = ''
  if session.timer != -1 | call timer_stop(session.timer) | let session.timer = -1 | endif
  call vima#refresh(a:bufnr)
endfunction

function! vima#on_read(bufnr) abort
  if has_key(s:sessions, a:bufnr)
    call vima#reload(a:bufnr)
  elseif g:vima_enabled
    call vima#enable(a:bufnr)
  endif
endfunction

function! vima#cleanup(bufnr) abort
  if !has_key(s:sessions, a:bufnr) | return | endif
  let session = s:sessions[a:bufnr]
  if session.timer != -1 | call timer_stop(session.timer) | endif
  call remove(s:sessions, a:bufnr)
endfunction

function! vima#toggle(bufnr) abort
  if has_key(s:sessions, a:bufnr) | call vima#disable(a:bufnr) | else | call vima#enable(a:bufnr) | endif
endfunction

function! vima#enable_all() abort
  let g:vima_enabled = v:true
  for info in getbufinfo({'bufloaded': v:true})
    if info.listed && !has_key(s:sessions, info.bufnr)
      call vima#enable(info.bufnr)
    endif
  endfor
endfunction

function! vima#disable_all() abort
  let g:vima_enabled = v:false
  for bufnr in keys(copy(s:sessions))
    call vima#disable(str2nr(bufnr))
  endfor
endfunction

function! vima#toggle_all() abort
  if g:vima_enabled | call vima#disable_all() | else | call vima#enable_all() | endif
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
