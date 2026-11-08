#!/usr/bin/env bash
# Rota la salida enfocada 90 grados por pulsacion. La tecla KEY_ROTATE_DISPLAY
# (evdev 153 -> XF86RotateWindows) del MSI MS-15H4 la dispara.
# El transform vive en outputs[<name>].logical.transform y niri lo devuelve
# capitalizado ("Normal", "_90"), asi que se normaliza antes de comparar.
set -euo pipefail

# Una sola consulta: focused-output ya trae su transform. Antes eran dos
# `niri msg` y un python3 (~50 ms de arranque) por pulsación.
read -r out cur < <(niri msg --json focused-output | jq -r '
    "\(.name) \(.logical.transform // "Normal" | ascii_downcase | ltrimstr("_"))"')

case "$cur" in
    normal) next=90 ;;
    90)     next=180 ;;
    180)    next=270 ;;
    *)      next=normal ;;
esac

niri msg output "$out" transform "$next"
command -v dms >/dev/null && dms ipc call toast info "Pantalla: $next" >/dev/null 2>&1 || true
