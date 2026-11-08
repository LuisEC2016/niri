#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Selecciona el perfil de power-profiles-daemon segun la fuente de energia.
#
# Por que existe: nadie mas lo hace. En GNOME el gnome-settings-daemon baja a
# power-saver al desconectar y lo restaura al enchufar; bajo niri no hay nada
# equivalente, asi que el perfil se queda en el ultimo valor puesto a mano —
# indefinidamente, y sobrevive al reinicio.
#
# Lo que costaba quedarse en power-saver, medido en este equipo (i7-13620H,
# enchufado, openssl speed -multi 16 -evp aes-256-gcm, bloque de 16 KiB):
#
#     power-saver   16.0 GB/s    frecuencia media de los 16 hilos: 1100 MHz
#     performance   45.7 GB/s    frecuencia media de los 16 hilos: 3225 MHz
#
# 2.85x en multihilo. En un solo hilo no hay diferencia (7.04 vs 7.02 GB/s):
# HWP deja llegar a 4700 MHz un core aislado incluso con EPP=power. El castigo
# es solo sobre la carga que usa todos los nucleos — compilar, ffmpeg, tests.
#
# Politica:
#   enchufado          -> performance   (EPP=performance)
#   bateria            -> balanced      (EPP=balance_performance)
#   bateria < 15%      -> power-saver   (EPP=power)
#
# Para desactivar:  systemctl --user disable --now power-profile-auto.service
# ─────────────────────────────────────────────────────────────────────────────

UMBRAL_BATERIA_BAJA=15
INTERVALO=5

# sysfs no soporta inotify, asi que no sirve una unidad .path ni inotifywait:
# hay que sondear. Cada ciclo son dos lecturas de /sys y una comparacion.
ruta_ac() {
    for d in /sys/class/power_supply/*/; do
        [ "$(cat "$d/type" 2>/dev/null)" = "Mains" ] || continue
        echo "$d/online"
        return
    done
}

capacidad_bateria() {
    for d in /sys/class/power_supply/*/; do
        [ "$(cat "$d/type" 2>/dev/null)" = "Battery" ] || continue
        cat "$d/capacity" 2>/dev/null
        return
    done
    echo 100
}

perfil_deseado() {
    if [ "$(cat "$AC" 2>/dev/null)" = "1" ]; then
        echo performance
    elif [ "$(capacidad_bateria)" -lt "$UMBRAL_BATERIA_BAJA" ]; then
        echo power-saver
    else
        echo balanced
    fi
}

AC=$(ruta_ac)
if [ -z "$AC" ]; then
    echo "sin adaptador de red en /sys/class/power_supply: nada que vigilar" >&2
    exit 1
fi

anterior=""
while :; do
    quiero=$(perfil_deseado)
    # Solo se escribe cuando cambia el veredicto, no cuando cambia el perfil:
    # asi un cambio manual (la tecla XF86Launch1 -> `dms ipc call powerprofile
    # cycle`) aguanta hasta que se enchufe o desenchufe el cargador.
    if [ "$quiero" != "$anterior" ]; then
        if powerprofilesctl set "$quiero" 2>/dev/null; then
            echo "perfil -> $quiero"
            anterior="$quiero"
        fi
    fi
    sleep "$INTERVALO"
done
