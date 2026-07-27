# vima.vim

> **Experimental:** vima.vim is an experimental plugin. Commands, mappings,
> state handling, and rendering behavior may change before the first stable
> release. Keep normal backups while evaluating it.

Review AI-agent edits directly inside a Vim buffer. Deleted lines are shown as
red virtual text, added lines remain editable and green, and each change can be
allowed or rejected without opening a split.

`:VimaEnable` safely compares the current buffer with the file's Git index
version, so modifications that already exist when the file is opened are
visible. `:VimaStart` captures the current buffer and reviews only later edits;
that mode also supports untracked files.

## Requirements

- Vim 9.0.0438 or newer compiled with `+textprop`
- A named, modifiable text buffer
- Git for `:VimaEnable`, older Vim builds, and larger diff calculations

Check the relevant features with:

```vim
:echo has('patch-9.0.0438')
:echo has('textprop')
:echo exists('*diff')
```

## Installation

### Native Vim packages

```sh
mkdir -p ~/.vim/pack/vima/start
git clone https://github.com/GZJ/vima.vim \
  ~/.vim/pack/vima/start/vima.vim
```

Vim automatically loads plugins under a `pack/*/start/` directory.

### vim-plug

Add this to `.vimrc`:

```vim
call plug#begin()
Plug 'GZJ/vima.vim'
call plug#end()
```

Then run `:PlugInstall`.

For local development:

```vim
set runtimepath^=/home/g/z/vima.vim
```

## Usage

Vima is opt-in by default so normal-mode keys are never taken over merely by
opening a file.

For modifications that already exist, run `:VimaEnable`. Vima reads the exact
stage-0 Git index version and immediately displays the current diff.

To review only a new AI transaction:

1. Open the file before the agent edits it.
2. Run `:VimaStart` to capture the current in-memory buffer.
3. Let the agent edit the buffer or file.
4. Use `a` or `r` while the cursor is on a pending change.
5. Run `:VimaReset` before another transaction, or `:VimaDisable` when done.

While review mode is enabled:

- `a` allows the change under the cursor.
- `r` rejects the change under the cursor and restores baseline text.
- `u` undoes the latest review decision, or falls back to native undo.
- `Ctrl-r` redoes the latest review decision, or falls back to native redo.

The cursor must be on a green added line. For a deletion-only change, place the
cursor on the real line to which the virtual deletion is attached. Commands
outside those locations change nothing.

### Launch with Vima enabled

To keep regular `vim` sessions opt-in while providing a separate command that
starts with Vima enabled globally, add this alias to `~/.bashrc`:

```sh
alias vima="vim -c 'VimaEnableAll'"
```

Reload the configuration with `source ~/.bashrc`, then use `vima file.txt`.
`:VimaEnableAll` attaches eligible buffers that were loaded at startup and
automatically attaches eligible buffers opened later in the same session. For
Zsh, put the same alias in `~/.zshrc` instead.

## Commands

- `:VimaEnable` starts review mode from the safe Git index baseline.
- `:VimaStart` starts review mode from the current in-memory buffer.
- `:VimaDisable` clears review state and restores mappings.
- `:VimaToggle` toggles review mode.
- `:VimaEnableAll` enables automatic review and attaches all loaded file buffers.
- `:VimaDisableAll` disables automatic review and detaches all buffers.
- `:VimaToggleAll` toggles automatic review and all loaded buffers.
- `:VimaRefresh` recalculates decorations.
- `:VimaReset` makes the current buffer the baseline for a new transaction.
- `:VimaAllow` and `:VimaReject` act on the change under the cursor.
- `:VimaAllowAll` and `:VimaRejectAll` act on all pending changes.
- `:VimaUndo` and `:VimaRedo` manage review decisions.

Allowing a change does not write, stage, or commit it. Use `:VimaReset` after
accepting a completed transaction. File reloads retain the selected Git or
buffer baseline but clear stale review decisions.

## Options

Set options before the plugin loads:

```vim
let g:vima_enabled = v:false
let g:vima_show_signs = v:true
let g:vima_delete_prefix = ''
let g:vima_debounce = 150
let g:vima_max_file_size = 2 * 1024 * 1024
let g:vima_max_lines = 50000
let g:vima_max_changes = 2000
let g:vima_history_limit = 50
let g:vima_git = 'git'
let g:vima_internal_diff_max_file_size = 512 * 1024
let g:vima_internal_diff_max_lines = 5000
let g:vima_mappings = {
      \ 'allow': 'a',
      \ 'reject': 'r',
      \ 'undo': 'u',
      \ 'redo': '<C-r>',
      \ }
```

`g:vima_enabled` controls automatic review for buffers read later. The global
commands also apply the setting immediately to buffers that are already loaded.

Set a mapping to `v:false` or an empty string to leave that key untouched. Vima
also provides `<Plug>(VimaAllow)`, `<Plug>(VimaReject)`, `<Plug>(VimaUndo)`, and
`<Plug>(VimaRedo)`.

Buffers above the configured limits are not rendered. History is bounded and
stores changed hunks plus hashes instead of a complete buffer for every action.
To keep real and virtual diff lines aligned, Vima temporarily disables `wrap`
in each review window and restores that window's previous value on disable. It
does not enable or disable Signify.

Small buffers on recent Vim builds use the in-process `diff()` function. Older
builds and larger buffers use `git diff --no-index`, which avoids a worst case
in Vim's List-based diff implementation. Only `:VimaEnable` reads Git index
content, and it aborts without attaching if that lookup fails.

## Tests

```sh
./tests/run.sh
```

Run `:helptags ALL`, then see `:help vima` for the command reference.
