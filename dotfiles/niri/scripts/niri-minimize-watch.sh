#!/usr/bin/env bash
# Vigila el event-stream de niri para dar semantica real de "restaurar":
#
#  - Si una ventana minimizada recibe el foco (p. ej. al pulsarla en el dock de
#    DMS o en Alt+Tab), se devuelve a su workspace de origen en vez de dejar al
#    usuario tirado en el workspace almacen.
#  - Si una ventana minimizada se cierra, se saca de la pila.
#
# Bajo demanda: NO arranca con la sesion. Lo lanza niri-minimize.sh al
# minimizar y termina en cuanto la pila queda vacia, asi que sin ventanas
# minimizadas no queda ningun proceso escuchando (antes eran ~20 MB residentes:
# bash + `niri msg event-stream`, y dos forks de jq y uno del helper por cada
# cambio de foco de la sesion).
#
# Uso: niri-minimize-watch.sh PILA   (la ruta la decide niri-minimize.sh)

set -uo pipefail

self=$(readlink -f "$0")
HELPER="${self%/*}/niri-minimize.sh"
STACK=${1:?uso: $0 PILA}

# Al salir se termina el grupo de procesos entero (el `niri msg` y el jq de
# abajo), asi que hace falta ser lider de un grupo propio. niri-minimize.sh ya
# lanza con setsid; esto cubre lanzarlo a mano. Sin fork: si no es lider,
# setsid(2) se aplica sobre este mismo pid.
read -r _ _ _ _ pgrp _ </proc/$$/stat
[ "$pgrp" = "$$" ] || exec setsid "$0" "$@"

# Un solo vigilante por pila.
exec 8>"$STACK.watch"
flock -n 8 || exit 0

trap 'trap - EXIT; kill -- -$$ 2>/dev/null' EXIT

# Sale si la pila esta vacia. Se comprueba con el cerrojo de la pila tomado,
# el mismo bajo el que niri-minimize.sh apila y lanza vigilante: un minimize
# simultaneo o ve a este vigilante vivo, o lanza uno nuevo despues de que este
# haya soltado su cerrojo. Nunca queda una ventana minimizada sin vigilante.
exit_if_empty() {
    exec 9>"$STACK.lock"
    if flock -w 10 9 && [ ! -s "$STACK" ]; then
        exec 8>&-
        exit 0
    fi
    exec 9>&-
}

# Pertenencia a la pila sin fork. Es solo un filtro previo: el helper vuelve a
# mirar la pila con el cerrojo tomado antes de tocar nada.
in_stack() {
    local sid _
    while IFS=$'\t' read -r sid _; do
        [ "$sid" = "$1" ] && return 0
    done <"$STACK"
    return 1
}

handle() {
    if [ -n "$2" ] && in_stack "$2"; then
        "$HELPER" "$1" "$2" 7<&- 8>&- || true
    fi
    [ -s "$STACK" ] || exit_if_empty
}

# Lanzado de mas: la pila se vacio mientras arrancaba.
exit_if_empty

# Un solo jq para todo el stream: descarta en C los eventos que no interesan
# (cambios de titulo, de workspace, de distribucion de teclado...) y bash solo
# despierta con foco y cierre. El estado inicial del stream no trae
# WindowFocusChanged (niri-ipc/src/state.rs) pero si WindowsChanged con
# is_focused: de ahi sale el foco al conectar, que cubre el hueco entre mover
# la ventana al almacen y que este vigilante se conecte. `exec 8>&-`: ni el
# subshell ni sus hijos deben retener el cerrojo del vigilante.
exec 7< <(
    exec 8>&-
    niri msg -j event-stream | jq --unbuffered -r '
        if .WindowFocusChanged then "focus \(.WindowFocusChanged.id // "")"
        elif .WindowClosed then "closed \(.WindowClosed.id)"
        elif .WindowsChanged then
            (.WindowsChanged.windows[] | select(.is_focused) | "focus \(.id)")
        else empty end'
)

while read -r -u 7 kind id; do
    case "$kind" in
        focus)  handle restore-id "$id" ;;
        closed) handle forget "$id" ;;
    esac
done
# El stream se corto (niri se cerro o reinicio): la pila era de esa instancia.
