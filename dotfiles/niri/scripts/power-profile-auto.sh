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
#
# Uso:  power-profile-auto.sh              vigila y aplica (lo lanza la unidad)
#       power-profile-auto.sh --comprobar  sale 0 solo si hay algo que vigilar
# ─────────────────────────────────────────────────────────────────────────────

UMBRAL_BATERIA_BAJA=15

# Por eventos, no por sondeo. `upower --monitor` escribe una linea cada vez que
# upowerd ve un cambio (cargador conectado o desconectado, % de bateria), y el
# bucle duerme en `read` hasta entonces. La version anterior leia sysfs cada
# 5 s porque sysfs no admite inotify: 17 000 vueltas al dia con un fork de
# `sleep` y varios de `cat` cada una (coreutils en Rust: ~8 MB por proceso), y
# hasta 5 s de retraso al desenchufar. upowerd ya sondea la bateria por su
# cuenta; aqui solo se escucha su resultado.

# Rutas de sysfs, resueltas una vez. Luego se leen con el builtin `read`, sin
# fork. Se ignoran las baterias con scope=Device: son las de ratones y
# teclados inalambricos (hidpp_battery_*), no la del equipo.
AC="" BAT=""
for d in /sys/class/power_supply/*; do
    tipo="" scope=""
    read -r tipo 2>/dev/null <"$d/type" || continue
    read -r scope 2>/dev/null <"$d/scope"
    [ "$scope" = "Device" ] && continue
    case "$tipo" in
        Mains)   [ -n "$AC" ] || AC="$d/online" ;;
        Battery) [ -n "$BAT" ] || BAT="$d/capacity" ;;
    esac
done

# Sin cargador (equipo de sobremesa) o sin las herramientas no hay nada que
# hacer. La unidad lo usa como ExecCondition: el servicio se salta sin quedar
# en fallo y sin reintentos.
comprobar() {
    [ -n "$AC" ] && command -v upower >/dev/null && command -v powerprofilesctl >/dev/null
}

if [ "${1:-}" = "--comprobar" ]; then
    # 1 explicito: ExecCondition salta la unidad con 1..254, pero 255 la falla.
    comprobar && exit 0
    exit 1
fi
if ! comprobar; then
    echo "sin cargador, upower o powerprofilesctl: nada que vigilar" >&2
    exit 0
fi

anterior=""

# Solo se escribe cuando cambia el veredicto, no cuando cambia el perfil: asi
# un cambio manual (la tecla XF86Launch1 -> `dms ipc call powerprofile cycle`)
# aguanta hasta que se enchufe o desenchufe el cargador.
# Si powerprofilesctl falla (polkit aun sin sesion activa al entrar), devuelve
# error y el script sale: con eventos no hay una vuelta siguiente que lo
# reintente, asi que reintenta systemd (Restart=on-failure, con limite).
evaluar() {
    online=0 capacidad=100
    read -r online 2>/dev/null <"$AC"
    [ -z "$BAT" ] || read -r capacidad 2>/dev/null <"$BAT"

    if [ "$online" = 1 ]; then
        quiero=performance
    elif [ "$capacidad" -lt "$UMBRAL_BATERIA_BAJA" ] 2>/dev/null; then
        quiero=power-saver
    else
        quiero=balanced
    fi

    [ "$quiero" = "$anterior" ] && return 0
    powerprofilesctl set "$quiero" || return 1
    echo "perfil -> $quiero"
    anterior=$quiero
}

evaluar || exit 1
upower --monitor | while read -r _; do
    evaluar || exit 1
done
echo "upower --monitor termino (upowerd reiniciado?)" >&2
exit 1
