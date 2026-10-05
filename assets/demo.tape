# README demo. Render with assets/demo.sh, which prepares the workspace and composites the window over a wallpaper.
# assets/demo.sh copies testdata/showcase/receipt-lab without Docker into $ZASK_DEMO_DIR and builds zask.
# HOME and TMUX_TMPDIR point into $ZASK_DEMO_DIR so the recording never touches the real tmux server or dotfiles.

Require zask
Require tmux
Require python3

Set Shell bash
Set FontFamily "DroidSansM Nerd Font Mono"
Set FontSize 13
Set LineHeight 1.2
Set Width 1200
Set Height 780
Set Padding 16
# assets/demo.sh keys out MarginFill outside the window; keep its geometry in sync.
Set Margin 40
Set MarginFill "#808080"
Set WindowBar Colorful
Set BorderRadius 10
# Same palette as the author's kitty theme (dotfiles kitty/themes/black-metal-bathory.conf).
Set Theme {"name":"Black Metal (Bathory)","background":"#000000","foreground":"#c1c1c1","cursor":"#c1c1c1","selection":"#c1c1c1","black":"#000000","red":"#5f8787","green":"#fbcb97","yellow":"#e78a53","blue":"#888888","magenta":"#999999","cyan":"#aaaaaa","white":"#c1c1c1","brightBlack":"#404040","brightRed":"#5f8787","brightGreen":"#fbcb97","brightYellow":"#e78a53","brightBlue":"#888888","brightMagenta":"#999999","brightCyan":"#aaaaaa","brightWhite":"#c1c1c1"}
Set Framerate 24
Set TypingSpeed 120ms

# 0. Point the session at the scratch home and tmux socket, then enter the project.
# SHELL is also the dashboard pane's shell, so it gets the scratch .bashrc prompt.
Hide
Type@1ms `export HOME="$ZASK_DEMO_DIR/home" TMUX_TMPDIR="$ZASK_DEMO_DIR/tmux" SHELL="$(command -v bash)" BASH_SILENCE_DEPRECATION_WARNING=1 PS1='$ ' && unset TMUX && cd "$ZASK_DEMO_DIR/receipt-lab" && clear`
Enter
Sleep 1s
Show

# 1. Open the workspace: ordered startup, then the dashboard and monitor.
Sleep 800ms
Type "zask open"
Sleep 500ms
Enter
Wait+Screen@60s /LIVE:8/
Sleep 2500ms

# 2. Monitor: select ocr-worker and read its log in the popup.
Down@350ms 5
Sleep 800ms
Type "l"
# Wait for less to draw the log, not just the popup frame.
Wait+Screen@10s /\(END\)/
Sleep 1500ms
Ctrl+G
Sleep 800ms

# 3. Restart realtime, which has a port, so the monitor waits for it to be ready again.
Up@350ms 2
Sleep 600ms
Type "r"
Wait+Screen@15s /restarted realtime/
Sleep 2000ms

# 4. Jump to its window, then come back through the window list.
Enter
Sleep 2000ms
Ctrl+Q
Type "w"
Sleep 1500ms
Up@300ms 4
Sleep 800ms
Enter
Sleep 1500ms

# 5. Close the workspace from the dashboard shell.
Ctrl+Q
Left
Sleep 600ms
Type "zask close"
Sleep 500ms
Enter
Wait+Screen@30s /exited/
Sleep 2s
