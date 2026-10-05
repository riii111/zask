#compdef zask

_zask() {
  local -a args candidates
  local out i
  args=("${(@Q)words[2,CURRENT-1]}")
  for (( i = 1; i <= $#args; i++ )); do
    [[ ${words[i+1]} == '~/'* ]] && args[i]=$HOME/${args[i]#'~/'}
  done
  case ${args[-1]} in
    --config) _files; return ;;
    --root) _files -/; return ;;
  esac
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
