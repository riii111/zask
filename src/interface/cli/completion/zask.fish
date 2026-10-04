# fish completion for zask. Candidates come from `zask __complete`; fish
# escapes them on insertion, so config names are never evaluated as code.

function __zask_complete
    # Tokens before the cursor as the command would receive them. -x (fish 4)
    # expands an unquoted ~ and variables but never runs command substitutions;
    # older fish only removes quoting.
    set -l args (commandline -xpc 2>/dev/null)
    or set args (commandline -opc)
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
