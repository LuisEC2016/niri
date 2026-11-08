# Escritorio propio sobre niri

Todo lo que cambia este fork respecto a niri upstream, y la configuración del
escritorio que corre encima: niri + DankMaterialShell (DMS) con dock, OSD y
centro de control estilo macOS.

```sh
dotfiles/install.sh --dry-run   # ver qué haría, sin tocar nada
dotfiles/install.sh             # config + shell DMS + compilar e instalar niri
dotfiles/install.sh config      # solo una parte: config | dms-shell | niri
```

## Qué hay y dónde vive

| En el repo | Se instala en | Cómo |
|---|---|---|
| `src/handlers/xdg_shell.rs` | `/usr/local/bin/niri` | compilado |
| `src/layout/floating.rs` | `/usr/local/bin/niri` | compilado |
| `dotfiles/niri/config.kdl`, `custom/*.kdl`, `scripts/*.sh` | `~/.config/niri/` | enlace simbólico |
| `dotfiles/matugen/templates/niri-futurista.kdl` | `~/.config/matugen/templates/` | enlace simbólico |
| `dotfiles/matugen/config.toml` | `~/.config/matugen/` | copia (rutas absolutas) |
| `dotfiles/dms/settings.json`, `plugin_settings.json` | `~/.config/dms/` | copia (DMS los reescribe) |
| `dotfiles/dms-shell/patches/*.patch` | `~/.local/share/dms-shell-custom/` | `dms-shell/build.sh` |
| `dotfiles/systemd/user/…` | `~/.config/systemd/user/` | copia |

Los enlaces hacen que editar `~/.config/niri/config.kdl` sea editar el repo:
`git diff` enseña el cambio y niri recarga al guardar igual que antes (resuelve
los `include` respecto a `~/.config/niri`, no respecto al destino del enlace).

No se versionan porque se generan solos: `~/.config/niri/dms/*.kdl` (DMS),
`~/.config/niri/dms-theme-sync.kdl` (plugin dmsThemeSync) y
`~/.config/niri/custom/futurista.kdl` (matugen, desde la plantilla). Por eso
`config.kdl` los incluye con `optional=true`: en una instalación limpia niri
arranca sin ellos y los carga en cuanto DMS los escribe.

## Cambios en el código de niri

- **Botón de minimizar** (`src/handlers/xdg_shell.rs`). niri deja
  `minimize_request` sin implementar, así que el botón de minimizar de las
  decoraciones del cliente no hacía nada. Ahora llama a
  `~/.config/niri/scripts/niri-minimize.sh minimize-id <id>`, que aparca la
  ventana en el workspace `min` y recuerda de dónde venía. La ruta va fija en el
  código: el script tiene que estar instalado (`install.sh config`).
- **Ventanas flotantes hasta el borde** (`src/layout/floating.rs`). Upstream
  obliga a dejar en pantalla un cuarto de la ventana (hasta 75 px, cifras de
  Mutter). Aquí basta una franja de 10 px dentro del área de trabajo, no de la
  salida entera: la barra es una capa encima de las ventanas y una franja debajo
  de ella no se podría agarrar.

Antes vivían como parches sueltos en `~/.config/niri/patches/` aplicados sobre
v26.04 en `~/.local/src/niri`; ese directorio queda obsoleto.

## Dock estilo macOS (DMS, no niri)

El dock lo dibuja DankMaterialShell, no niri. Lo que lo hace "estilo macOS" son
dos parches QML sobre DMS y unos ajustes:

- `dms-shell/patches/03-dock-macos-magnify.patch`: magnificación al pasar el
  puntero. Cada icono se escala por su distancia al cursor con caída coseno y
  empuja a los vecinos.
- `dms-shell/patches/01-dock-launch-bounce.patch`: rebote al lanzar una app.
- `dms/settings.json`: `appsDockEnlargeOnHover`, `appsDockEnlargePercentage`
  (145), `dockAutoHide`, `dockSmartAutoHide`, `dockIconSize` (52),
  `dockTransparency`, `dockBorder*`, `dockShowTrash`, iconos `WhiteSur-purple`.
- `niri/config.kdl`: `layer-rule` que quita la sombra de niri a `dms:dock` (DMS
  ya pinta la suya).
- `niri/scripts/niri-minimize-watch.sh`: restaura una ventana minimizada al
  pulsarla en el dock. Solo corre mientras hay alguna minimizada.

El resto de parches: `05` OSD de volumen y brillo estilo macOS, `06` centro de
control estilo macOS, `02` caché del mapa de categorías del lanzador, `04`
`07` `08` `09` `10` notificaciones.

`dms-shell/build.sh` clona DMS **v1.6.0** (commit `0bbe8338`), aplica los
parches e instala el resultado en `~/.local/share/dms-shell-custom`, que
`systemd/user/dms.service.d/override.conf` pasa a DMS con `DMS_SHELL_DIR`.
`build.sh --check` reconstruye en un temporal y lo compara con lo instalado.

La base va fijada a propósito. El antiguo `.patches/resync.sh` la copiaba de
`/usr/share/quickshell/dms/quickshell`, que sigue al paquete del sistema; el
paquete ya está en 2.1.1, con otra estructura de archivos, y los parches no
aplican sobre ella. Pasar a una versión nueva de DMS es portar los parches a
mano y cambiar `DMS_TAG`/`DMS_COMMIT` en `build.sh`.

## Procesos: ninguno al arrancar, cada uno cuando hace falta

`config.kdl` no tiene `spawn-at-startup`. Lo que la sesión necesita arranca
bajo demanda o como unidad de systemd que se salta donde no aplica, así que el
mismo repo se instala en otro equipo sin arrastrar arreglos de este:

| Qué | Cuándo corre | Fuera de este equipo |
|---|---|---|
| `niri-minimize-watch.sh` | desde que se minimiza una ventana hasta que no queda ninguna | igual |
| `power-profile-auto.service` | toda la sesión, dormido hasta un evento de `upower --monitor` | se salta sin batería ni `powerprofilesctl` |
| `audio-init.service` | una vez al entrar, y sale | se salta si la placa no es MS-15H4 |
| `ssm-tray.service` | toda la sesión | se salta si no está `~/.local/bin/ssm-tray` |

Antes, con la sesión en reposo: el vigilante de minimizar vivía siempre (bash
+ `niri msg event-stream`, ~20 MB) y lanzaba dos `jq` y el helper en cada
cambio de foco; el perfil de energía leía sysfs cada 5 s con forks de `sleep`
y `cat` (coreutils en Rust: ~8 MB por proceso). Medido el 2026-11-07.

## Fuera del repo

- Se instalan aparte: `ssm-tray` y lo que usan los scripts: `jq`, `pactl`,
  `notify-send`, `fuzzel`, `upower`, `powerprofilesctl`, `python3`
  (`toggle-touchpad.sh`), `setsid` y `flock` (util-linux).
- `sony-wf-c710n-autoswitch.service` no tiene que ver con niri y no está aquí.
  WirePlumber 0.5 ya hace ese cambio de perfil A2DP/HFP él solo
  (`bluetooth.autoswitch-to-headset-profile`, activo por defecto).
