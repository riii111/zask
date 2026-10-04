#compdef zask
# zsh completion for zask. Candidates come from `zask __complete`; compadd
# quotes them on insertion, so config names are never evaluated as code.

_zask() {
  local -a args candidates
  local out i
  # (Q) removes the user's quoting without expanding anything. Only a ~ typed
  # unquoted is expanded, matching what the command receives.
  args=("${(@Q)words[2,CURRENT-1]}")
  for (( i = 1; i <= $#args; i++ )); do
    [[ ${words[i+1]} == '~/'* ]] && args[i]=$HOME/${args[i]#'~/'}
  done
  case ${args[-1]} in
    --config) _files; return ;;
    --root) _files -/; return ;;
  esac
  # The current word is left to compadd so zsh matches it with its own quoting rules.
  out=$(command zask __complete "${args[@]}" "" 2>/dev/null) || return 1
  candidates=("${(@f)out}")
  candidates=(${candidates:#})
  (( $#candidates )) || return 1
  compadd -- "${candidates[@]}"
}

if [[ $funcstack[1] == _zask ]]; then
  _zask "$@"
else
  (( $+functions[compdef] )) || { autoload -Uz compinit && compinit; }
  compdef _zask zask
fi
