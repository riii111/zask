
_zask() {
    local -a args=()
    local i quote
    for (( i = 1; i < COMP_CWORD; i++ )); do
        __zask_unquote "${COMP_WORDS[i]}"
        args+=("$__zask_word")
    done
    __zask_unquote "${COMP_WORDS[COMP_CWORD]}"
    quote=$__zask_quote
    COMPREPLY=()

    if (( ${#args[@]} > 0 )); then
        case ${args[${#args[@]}-1]} in
            --config)
                type compopt >/dev/null 2>&1 && { compopt -o default; return 0; }
                __zask_reply "$quote" < <(compgen -f -- "$__zask_word")
                return 0
                ;;
            --root)
                type compopt >/dev/null 2>&1 && { compopt -o dirnames; return 0; }
                __zask_reply "$quote" < <(compgen -d -- "$__zask_word")
                return 0
                ;;
        esac
    fi
    __zask_reply "$quote" < <(command zask __complete ${args[@]+"${args[@]}"} "$__zask_word" 2>/dev/null)
}

__zask_unquote() {
    local word=$1 value= quote= before= char i
    for (( i = 0; i < ${#word}; i++ )); do
        char=${word:i:1}
        if [[ $quote == "'" ]]; then
            if [[ $char == "'" ]]; then quote=; else value+=$char; fi
        elif [[ $char == '\' ]]; then
            i=$(( i + 1 ))
            char=${word:i:1}
            if [[ $quote == '"' ]]; then
                case $char in
                    '$'|'`'|'"'|'\') ;;
                    *) value+='\' ;;
                esac
            fi
            value+=$char
        elif [[ $char == '"' && $quote == '"' ]]; then
            quote=
        elif [[ ( $char == "'" || $char == '"' ) && -z $quote ]]; then
            quote=$char
            before=$value
        else
            value+=$char
        fi
    done
    case $word in
        \~/*) value=$HOME/${value#\~/} ;;
    esac
    __zask_word=$value
    __zask_quote=$quote
    __zask_before_quote=$before
}

__zask_reply() {
    local line squote="'" bslash='\'
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        [[ -n $1 ]] && line=${line#"$__zask_before_quote"}
        case $1 in
            \')
                line=${line//$squote/$squote$bslash$squote$squote}
                [[ $line == "$squote"* ]] && line=$squote$line
                ;;
            \")
                line=${line//$bslash/$bslash$bslash}
                line=${line//\$/$bslash\$}
                line=${line//\`/$bslash\`}
                line=${line//\"/$bslash\"}
                ;;
            *)
                printf -v line %q "$line"
                ;;
        esac
        COMPREPLY+=("$line")
    done
}

complete -F _zask zask
