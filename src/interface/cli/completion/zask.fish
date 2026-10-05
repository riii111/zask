
function __zask_complete
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
    command zask __complete $args "" 2>/dev/null
end

complete -c zask -f -a '(__zask_complete)'
