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
  ya pinta la suya) y el vigilante que restaura una ventana minimizada al
  pulsarla en el dock.

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

## Fuera del repo

- Se instalan aparte: `ssm-tray` (lo arranca `config.kdl`) y lo que usan los
  scripts: `jq`, `pactl`, `inotifywait`, `notify-send`, `powerprofilesctl`.
- `sony-wf-c710n-autoswitch.service` no tiene que ver con niri y no está aquí.
