# bash completion for zask. Candidates come from `zask __complete` and are
# escaped before insertion, so config names are never evaluated as code.
# Written for bash 3.2 as well, which macOS ships as /bin/bash.

_zask() {
    local -a args=()
    local i quote=
    for (( i = 1; i < COMP_CWORD; i++ )); do
        __zask_unquote "${COMP_WORDS[i]}"
        args+=("$__zask_word")
    done
    case ${COMP_WORDS[COMP_CWORD]} in
        \'*|\"*) quote=${COMP_WORDS[COMP_CWORD]:0:1} ;;
    esac
    __zask_unquote "${COMP_WORDS[COMP_CWORD]}"
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

# Removes the user's quoting without eval, so typed words are never expanded.
__zask_unquote() {
    local word=$1
    case $word in
        \'*) word=${word#\'}; word=${word%\'} ;;
        \"*) word=${word#\"}; word=${word%\"} ;;
        *) word=${word//\\/} ;;
    esac
    case $word in
        \~/*) word=$HOME/${word#\~/} ;;
    esac
    __zask_word=$word
}

# Adds each input line to COMPREPLY, escaped for the quote the user opened.
# readline inserts replies as typed text, so anything left unescaped would run
# as shell syntax when the line is executed.
__zask_reply() {
    local line squote="'" bslash='\'
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        case $1 in
            \')
                line=${line//$squote/$squote$bslash$squote$squote}
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
