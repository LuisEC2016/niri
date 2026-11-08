#!/usr/bin/env bash
# Menú (fuzzel) para elegir qué ventana minimizada restaurar.
#
# niri minimiza de forma nativa: acciones minimize-window y unminimize-window,
# el botón de minimizar de las decoraciones y wlr-foreign-toplevel (el dock de
# DMS). Este script solo añade la lista para elegir una; las primeras son las
# que tuvieron el foco más recientemente.
#
# Sustituye a niri-minimize.sh y niri-minimize-watch.sh, que emulaban minimizar
# con un workspace "min", una pila en $XDG_RUNTIME_DIR y un vigilante del
# event-stream.
#
# Uso: niri-minimized-menu.sh
set -euo pipefail

# Una línea "<id>\t<app> — <título>" por ventana minimizada.
menu=$(niri msg -j windows | jq -r '
    map(select(.is_minimized))
    | sort_by(.focus_timestamp.secs // 0, .focus_timestamp.nanos // 0)
    | reverse[]
    | "\(.id)\t\(.app_id // "?") — \(.title // "")"')

if [ -z "$menu" ]; then
    notify-send -a niri "Minimizar" "No hay ventanas minimizadas"
    exit 0
fi

sel=$(printf '%s\n' "$menu" | fuzzel --dmenu --prompt "Restaurar: " --with-nth 2 --accept-nth 1 2>/dev/null || true)
[ -n "$sel" ] || exit 0

exec niri msg action unminimize-window --id "$sel"
