#!/usr/bin/env bash
# Emula minimizar/restaurar ventanas en niri.
#
# niri no tiene el concepto de "minimizado". Esto lo simula moviendo la ventana
# a un workspace con nombre ("min") que actua de almacen, y guardando una pila
# con el id de ventana y el workspace de origen para poder devolverla a su sitio.
#
# Uso: niri-minimize.sh {minimize|restore|pick|list}

set -euo pipefail

STASH_WS="min"
STACK="${XDG_RUNTIME_DIR:-/tmp}/niri-minimized"

touch "$STACK"

# Las ordenes llegan a la vez: el boton de minimizar (via niri), el vigilante
# del event-stream y los atajos. Sin cerrojo, dos minimize-id de la misma
# ventana pasaban los dos el "ya esta minimizada" y el segundo guardaba el
# almacen como origen; y restore_window, al enfocar la ventana, dispara un
# restore-id del vigilante mientras ella misma sigue a medias. El cerrojo cubre
# solo lo que lee y escribe la pila, nunca el menu de pick, que espera al usuario.
lock() {
    exec 9>"$STACK.lock"
    flock -w 10 9 || { echo "niri-minimize: pila ocupada" >&2; exit 1; }
}
unlock() {
    flock -u 9
}

# Elimina de la pila los ids de ventanas que ya no existen (cerradas mientras
# estaban minimizadas) y los que ya no estan en el workspace almacen.
prune() {
    local stash_ids
    stash_ids=$(stash_window_ids)
    local tmp
    tmp=$(mktemp)
    while IFS=$'\t' read -r id ws_id; do
        [ -n "${id:-}" ] || continue
        if grep -qx "$id" <<<"$stash_ids"; then
            printf '%s\t%s\n' "$id" "$ws_id" >>"$tmp"
        fi
    done <"$STACK"
    mv "$tmp" "$STACK"
}

# Id del workspace almacen, o vacio si ahora mismo no existe.
stash_ws_id() {
    niri msg -j workspaces | jq -r --arg n "$STASH_WS" '.[] | select(.name == $n) | .id' | head -n1
}

# Ids de ventana que estan ahora mismo en el workspace almacen.
stash_window_ids() {
    local ws_id
    ws_id=$(stash_ws_id)
    [ -n "$ws_id" ] || return 0
    niri msg -j windows | jq -r --argjson w "$ws_id" '.[] | select(.workspace_id == $w) | .id'
}

# El almacen no se declara en config.kdl: niri coloca los workspaces con nombre
# los primeros, y "min" en el indice 1 hacia arrancar la sesion en el 2. Se crea
# al minimizar, nombrando el workspace vacio del final del monitor enfocado
# (niri anade otro vacio detras), asi no desplaza los indices de los demas.
ensure_stash() {
    [ -n "$(stash_ws_id)" ] && return 0
    local last
    last=$(niri msg -j workspaces | jq -r '(map(select(.is_focused))[0].output) as $o | [.[] | select(.output == $o) | .idx] | max')
    niri msg action set-workspace-name --workspace "$last" "$STASH_WS"
}

# Cuando el almacen se queda sin ventanas se le quita el nombre y niri lo recoge
# como a cualquier workspace vacio.
release_stash_if_empty() {
    [ -n "$(stash_ws_id)" ] || return 0
    if [ -z "$(stash_window_ids)" ]; then
        niri msg action unset-workspace-name "$STASH_WS"
    fi
}

# Output del monitor en el que esta actualmente la ventana $1.
window_output() {
    local ws_id
    ws_id=$(niri msg -j windows | jq -r --argjson i "$1" '.[] | select(.id == $i) | .workspace_id')
    [ -n "$ws_id" ] || return 0
    niri msg -j workspaces | jq -r --argjson w "$ws_id" '.[] | select(.id == $w) | .output'
}

minimize() {
    local win
    win=$(niri msg -j focused-window)
    [ "$win" = "null" ] && exit 0
    minimize_id "$(jq -r '.id' <<<"$win")"
}

# Minimiza una ventana concreta por id. Lo usa el parche de minimize_request en
# niri, que recibe la peticion del boton de la barra de titulo del cliente.
minimize_id() {
    local id="$1" ws_id
    ws_id=$(niri msg -j windows | jq -r --argjson i "$id" '.[] | select(.id == $i) | .workspace_id')
    [ -n "$ws_id" ] || exit 0

    # Ya esta minimizada: no reapuntar el origen al propio almacen.
    grep -qP "^${id}\t" "$STACK" && exit 0

    ensure_stash
    niri msg action move-window-to-workspace --window-id "$id" --focus false "$STASH_WS"
    printf '%s\t%s\n' "$id" "$ws_id" >>"$STACK"
}

# Devuelve la ventana $1 a su workspace de origen ($2). Si ese workspace ya no
# existe, la devuelve al workspace enfocado.
restore_window() {
    local id="$1" origin_ws_id="${2:-}"
    local wss
    wss=$(niri msg -j workspaces)

    local target_idx target_output
    target_idx=$(jq -r --argjson w "${origin_ws_id:-0}" '.[] | select(.id == $w) | .idx' <<<"$wss")
    target_output=$(jq -r --argjson w "${origin_ws_id:-0}" '.[] | select(.id == $w) | .output' <<<"$wss")

    if [ -z "$target_idx" ] || [ "$target_idx" = "null" ]; then
        # El workspace de origen desaparecio: usar el enfocado.
        target_idx=$(jq -r '.[] | select(.is_focused) | .idx' <<<"$wss")
        target_output=$(jq -r '.[] | select(.is_focused) | .output' <<<"$wss")
    fi

    # El indice de workspace se resuelve sobre el output donde esta la ventana,
    # no sobre el enfocado. Como la ventana vive en el almacen (que puede estar
    # en otro monitor), primero se mueve al output destino y solo despues se
    # aplica el indice.
    local cur_output
    cur_output=$(window_output "$id")
    if [ -n "$target_output" ] && [ "$target_output" != "null" ] && [ "$target_output" != "$cur_output" ]; then
        niri msg action move-window-to-monitor --id "$id" "$target_output"
    fi

    niri msg action move-window-to-workspace --window-id "$id" --focus true "$target_idx"
    niri msg action focus-window --id "$id"

    # Sacarla de la pila.
    grep -v -P "^${id}\t" "$STACK" >"$STACK.tmp" || true
    mv "$STACK.tmp" "$STACK"
    release_stash_if_empty
}

restore_last() {
    prune
    local line
    line=$(tail -n1 "$STACK" || true)
    if [ -z "$line" ]; then
        notify-send -a niri "Minimizar" "No hay ventanas minimizadas"
        exit 0
    fi
    local id ws_id
    IFS=$'\t' read -r id ws_id <<<"$line"
    restore_window "$id" "$ws_id"
}

pick() {
    prune
    if [ ! -s "$STACK" ]; then
        notify-send -a niri "Minimizar" "No hay ventanas minimizadas"
        exit 0
    fi
    local wins menu sel id
    wins=$(niri msg -j windows)
    menu=""
    while IFS=$'\t' read -r id ws_id; do
        [ -n "${id:-}" ] || continue
        local label
        label=$(jq -r --argjson i "$id" '.[] | select(.id == $i) | "\(.app_id // "?") — \(.title // "")"' <<<"$wins")
        [ -n "$label" ] && menu+="$id"$'\t'"$label"$'\n'
    done <"$STACK"

    unlock
    sel=$(printf '%s' "$menu" | fuzzel --dmenu --prompt "Restaurar: " --with-nth 2 --accept-nth 1 2>/dev/null || true)
    [ -n "$sel" ] || exit 0
    id=$(awk '{print $1}' <<<"$sel")
    lock
    # Mientras el menu estaba abierto otra orden pudo restaurarla ya.
    ws_id=$(grep -P "^${id}\t" "$STACK" | head -n1 | cut -f2 || true)
    [ -n "$ws_id" ] || exit 0
    restore_window "$id" "$ws_id"
}

list() {
    prune
    cat "$STACK"
}

# Restaura una ventana concreta si esta minimizada; si no lo esta, no hace nada.
restore_id() {
    local id="$1" line ws_id
    line=$(grep -P "^${id}\t" "$STACK" | head -n1 || true)
    [ -n "$line" ] || exit 0
    ws_id=$(cut -f2 <<<"$line")
    restore_window "$id" "$ws_id"
}

# Saca de la pila una ventana que ya no existe.
forget() {
    grep -qP "^${1}\t" "$STACK" || exit 0
    grep -v -P "^${1}\t" "$STACK" >"$STACK.tmp" || true
    mv "$STACK.tmp" "$STACK"
    release_stash_if_empty
}

case "${1:-}" in
    minimize|minimize-id|restore|restore-id|forget|pick|list) lock ;;
esac

case "${1:-}" in
    minimize)    minimize ;;
    minimize-id) minimize_id "${2:?falta id}" ;;
    restore)    restore_last ;;
    restore-id) restore_id "${2:?falta id}" ;;
    forget)     forget "${2:?falta id}" ;;
    pick)       pick ;;
    list)       list ;;
    *) echo "uso: $0 {minimize|minimize-id ID|restore|restore-id ID|forget ID|pick|list}" >&2; exit 2 ;;
esac
