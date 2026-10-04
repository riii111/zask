# fish completion for zask. Candidates come from `zask __complete`; fish
# escapes them on insertion, so config names are never evaluated as code.

function __zask_complete
    # Tokens before the cursor with the user's quoting removed.
    set -l args
    for token in (commandline -opc)
        if string match -q -- '~/*' $token
            set token $HOME/(string sub -s 3 -- $token)
        end
        set -a args $token
    end
    set -e args[1]
    switch "$args[-1]"
        case --config
            __fish_complete_path (commandline -ct)
            return
        case --root
            __fish_complete_directories (commandline -ct)
            return
    end
    # The current token is left to fish so it matches with its own quoting rules.
    command zask __complete $args "" 2>/dev/null
end

complete -c zask -f -a '(__zask_complete)'
