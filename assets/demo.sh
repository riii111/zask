#!/usr/bin/env bash
# Renders assets/demo.gif from assets/demo.tape as a translucent window over a wallpaper.
# Usage: assets/demo.sh <wallpaper>
# The wallpaper is read at render time and is not committed; any format sips can read works (PNG, JPEG, HEIC).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 1 ]; then
  echo "usage: $0 <wallpaper>" >&2
  exit 2
fi
wallpaper=$1

# Run from inside tmux, TMUX would point every tmux command here and in the recording at the caller's server.
unset TMUX

tmp=$(mktemp -d)
scratch="$tmp/scratch"
# The socket the recording's tmux creates from TMUX_TMPDIR="$scratch/tmux".
demo_socket="$scratch/tmux/tmux-$(id -u)/default"
cleanup() {
  # Stops the demo tmux server even when the recording fails halfway, so no services keep running.
  # The explicit socket keeps this from reaching any other tmux server.
  tmux -S "$demo_socket" kill-server 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

zig build
export PATH="$PWD/zig-out/bin:$PATH"

# The showcase without Docker, so the recording needs no images and starts in a stable time.
mkdir -p "$scratch/home" "$scratch/tmux"
cp -R testdata/showcase/receipt-lab "$scratch/receipt-lab"
python3 - "$scratch/receipt-lab/zask.json" <<'EOF'
import json, re, sys
path = sys.argv[1]
with open(path) as f:
    config = json.load(f)
config.pop("docker")
config["project"]["root"] = "."
config["startup_order"] = [phase for phase in config["startup_order"] if not phase.get("docker")]
# Faster workers, so their logs fill the popup within the recording.
for group in config["groups"]:
    for service in group["services"]:
        service["command"] = re.sub(r"--interval \S+", "--interval 0.4", service["command"])
with open(path, "w") as f:
    json.dump(config, f, indent=2)
EOF
printf '%s\n' "PS1='\$ '" >"$scratch/home/.bashrc"
# tmux's default status bar uses the theme's bright green; a darker bar keeps the focus on the panes.
printf '%s\n' "set -g status-style 'bg=#2b2520,fg=#fbcb97'" >"$scratch/home/.tmux.conf"

ZASK_DEMO_DIR="$scratch" vhs -q -o "$tmp/demo.gif" assets/demo.tape

# Must match Width, Height, Margin, BorderRadius and MarginFill in the tape.
width=1200 height=780 margin=40 radius=10 fill=0x808080
# Theme background as rendered in the VHS GIF, and the tint left over the wallpaper (kitty background_opacity).
terminal_bg=0x000000 tint=0x000000 tint_opacity=0.70

sips -s format png "$wallpaper" --out "$tmp/source.png" >/dev/null
ffmpeg -v error -y -i "$tmp/source.png" \
  -vf "scale=${width}:${height}:force_original_aspect_ratio=increase,crop=${width}:${height}" \
  -frames:v 1 "$tmp/wallpaper.png"

inner_x=$((margin + radius)) inner_y=$((margin + radius))
# 1. Window: key out the margin fill outside the window only, so terminal colors survive.
# 2. Glass: blur and darken the wallpaper inside the window, then show it where the terminal background was.
filter="[1:v]split=3[key][wide][tall];\
[key]colorkey=${fill}:0.12:0[keyed];\
[wide]crop=$((width - 2 * inner_x)):$((height - 2 * margin)):${inner_x}:${margin}[wide_crop];\
[tall]crop=$((width - 2 * margin)):$((height - 2 * inner_y)):${margin}:${inner_y}[tall_crop];\
[keyed][wide_crop]overlay=${inner_x}:${margin}[partial];\
[partial][tall_crop]overlay=${margin}:${inner_y},format=rgba,split[shape][window];\
[shape]alphaextract,format=gray[mask];\
[0:v]format=rgba,split[wallpaper][behind];\
color=c=${tint}:s=${width}x${height},format=rgba,colorchannelmixer=aa=${tint_opacity}[tint_color];\
[behind]gblur=sigma=12[blurred];\
[blurred][tint_color]overlay=format=rgb,format=rgba[frosted];\
[frosted][mask]alphamerge[glass];\
[wallpaper][glass]overlay=format=rgb[backdrop];\
color=c=${terminal_bg}:s=${width}x${height}[flat];\
[flat][window]overlay=shortest=1:format=rgb,format=rgba,colorkey=${terminal_bg}:0.005:0.02[text];\
[backdrop][text]overlay=shortest=1:format=rgb,format=rgb24,split[frames][palette_source];\
[palette_source]palettegen=stats_mode=full[palette];\
[frames][palette]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle[out]"
ffmpeg -v error -y -loop 1 -framerate 24 -i "$tmp/wallpaper.png" -i "$tmp/demo.gif" \
  -filter_complex "$filter" -map "[out]" "$tmp/composited.gif"
gifsicle -O3 "$tmp/composited.gif" -o assets/demo.gif 2>/dev/null
