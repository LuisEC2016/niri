#!/usr/bin/env bash
# Vigila el event-stream de niri para dar semantica real de "restaurar":
#
#  - Si una ventana minimizada recibe el foco (p. ej. al pulsarla en el dock de
#    DMS o en Alt+Tab), se devuelve a su workspace de origen en vez de dejar al
#    usuario tirado en el workspace almacen.
#  - Si una ventana minimizada se cierra, se saca de la pila.

set -euo pipefail

HELPER="$(dirname "$(readlink -f "$0")")/niri-minimize.sh"
STACK="${XDG_RUNTIME_DIR:-/tmp}/niri-minimized"

# Arranque limpio: al iniciar sesion no hay nada minimizado.
: >"$STACK"

niri msg -j event-stream | while IFS= read -r line; do
    case "$line" in
        *WindowFocusChanged*)
            id=$(jq -r '.WindowFocusChanged.id // empty' <<<"$line")
            [ -n "$id" ] && "$HELPER" restore-id "$id" || true
            ;;
        *WindowClosed*)
            id=$(jq -r '.WindowClosed.id // empty' <<<"$line")
            [ -n "$id" ] && "$HELPER" forget "$id" || true
            ;;
    esac
done
