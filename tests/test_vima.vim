let s:repo_root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:repo_root)
runtime plugin/vima.vim

let s:path = tempname()
call writefile(["\tone", 'two', 'three'], s:path)
execute 'edit ' .. fnameescape(s:path)
nnoremap <buffer> a :let g:vima_original_map = 1<CR>
let s:original = maparg('a', 'n', v:false, v:true)
setlocal wrap
call assert_equal(0, getbufvar(bufnr(), 'vima_attached', 0), 'setup attached by default')
call assert_equal(s:original.rhs, maparg('a', 'n', v:false, v:true).rhs, 'setup changed mapping')

VimaStart
call assert_equal(0, &l:wrap, 'review window still wraps')
call assert_equal('<Plug>(VimaAllow)', maparg('a', 'n', v:false, v:true).rhs, 'mapping was not installed')
let s:changed = ["\tONE", 'two', 'new', 'three']
call setline(1, s:changed)
VimaRefresh
let s:deleted_props = prop_list(1, {'end_lnum': -1, 'types': ['VimaDelete']})
let s:prefix = get(g:, 'vima_delete_prefix', '')
" Tabs in virtual text start at the text area's virtual column zero. Number,
" sign, and fold columns are outside that coordinate system.
let s:start_width = strdisplaywidth(s:prefix)
let s:tab_width = &tabstop - (s:start_width % &tabstop)
call assert_true(index(map(copy(s:deleted_props), {_, prop -> prop.text}), s:prefix .. repeat(' ', s:tab_width) .. 'one') >= 0, 'deleted Tab indentation is misaligned')

" Consecutive deleted lines must retain their original top-to-bottom order.
VimaDisable
call setline(1, ['first', 'second', 'third', 'tail'])
call deletebufline(bufnr(), 5, '$')
VimaStart
call setline(1, ['tail'])
call deletebufline(bufnr(), 2, '$')
VimaRefresh
let s:ordered_props = prop_list(1, {'end_lnum': 1, 'types': ['VimaDelete']})
" prop_list() exposes above-line properties from the visual bottom upwards.
call assert_equal(['third', 'second', 'first'], map(copy(s:ordered_props), {_, prop -> prop.text}), 'deleted-line property stack is incorrect')
VimaDisable

" Restore the main undo/allow/reject scenario.
call setline(1, ["\tone", 'two', 'three'])
call deletebufline(bufnr(), 4, '$')
VimaStart
call setline(1, s:changed)
call deletebufline(bufnr(), 5, '$')
VimaRefresh

VimaRejectAll
call assert_equal(["\tone", 'two', 'three'], getline(1, '$'), 'reject all failed')
VimaUndo
call assert_equal(s:changed, getline(1, '$'), 'reject undo failed')
VimaRedo
call assert_equal(["\tone", 'two', 'three'], getline(1, '$'), 'reject redo failed')

VimaUndo
VimaAllowAll
VimaUndo
call assert_equal(s:changed, getline(1, '$'), 'allow undo changed buffer')
VimaRedo
VimaReset
VimaRejectAll
call assert_equal(s:changed, getline(1, '$'), 'reset failed')

call writefile(['external', 'content'], s:path)
edit!
VimaRejectAll
call assert_equal(s:changed, getline(1, '$'), 'reload lost the review baseline')

VimaDisable
call assert_equal(s:original.rhs, maparg('a', 'n', v:false, v:true).rhs, 'mapping was not restored')
call assert_equal(1, &l:wrap, 'window wrap was not restored')

let s:large_path = tempname()
call writefile(['more than five bytes'], s:large_path)
let g:vima_max_file_size = 5
execute 'edit! ' .. fnameescape(s:large_path)
silent VimaEnable
call assert_equal(0, getbufvar(bufnr(), 'vima_attached', 0), 'oversized buffer was attached')

let s:no_git_path = tempname()
call writefile(['must survive', 'second'], s:no_git_path)
let g:vima_max_file_size = 2 * 1024 * 1024
let g:vima_git = 'vima-command-that-does-not-exist'
execute 'edit! ' .. fnameescape(s:no_git_path)
VimaEnable
VimaRejectAll
call assert_equal(['must survive', 'second'], getline(1, '$'), 'Git baseline failure modified the buffer')
call assert_equal(0, getbufvar(bufnr(), 'vima_attached', 0), 'Git baseline failure attached Vima')

let g:vima_git = 'git'
let s:git_dir = tempname()
call mkdir(s:git_dir, 'p', 0700)
let s:git_path = s:git_dir .. '/tracked.txt'
call writefile(['git baseline', 'second'], s:git_path)
call system('git -C ' .. shellescape(s:git_dir) .. ' init -q')
call assert_equal(0, v:shell_error, 'git init failed')
call system('git -C ' .. shellescape(s:git_dir) .. ' add -- ' .. shellescape('tracked.txt'))
call assert_equal(0, v:shell_error, 'git add failed')
call writefile(['existing change', 'second'], s:git_path)
execute 'edit! ' .. fnameescape(s:git_path)
VimaEnable
VimaRejectAll
call assert_equal(['git baseline', 'second'], getline(1, '$'), 'Git baseline reject failed')
VimaDisable

let s:untracked_path = s:git_dir .. '/untracked.txt'
call writefile(['untracked survives'], s:untracked_path)
execute 'edit! ' .. fnameescape(s:untracked_path)
VimaEnable
VimaRejectAll
call assert_equal(['untracked survives'], getline(1, '$'), 'untracked file was modified')
call assert_equal(0, getbufvar(bufnr(), 'vima_attached', 0), 'untracked file was attached')

call delete(s:path)
call delete(s:large_path)
call delete(s:no_git_path)
call delete(s:git_dir, 'rf')
if !empty(v:errors)
  for s:error in v:errors | echomsg s:error | endfor
  cquit
endif
qa!
