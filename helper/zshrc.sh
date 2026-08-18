# Portable zsh interactive defaults.
#
# This file is copied into the portable runtime directory as zshrc.sh and
# sourced by the packaged .zshrc before handing off to the user's real .zshrc.
# Keep it independent from any per-user checkout so nested portable zsh sessions
# always load the same default key bindings and prompt.

if [[ -o interactive ]]; then
  PROMPT="%n@%~%# "
  zsh_portable_fix_keys() {
    local zsh_portable_keymap
    for zsh_portable_keymap in main emacs viins vicmd; do
      bindkey -M "$zsh_portable_keymap" "^M" accept-line 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^J" accept-line 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^?" backward-delete-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^H" backward-delete-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[A" up-line-or-history 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[B" down-line-or-history 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[C" forward-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[D" backward-char 2>/dev/null
      bindkey -M "$zsh_portable_keymap" "^[[200~" bracketed-paste 2>/dev/null
    done
    stty erase "^?" 2>/dev/null || stty erase "^H" 2>/dev/null
  }
  zsh_portable_fix_keys
  precmd_functions=(${precmd_functions:#zsh_portable_fix_keys} zsh_portable_fix_keys)
fi
