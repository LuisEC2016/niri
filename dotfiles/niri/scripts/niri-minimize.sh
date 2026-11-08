#!/usr/bin/env bash
# Emula minimizar/restaurar ventanas en niri.
#
# niri no tiene el concepto de "minimizado". Esto lo simula moviendo la ventana
# a un workspace con nombre ("min") que actua de almacen, y guardando una pila
# con el id de ventana y el workspace de origen para poder devolverla a su sitio.
#
# Uso: niri-minimize.sh {minimize|restore|pick|list}
#
# Procesos: cada orden toma una foto del estado (`niri msg` de workspaces y de
# ventanas) y saca de ella todo lo que necesita con un solo jq; la pila se lee
# y se reescribe con builtins de bash. Antes cada dato era su propio par
# `niri msg | jq` (más head/cut/grep/mktemp, que aquí son coreutils en Rust,
# ~8 MB por proceso): restaurar una ventana lanzaba ~30 procesos, ahora ~10.

set -euo pipefail

STASH_WS="min"

# Una pila por instancia de niri. $NIRI_SOCKET lleva el pid del compositor
# (niri.wayland-1.<pid>.sock) y niri lo exporta a todo lo que lanza.
# XDG_RUNTIME_DIR sobrevive a reiniciar niri sin cerrar sesión y los ids de
# ventana vuelven a empezar en 1: una pila heredada "restauraría" ventanas
# nuevas que no tienen nada que ver. Antes lo evitaba el vigilante vaciando la
# pila al arrancar con la sesión; ahora el vigilante no arranca con la sesión.
instance=${NIRI_SOCKET:-niri}
instance=${instance##*/}
STACK="${XDG_RUNTIME_DIR:-/tmp}/${instance%.sock}.minimized"

: >>"$STACK"

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

# --- Estado de niri ---------------------------------------------------------

# Foto del estado: el JSON de workspaces y el de ventanas, uno detrás de otro.
# Hay que repetirla después de mover ventanas.
SNAP=
snapshot() {
    SNAP=$(niri msg -j workspaces && niri msg -j windows)
}

# Filtra la foto con un solo jq. Dentro del programa: $ws (workspaces), $win
# (ventanas), $n (nombre del almacen) y $stash (id del almacen, o null).
# Uso: query PROGRAMA [opciones de jq...]
query() {
    local prog=$1
    shift
    # Las opciones van detrás del programa: con --args delante, jq tomaría el
    # primer argumento posicional como programa.
    jq -rs --arg n "$STASH_WS" '
        .[0] as $ws | .[1] as $win
        | ([$ws[] | select(.name == $n) | .id][0]) as $stash
        | '"$prog" "$@" <<<"$SNAP"
}

# Cuando el almacen se queda sin ventanas se le quita el nombre y niri lo recoge
# como a cualquier workspace vacio. Mira el estado de ahora, no una foto vieja.
release_stash_if_empty() {
    local empty
    snapshot
    empty=$(query 'if $stash != null and all($win[]; .workspace_id != $stash) then 1 else empty end')
    if [ -n "$empty" ]; then
        niri msg action unset-workspace-name "$STASH_WS"
    fi
}

# --- Pila -------------------------------------------------------------------
# Una linea por ventana minimizada: "<id>\t<id del workspace de origen>".

# Linea de la pila de la ventana $1 (la primera, si hubiera varias) en $line.
# Falla si no esta.
stack_line() {
    local l
    line=
    while IFS= read -r l || [ -n "$l" ]; do
        if [[ $l == "$1"$'\t'* ]]; then
            line=$l
            return 0
        fi
    done <"$STACK"
    return 1
}

# Quita de la pila todas las lineas de la ventana $1. Reescribe con rename para
# que el vigilante, que lee la pila sin cerrojo, nunca la vea a medias.
stack_remove() {
    local l
    while IFS= read -r l || [ -n "$l" ]; do
        [[ $l == "$1"$'\t'* ]] || printf '%s\n' "$l"
    done <"$STACK" >"$STACK.tmp"
    mv "$STACK.tmp" "$STACK"
}

# Elimina de la pila los ids de ventanas que ya no existen (cerradas mientras
# estaban minimizadas) y los que ya no estan en el workspace almacen. Toma la
# foto que usan despues restore_last y pick.
prune() {
    local -A keep=()
    local l id ws_id out kept="" changed=0
    snapshot
    out=$(query 'if $stash == null then empty else ($win[] | select(.workspace_id == $stash) | .id) end')
    while read -r id; do
        [ -n "$id" ] && keep[$id]=1
    done <<<"$out"
    while IFS= read -r l || { [ -n "$l" ] && changed=1; }; do
        IFS=$'\t' read -r id ws_id <<<"$l"
        if [ -n "${id:-}" ] && [ -n "${keep[$id]:-}" ]; then
            kept+="$id"$'\t'"$ws_id"$'\n'
            [ "$l" = "$id"$'\t'"$ws_id" ] || changed=1
        else
            changed=1
        fi
    done <"$STACK"
    # Solo se reescribe si sobra algo: lo normal es que no, y el mv es un proceso.
    if [ "$changed" -eq 1 ]; then
        printf '%s' "$kept" >"$STACK.tmp"
        mv "$STACK.tmp" "$STACK"
    fi
}

# --- Ordenes ----------------------------------------------------------------

# Minimiza la ventana enfocada (sin argumento) o una concreta por id. La
# segunda la usa el parche de minimize_request en niri, que recibe la peticion
# del boton de la barra de titulo del cliente.
minimize_id() {
    local out id ws_id stash last
    snapshot
    # Ventana, su workspace, el almacen y el ultimo workspace del monitor
    # enfocado, una linea cada uno: read con IFS de tabulador se comeria los
    # campos vacios.
    out=$(query '
        ([$win[] | select(if $i == null then .is_focused else .id == $i end)][0]) as $w
        | if $w == null then empty else
            $w.id,
            ($w.workspace_id | tostring),
            ($stash // ""),
            (([$ws[] | select(.is_focused)][0].output) as $o
             | [$ws[] | select(.output == $o) | .idx] | max | tostring)
          end' --argjson i "${1:-null}")
    [ -n "$out" ] || exit 0
    { read -r id; read -r ws_id; read -r stash; read -r last; } <<<"$out"

    # Ya esta minimizada: no reapuntar el origen al propio almacen. Si el
    # vigilante murio por otra causa (kill, OOM), esto lo vuelve a levantar; si
    # vive, el nuevo sale solo.
    stack_line "$id" && { start_watcher; exit 0; }

    # El almacen no se declara en config.kdl: niri coloca los workspaces con
    # nombre los primeros, y "min" en el indice 1 hacia arrancar la sesion en
    # el 2. Se crea al minimizar, nombrando el workspace vacio del final del
    # monitor enfocado (niri anade otro vacio detras), asi no desplaza los
    # indices de los demas.
    if [ -z "$stash" ]; then
        niri msg action set-workspace-name --workspace "$last" "$STASH_WS"
    fi
    niri msg action move-window-to-workspace --window-id "$id" --focus false "$STASH_WS"
    printf '%s\t%s\n' "$id" "$ws_id" >>"$STACK"
    start_watcher
}

# El vigilante solo vive mientras hay ventanas minimizadas: se lanza aquí y
# termina solo cuando la pila se vacía. Si ya hay uno, el nuevo sale al no
# conseguir su cerrojo. Se lanza con el cerrojo de la pila tomado, y el
# vigilante decide salir también con él tomado: o ve esta entrada, o ya ha
# soltado el suyo y este arranca.
#   setsid: grupo de procesos propio, para que al salir se lleve por delante su
#           `niri msg event-stream` y su jq.
#   9>&-:   sin esto heredaría el cerrojo de la pila y bloquearía todas las
#           órdenes siguientes mientras viviera.
start_watcher() {
    local self
    self=$(readlink -f "$0")
    setsid -f "${self%/*}/niri-minimize-watch.sh" "$STACK" </dev/null 9>&- || true
}

# Devuelve la ventana $1 a su workspace de origen ($2). Si ese workspace ya no
# existe, la devuelve al workspace enfocado. Usa la foto que haya en $SNAP.
restore_window() {
    local id="$1" origin_ws_id="${2:-}" out
    local target_idx target_output cur_output
    out=$(query '
        ([$ws[] | select(.id == $o)][0]
         // [$ws[] | select(.is_focused)][0]) as $t
        | ([$win[] | select(.id == $i)][0].workspace_id) as $cur
        | ($t.idx // "" | tostring),
          ($t.output // ""),
          ([$ws[] | select(.id == $cur) | .output][0] // "")
        ' --argjson o "${origin_ws_id:-0}" --argjson i "$id")
    { read -r target_idx; read -r target_output; read -r cur_output; } <<<"$out"

    # El indice de workspace se resuelve sobre el output donde esta la ventana,
    # no sobre el enfocado. Como la ventana vive en el almacen (que puede estar
    # en otro monitor), primero se mueve al output destino y solo despues se
    # aplica el indice.
    if [ -n "$target_output" ] && [ "$target_output" != "$cur_output" ]; then
        niri msg action move-window-to-monitor --id "$id" "$target_output"
    fi

    niri msg action move-window-to-workspace --window-id "$id" --focus true "$target_idx"
    niri msg action focus-window --id "$id"

    stack_remove "$id"
    release_stash_if_empty
}

restore_last() {
    prune
    local line="" l id ws_id
    while IFS= read -r l || [ -n "$l" ]; do
        line=$l
    done <"$STACK"
    if [ -z "$line" ]; then
        notify-send -a niri "Minimizar" "No hay ventanas minimizadas"
        exit 0
    fi
    IFS=$'\t' read -r id ws_id <<<"$line"
    restore_window "$id" "$ws_id"
}

pick() {
    prune
    if [ ! -s "$STACK" ]; then
        notify-send -a niri "Minimizar" "No hay ventanas minimizadas"
        exit 0
    fi
    local ids=() id ws_id menu sel line
    while IFS=$'\t' read -r id ws_id; do
        [ -n "${id:-}" ] && ids+=("$id")
    done <"$STACK"
    # Una linea "<id>\t<app> — <titulo>" por ventana, en el orden de la pila.
    menu=$(query '
        ($win | map({key: (.id | tostring), value: .}) | from_entries) as $by
        | $ARGS.positional[] | $by[.] // empty
        | "\(.id)\t\(.app_id // "?") — \(.title // "")"' --args "${ids[@]}")
    [ -n "$menu" ] && menu+=$'\n'

    unlock
    sel=$(printf '%s' "$menu" | fuzzel --dmenu --prompt "Restaurar: " --with-nth 2 --accept-nth 1 2>/dev/null || true)
    [ -n "$sel" ] || exit 0
    read -r id _ <<<"$sel"
    lock
    # Mientras el menu estaba abierto otra orden pudo restaurarla ya.
    stack_line "$id" || exit 0
    ws_id=${line#*$'\t'}
    ws_id=${ws_id%%$'\t'*}
    [ -n "$ws_id" ] || exit 0
    # La foto de antes del menu ya no vale.
    snapshot
    restore_window "$id" "$ws_id"
}

list() {
    prune
    local l
    while IFS= read -r l || [ -n "$l" ]; do
        printf '%s\n' "$l"
    done <"$STACK"
}

# Restaura una ventana concreta si esta minimizada; si no lo esta, no hace nada.
restore_id() {
    local line ws_id
    stack_line "$1" || exit 0
    ws_id=${line#*$'\t'}
    ws_id=${ws_id%%$'\t'*}
    snapshot
    restore_window "$1" "$ws_id"
}

# Saca de la pila una ventana que ya no existe.
forget() {
    local line
    stack_line "$1" || exit 0
    stack_remove "$1"
    release_stash_if_empty
}

case "${1:-}" in
    minimize|minimize-id|restore|restore-id|forget|pick|list) lock ;;
esac

case "${1:-}" in
    minimize)    minimize_id ;;
    minimize-id) minimize_id "${2:?falta id}" ;;
    restore)    restore_last ;;
    restore-id) restore_id "${2:?falta id}" ;;
    forget)     forget "${2:?falta id}" ;;
    pick)       pick ;;
    list)       list ;;
    *) echo "uso: $0 {minimize|minimize-id ID|restore|restore-id ID|forget ID|pick|list}" >&2; exit 2 ;;
esac
