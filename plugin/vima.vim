if exists('g:loaded_vima')
  finish
endif
let g:loaded_vima = 1

let s:save_cpo = &cpoptions
set cpoptions&vim

if !has('textprop') || !has('patch-9.0.0438')
  let &cpoptions = s:save_cpo
  unlet s:save_cpo
  echoerr 'vima requires Vim 9.0.0438 or newer with +textprop'
  finish
endif

if !exists('g:vima_enabled') | let g:vima_enabled = v:false | endif
if !exists('g:vima_show_signs') | let g:vima_show_signs = v:true | endif
if !exists('g:vima_delete_prefix') | let g:vima_delete_prefix = '' | endif
if !exists('g:vima_debounce') | let g:vima_debounce = 150 | endif
if !exists('g:vima_max_file_size') | let g:vima_max_file_size = 2 * 1024 * 1024 | endif
if !exists('g:vima_max_lines') | let g:vima_max_lines = 50000 | endif
if !exists('g:vima_max_changes') | let g:vima_max_changes = 2000 | endif
if !exists('g:vima_history_limit') | let g:vima_history_limit = 50 | endif
if !exists('g:vima_git') | let g:vima_git = 'git' | endif
if !exists('g:vima_internal_diff_max_file_size') | let g:vima_internal_diff_max_file_size = 512 * 1024 | endif
if !exists('g:vima_internal_diff_max_lines') | let g:vima_internal_diff_max_lines = 5000 | endif
if !exists('g:vima_mappings')
  let g:vima_mappings = {'allow': 'a', 'reject': 'r', 'undo': 'u', 'redo': '<C-r>', 'previous': '[c', 'next': ']c'}
endif
if !has_key(g:vima_mappings, 'previous') | let g:vima_mappings.previous = '[c' | endif
if !has_key(g:vima_mappings, 'next') | let g:vima_mappings.next = ']c' | endif

function! s:apply_highlights() abort
  highlight default VimaDelete guifg=#ff0000 guibg=NONE ctermfg=Red ctermbg=NONE
  highlight default VimaDeletePrefix guifg=#ff0000 guibg=NONE ctermfg=Red ctermbg=NONE
  highlight default VimaAdd guifg=#00ff00 guibg=NONE ctermfg=Green ctermbg=NONE
  highlight default VimaAddSign guifg=#00ff00 guibg=NONE ctermfg=Green ctermbg=NONE
  highlight default link VimaHint WarningMsg
endfunction
call s:apply_highlights()

sign define VimaAdd text=+ texthl=VimaAddSign
if empty(prop_type_get('VimaDelete'))
  call prop_type_add('VimaDelete', {'highlight': 'VimaDelete'})
endif
if empty(prop_type_get('VimaAdd'))
  call prop_type_add('VimaAdd', {'highlight': 'VimaAdd', 'combine': v:false})
endif

nnoremap <silent> <Plug>(VimaAllow) :<C-U>VimaAllow<CR>
nnoremap <silent> <Plug>(VimaReject) :<C-U>VimaReject<CR>
nnoremap <silent> <Plug>(VimaUndo) :<C-U>VimaUndo<CR>
nnoremap <silent> <Plug>(VimaRedo) :<C-U>VimaRedo<CR>
nnoremap <silent> <Plug>(VimaPrevious) :<C-U>VimaPrevious<CR>
nnoremap <silent> <Plug>(VimaNext) :<C-U>VimaNext<CR>

command! VimaEnable call vima#enable(bufnr())
command! VimaStart call vima#start(bufnr())
command! VimaDisable call vima#disable(bufnr())
command! VimaToggle call vima#toggle(bufnr())
command! VimaEnableAll call vima#enable_all()
command! VimaDisableAll call vima#disable_all()
command! VimaToggleAll call vima#toggle_all()
command! VimaRefresh call vima#refresh(bufnr())
command! VimaReset call vima#reset(bufnr())
command! VimaAllow call vima#allow(bufnr())
command! VimaReject call vima#reject(bufnr())
command! VimaAllowAll call vima#allow_all(bufnr())
command! VimaRejectAll call vima#reject_all(bufnr())
command! VimaUndo call vima#undo(bufnr())
command! VimaRedo call vima#redo(bufnr())
command! VimaPrevious call vima#previous(bufnr())
command! VimaNext call vima#next(bufnr())

augroup Vima
  autocmd!
  autocmd BufReadPost * call vima#on_read(expand('<abuf>')->str2nr())
  autocmd BufWinEnter * if getbufvar(expand('<abuf>')->str2nr(), 'vima_attached', v:false) | call vima#settle(expand('<abuf>')->str2nr()) | endif
  autocmd BufWritePost * if getbufvar(expand('<abuf>')->str2nr(), 'vima_attached', v:false) | call vima#refresh(expand('<abuf>')->str2nr()) | endif
  autocmd TextChanged,TextChangedI * if getbufvar(expand('<abuf>')->str2nr(), 'vima_attached', v:false) | call vima#schedule(expand('<abuf>')->str2nr()) | endif
  autocmd FileChangedShellPost * if getbufvar(expand('<abuf>')->str2nr(), 'vima_attached', v:false) | call vima#reload(expand('<abuf>')->str2nr()) | endif
  autocmd BufDelete,BufWipeout * call vima#cleanup(expand('<abuf>')->str2nr())
  autocmd ColorScheme * call <SID>apply_highlights()
  autocmd CursorMoved,WinScrolled,BufEnter * if getbufvar(bufnr(), 'vima_attached', v:false) | call vima#update_hints(bufnr()) | endif
augroup END

let &cpoptions = s:save_cpo
unlet s:save_cpo
