# Cuando el escritorio está roto

Firmas de falla, cada una pagada con tiempo. Cada entrada va *primero el
síntoma*, porque es lo que tienes cuando empiezas.

## Lee esto antes de teorizar

    ergon-doctor                                  # salud de la máquina
    ergon-lint                                    # trampas estáticas en el repositorio
    tail -40 $XDG_RUNTIME_DIR/hypr/*/hyprland.log # EL log del compositor
    journalctl --user -b -p warning

**El log del compositor no está donde crees.** Hyprland escribe en
`$XDG_RUNTIME_DIR/hypr/<signature>/hyprland.log`. El stdout de lo que lo lanzó
está vacío, así que mirarlo no da ninguna pista, que es exactamente lo que pasó
la primera vez.

Un directorio de instancia existe apenas Hyprland arranca, así que "el socket
está ahí" no significa "levantó".

---

## Ningún atajo hace nada, y Hyprland dice que SUPER + Q es todo lo que hay

    Emergency mode tripped: A lua config error resulted in no binds being
    registered. Emergency binds active: SUPER + Q

**Ese mensaje es de Hyprland, no de este repositorio.** Significa que la
configuración Lua lanzó un error antes de que corriera un solo `hl.bind`, así
que nada se registró y el compositor recurrió a una configuración incorporada en
el binario. Anuncia un bind e instala tres en realidad:

| acorde | a qué lo asocia el binario |
|---|---|
| SUPER + Q | el primero de kitty, alacritty, **foot**, wezterm, gnome-terminal, xterm que esté instalado |
| SUPER + R | `hyprland-run` |
| SUPER + M | salir del compositor |

`foot` está en `packages/pacman`, así que **SUPER + Q te da una terminal**.
Úsala antes de buscar una TTY.

### Leerlo

    hyprctl configerrors
    tail -60 $XDG_RUNTIME_DIR/hypr/*/hyprland.log

La forma del error te dice de qué tipo es, y **cuenta entradas, no líneas**:
cada problema de configuración que Hyprland registra es UNA entrada impresa como
una línea `file:line: message`; cinco claves malas imprimen cinco líneas. Los
errores de Lua son la excepción, y esa excepción es todo el diagnóstico:

- **dos docenas de líneas de `no file '.../common/<name>.lua'`**: el "module not
  found" de Lua, que es UNA entrada cuyo texto lista cada ruta que probó (27
  líneas desde un require de nivel superior, 24 desde uno dentro de otro
  módulo). Falta un archivo.
- **`cannot open .../hyprland.lua: No such file or directory`**: el punto de
  entrada mismo desapareció, así que no corrió nada de Lua. En una máquina donde
  `~/.config/hypr` es un enlace simbólico hacia el checkout, eso significa que el
  checkout está en medio de un reemplazo.
- **dos líneas que nombran un archivo y un número de línea**: un error de
  sintaxis, o un valor que Hyprland rechazó, en un archivo que sí está.
- **N líneas `file:line:` separadas**: N problemas genuinamente distintos. Eso
  *no* es un módulo faltante, y si viene con cero binds entonces algo en
  `common.env` o `common.looknfeel` falló en muchas claves Y lanzó un error duro
  de Lua antes de llegar a `common.binds`.

`debug:error_limit` limita cuántos se muestran, así que una lista larga en
pantalla puede aparecer truncada con un "... more"; `hyprctl configerrors` es la
completa.

### Arreglarlo

Nueve de cada diez veces el archivo faltante es `hypr/common/looknfeel.lua`: es
el único archivo de la cadena de require del compositor que es **generado y está
en gitignore**, así que es el único que puede faltar en una máquina que tiene el
repositorio. Desaparece cuando falla un renderizado, en un clon nuevo o un `git
worktree` antes de que haya corrido `install.sh`, y (antes del 2026-09-24)
mientras el arnés de la VM reemplazaba el checkout bajo una sesión viva.

    ergon theme                                   # volver a renderizar la paleta
    ls -l ~/.config/hypr/common/looknfeel.lua     # debe existir
    hyprctl reload                                # Hyprland lee la configuración UNA vez

El reload no es opcional ni cosmético: arreglar el archivo en disco no hace
absolutamente nada al compositor en ejecución, que lo leyó al arrancar y no
volverá a mirar.

Desde el 2026-09-24 `hypr/hyprland.lua` carga cada módulo mediante `need()`, que
usa pcall, y carga `common.binds` segundo, de modo que un archivo generado
faltante te cuesta el tema y no el teclado. Si estás en modo de emergencia en
`main` actual, **no** es un `looknfeel.lua` faltante: lee el error, porque algo
en `common.env` o en el propio `common.binds` está roto.

---

## El escritorio es solo el color de fondo, y hyprpaper hace segfault

    coredumpctl list hyprpaper     # segfault en libhyprtoolkit

hyprpaper dibuja con GL. Sin un GL que funcione (una VM sin render node, un
driver roto) se cae al arrancar. `ergon-wallpaper` lo maneja: sin
`/dev/dri/renderD*`, o cuando hyprpaper muere en pocos segundos, ejecuta `swaybg`
en su lugar (CPU, wl_shm) y sigue usándolo durante la sesión (marcador
`$XDG_RUNTIME_DIR/ergon-wallpaper-swaybg`). `ergon-doctor` lo muestra como ok,
con la razón. Si ninguno dibuja, revisa `pgrep -a swaybg` y que `swaybg` esté
instalado.

## Los clics no hacen nada, pero la barra se ve bien

Dos causas independientes, y fueron ambas a la vez:

**Los botones de espacios de trabajo se resaltan pero no cambian.** waybar
0.15.0 envía la cadena clásica `dispatch workspace 3`, y un Hyprland configurado
con Lua la parsea como Lua y falla. Instala `waybar-git` (ver `packages/aur`).
Corregido en upstream en Alexays/Waybar#5013, aún no en un release etiquetado.

**Un módulo se dispara y no pasa nada.** Su `on-click` no está en el PATH de la
sesión. La pista: bluetooth funciona y nada más lo hace, porque su manejador es
`blueman-manager`, un binario real, mientras que el resto llama a
`ergon-launch-tui`. La causa casi siempre es que `environment.d/10-ergon-path.conf`
no está enlazado: `install.sh` lo hace, y una máquina donde las configuraciones
se copiaron a mano nunca lo recibió.

    ls -l ~/.config/environment.d/10-ergon-path.conf
    systemctl --user show-environment | grep PATH

## El greeter acepta la contraseña y vuelve al greeter

`/etc/greetd/config.toml` debe ejecutar la sesión como lo hace el archivo desktop
del paquete:

    command = "tuigreet ... --cmd 'uwsm start -e -D Hyprland hyprland.desktop'"

`uwsm start -S hyprland-uwsm.desktop` está doblemente mal: `-S` no es una bandera
de uwsm, y `hyprland-uwsm.desktop` **es** el lanzador de uwsm, así que le pide a
uwsm que inicie uwsm. greetd autentica y luego ejecuta sinsentidos.

Ten en cuenta que el paquete greetd distribuye su propio `config.toml`, así que
"el archivo existe" no prueba nada. Busca con grep `tuigreet` y el comando de
arriba.

## "La cuenta está bloqueada"

`pam_faillock`. Arch usa por defecto `deny=3`, `unlock_time=600`, así que tres
errores de tipeo durante una sesión de depuración te dejan fuera diez minutos.

    faillock --user <name> --reset

`/etc/security/faillock.conf` se aprovisiona con `deny = 10`,
`unlock_time = 120`.

## SUPER+RETURN no hace nada

`wezterm` es una compilación **git** de AUR y es el paquete con más
probabilidades de faltar o estar en medio de una recompilación: el
aprovisionamiento lo omite con `ERGON_SKIP_AUR=1`. `ergon-term` recurre a foot
automáticamente. `SUPER+SHIFT+ALT+RETURN` es la vía de escape explícita y nombra
foot directamente, para cuando wezterm está presente pero roto.

## Nunca aparece una ventana al hacer clic en un módulo de la barra

`ergon-launch-tui` pasa por `uwsm-app` solo cuando hay una unidad de sesión uwsm
activa, y recurre a un exec simple en caso contrario. Fuera de una sesión uwsm
`uwsm-app` falla y la ventana nunca aparece, lo que desde la barra es
indistinguible de que el clic no se registre.

## Un prompt de polkit que ninguna contraseña responde

La sesión se inició a mano en vez de por logind, así que polkit no ve ninguna
sesión local activa. No es una credencial equivocada. No ocurre en hardware real,
donde greetd da una sesión propiamente tal, solo en un arnés que inicia el
compositor directamente.

## Discord pide iniciar sesión después de cada sesión

O VS Code dice que el cifrado no está disponible y que no se pudo identificar un
llavero del SO, o un diálogo **Unlock Keyring** aparece frente a la primera app
Electron que inicias. Dos mitades. ERGON-64: Chromium no conoce "Hyprland" como
escritorio y guarda la clave en texto plano o en memoria, a menos que
`GNOME_DESKTOP_SESSION_ID` esté fijada; `uwsm/env-hyprland.d/ergon-keyring` la
fija, **vacía**. ERGON-123: el llavero que entonces usa nunca debe necesitar
desbloqueo. El aprovisionamiento crea `Default_keyring`, que no tiene contraseña,
y apunta el alias `default` a él antes de que cualquier app pueda pedirle a
gnome-keyring que cree uno (esa petición es en sí un diálogo de contraseña). Nadie
escribe una contraseña de inicio de sesión al arrancar, así que nada podría
desbloquear uno protegido con contraseña.

    systemctl --user show-environment | grep GNOME_DESKTOP_SESSION_ID  # presente, vacía
    cat ~/.local/share/keyrings/default            # Default_keyring
    ls ~/.local/share/keyrings/                    # Default_keyring.keyring, sin login.keyring
    grep pam_gnome_keyring /etc/pam.d/greetd /etc/pam.d/passwd  # nada (ver abajo)
    ergon doctor | grep keyring                    # unlocked
    <app> --enable-logging=stderr --vmodule=key_storage_util_linux=1 2>&1 \
      | grep 'Password storage detected desktop environment'   # GNOME, no (unknown)
    #   para code agrega --verbose, o esto no imprime nada, esté arreglado o no
    secret-tool search --all application <app>     # su clave: discord, code-oss, ...

Encuentra la clave por `application`, no por etiqueta: todas llevan la etiqueta
`Chromium Safe Storage`.

- **El primer comando no imprime nada.** La sesión no se inició mediante uwsm (la
  entrada simple "Hyprland" de tuigreet, una TTY, ssh), o
  `~/.config/uwsm/env-hyprland.d/ergon-keyring` no está enlazado: `install.sh`
  lo hace, y deja tu propio `env-hyprland` en paz.
- **Imprime un valor.** Debe seguir vacía: un valor hace que cada script de
  xdg-utils decida que esto es GNOME, y entonces `xdg-open <dir>` falla. Y no en
  `environment.d`, cuyo generador descarta una asignación vacía con una línea en
  el journal y nada más.
- **`default` nombra `login`.** Una máquina instalada antes de ERGON-123 que
  todavía inicia sesión en el greeter (`AUTOLOGIN=0`) conserva su llavero login, y
  el aprovisionamiento mantiene las líneas `pam_gnome_keyring` de ERGON-64 en
  `/etc/pam.d/greetd` y `passwd` para desbloquearlo con tu contraseña. Si esa
  máquina activa `AUTOLOGIN=1`, nada desbloquea login: vuelve a ejecutar el
  aprovisionamiento (deja Default_keyring como el predeterminado), luego aparta
  `~/.local/share/keyrings/login.keyring` una vez que sus secretos ya no se
  necesiten.
- **El diálogo pide crear un llavero.** No había uno por defecto cuando una app
  preguntó. Vuelve a ejecutar `bin/provision-arch.sh`, o a mano: un archivo de
  llavero sin cifrar `~/.local/share/keyrings/Default_keyring.keyring` y
  `Default_keyring` en `~/.local/share/keyrings/default`, luego cierra sesión y
  vuelve a entrar.

Efecto secundario, por diseño: con la variable fijada, Chromium toma su proxy de
gsettings `org.gnome.system.proxy` e ignora `http_proxy` y `https_proxy`.

## El arranque: una contraseña, luego el escritorio

Instalaciones desde ERGON-123 en adelante: systemd-boot en la ESP sin cifrar
inicia una UKI (`/efi/EFI/ergon/linux.efi`), Plymouth dibuja el prompt de la
contraseña desde el initramfs, sd-encrypt desbloquea la raíz, y el
`initial_session` de greetd inicia Hyprland mediante uwsm sin greeter. Al cerrar
sesión llegas a tuigreet. Las instalaciones más antiguas arrancan GRUB, con
`/boot` dentro de LUKS, hasta que se migran (opcional, BOOT_MIGRATE=1)
(`ergon-boot-migrate check` dice si se puede, y por qué no). Una instalación con
`ENCRYPT=0` (`/etc/ergon/install.env`) no tiene el hook sd-encrypt ni `rd.luks`
en la línea de comandos: `root=UUID=...` es el propio sistema de archivos btrfs,
y Plymouth muestra el splash sin prompt.

    bootctl status                                 # systemd-boot, la entrada arrancada
    ergon-boot-entries list                        # el menú: ergonOS, snapshots, linux-lts
    cat /etc/kernel/cmdline                        # la línea de comandos que lleva cada UKI
    ergon-plymouth status                          # la paleta del splash
    sed -n '/initial_session/,$p' /etc/greetd/config.toml   # inicio de sesión automático
    ergon doctor | grep -E 'bootloader|snapshot-menu|boot-splash|autologin'

- **Un parámetro del kernel no surte efecto.** Va en `/etc/kernel/cmdline`, luego
  `sudo mkinitcpio -P`: la UKI lleva la línea de comandos, así que editar las
  entradas del loader no hace nada por la entrada principal.
- **Sin splash, texto del kernel en su lugar.** Falta `splash` en la línea de
  comandos, o el hook `plymouth` en `HOOKS` de `/etc/mkinitcpio.conf` (va justo
  después de `systemd`). En NVIDIA, Plymouth necesita los módulos del driver
  temprano (`ergon-gpu`); sin ellos recurre a texto, y el prompt igual funciona.
- **El splash tiene la paleta equivocada.** Sigue a `ergon theme` solo donde sudo
  no pide contraseña; en otro caso, en el próximo `ergon sync`, o ahora:
  `ergon-plymouth install`.
- **Un snapshot no está en el menú.** La unidad path (ergon-boot-entries.path)
  debería estar activa; `sudo ergon-boot-entries sync` las escribe a mano. Solo
  las ocho más nuevas reciben entradas, más la conocida como buena del guardián de
  arranque, de modo que la ESP no se llene.
- **Quieres de vuelta el prompt de contraseña.** `AUTOLOGIN=0` en
  `hosts/<host>/host.env`, luego `ergon sync`. En una raíz sin cifrar que no se
  instaló con `ENCRYPT=0`, `ergon doctor` advierte sobre el inicio de sesión
  automático.
- **Revertir una instalación sin cifrar.** `ergon-rollback` encuentra por sí mismo
  la partición raíz desde un arranque de snapshot; desde la ISO de Arch, nómbrala:
  `ergon-rollback --device /dev/nvme0n1p2 --list`.
- **El menú no aparece.** Se muestra durante dos segundos (`timeout` en
  `/efi/loader/loader.conf`); presiona cualquier tecla mientras se muestra para
  detener la cuenta regresiva.

## git por SSH pide la contraseña de la clave cada vez

La sesión corre el agente propio de openssh (`ssh-agent.socket`, una unidad de
usuario, iniciada en el primer uso) y `uwsm/env-hyprland.d/ergon-ssh-agent`
exporta `SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent.socket` al compositor y al
gestor de usuario. La fila `ssh-agent` de `ergon doctor` dice qué mitad falta.

    systemctl --user show-environment | grep SSH_AUTH_SOCK   # debe imprimir la ruta
    systemctl --user status ssh-agent.socket                  # listening
    ssh-add -l                                                # 1 = alcanzable, aún sin claves

- **Sin SSH_AUTH_SOCK**: no es un inicio de sesión uwsm, o el drop-in no está
  enlazado (`install.sh` lo enlaza); vuelve a iniciar sesión tras `ergon update`.
- **Alcanzable pero aun así pregunta**: el agente parte vacío. `install.sh` escribe
  `~/.ssh/config.d/ergon.conf` (`Host *` / `AddKeysToAgent yes`) y agrega un
  bloque marcado `Match all` + `Include` al FINAL de `~/.ssh/config` (`Match all`
  restablece el ámbito para que el Include sea global; al ir último solo aporta un
  valor por defecto, así que tu propio `AddKeysToAgent no` anterior por host
  gana). Comprueba con `ssh -G somehost | grep addkeystoagent` (debe decir
  `true`). Tu archivo, por lo demás, nunca se edita; hay una copia en
  `config.ergon-backup`.
- **Crear o cargar una clave**: `ergon ssh-key new [NAME]` (ed25519, contraseña,
  cargada, clave pública impresa y copiada), `add PATH`, `list`, `copy [NAME]`.
- **Otro agente**: un login `ssh` que reenvía uno, o `gcr-ssh-agent` /
  `gpg-agent --enable-ssh-support`, responde en su lugar; corre un solo agente.

## Mantener una letra la repite, y no aparece el popup de acentos

Los acentos de mantener presionado son fcitx5 más el addon omacento (ERGON-79).
Encuentra qué eslabón falta, en este orden:

    pgrep -a fcitx5                                       # ¿corre siquiera?
    grep -c libomacento /proc/$(pgrep -x fcitx5)/maps     # 0: el addon no está cargado
    pacman -Q fcitx5-omacento                             # ¿instalado?
    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
      --method org.fcitx.Fcitx.Controller1.DebugInfo      # focus:1 = esta ventana lo alcanzó

- **Sin fcitx5.** `hypr/common/autostart.lua` lo inicia con la sesión; un
  compositor iniciado de otra forma no lo hizo. `fcitx5 -d --replace` lo inicia a
  mano. No pruebes primero con una llamada D-Bus: una inicia un fcitx5 por
  activación, fuera de la sesión, y ese responde.
- **Corriendo, sin libomacento.** Falta el paquete o falló su compilación: se
  construye desde `packages/pkgbuild/fcitx5-omacento` durante el
  aprovisionamiento, y el log dice por qué. `ergon aur --rebuild fcitx5-omacento`,
  luego `fcitx5 -d --replace`.
- **Cargado, pero esta ventana no está en focus:1.** La aplicación no está
  hablando con un método de entrada. Una app Chromium o Electron necesita
  `--enable-wayland-ime` en su línea de comandos (Discord lo recibe de su entrada
  del lanzador, `~/.local/share/applications/discord.desktop`); una app Qt
  necesita `QT_IM_MODULE=fcitx`, que solo tiene una sesión iniciada mediante el
  propio entorno de Hyprland. Los campos de contraseña se excluyen a propósito.
- **focus:1, y aun así nada.** `ergon accents` dice si está apagado, o si la clase
  de esta ventana está omitida, y si el fcitx5 en ejecución tiene lo que dice
  (`fcitx5 -d --replace` si no). `ergon accents unskip` en la propia ventana, o
  `ergon accents on`.

El popup lo dibuja fcitx5, posicionado por el compositor; el acento se confirma
se haya podido ver o no, así que un dígito tras mantener escribe el acento aunque
falte el popup.

---

## En una VM

**Pantalla negra sobre VNC, compositor aparentemente bien.** `virtio-gpu-pci` da
al invitado un dispositivo DRM sin scanout VGA, así que qemu no tiene nada que
mostrar. Usa `-device virtio-vga`.

**Los clics caen en otro lugar que el cursor.** El mouse PS/2 por defecto es un
dispositivo *relativo* y VNC solo envía coordenadas absolutas. Agrega `-device
qemu-xhci -device usb-tablet`.

**`grim` se cuelga.** Captura todas las salidas y se bloquea para siempre en una
que nunca presenta un cuadro bajo renderizado por software. Captura una: `grim -o
<monitor>`.

**`EGL_BAD_ALLOC ... createImageFromDmaBufs failed` inundando el log.** La GPU
emulada no tiene ruta dmabuf. El renderizado recurre a software. La distribución,
el color y el comportamiento son exactos; la fluidez no, y las capturas de
pantalla no funcionan. No es un error del escritorio.

**`Cmd+Space` nunca llega al invitado desde un Mac.** macOS lo toma para
Spotlight antes de que Screen Sharing lo reenvíe, y lo toma incluso cuando
Spotlight no se abre visiblemente. Prueba primero con `SUPER+RETURN` para
confirmar que las teclas llegan siquiera.

---

## Paquetes

**Un paquete AUR se compila y luego no se instala.** Entra en conflicto con un
paquete de repo, pacman pregunta `Remove <x>? [y/N]`, y `--noconfirm` toma el
valor por defecto (No) y luego aborta con "unresolvable package conflicts". La
compilación tuvo éxito, la instalación no, y el único rastro es una línea en un
log. `ergon-aur` despeja primero los conflictos declarados; úsalo en vez de un
`makepkg -si` a secas.

## Recuperar una máquina que no arranca

`ergon-rollback` cambia el subvolumen `@` por un snapshot. **Se niega a correr
desde `@`**: arranca el snapshot desde el menú de arranque (o la ISO de Arch,
luego `cryptsetup open /dev/<disk>p2 cryptroot`), y ejecútalo desde ahí. Tras dos
arranques que nunca llegan al escritorio, el guardián de arranque inicia por sí
mismo el último snapshot conocido como bueno (`ergon-boot-guard status`).
`snapper rollback` no funciona con este esquema y no es la herramienta.

## La suspensión drena la batería, o la máquina no vuelve

Mide antes de cambiar nada. Los workarounds de reanudación se publican por
plataforma, sobre todo como reportes de foros, y la mayoría cuestan a otras
máquinas.

    ergon-sleep check                  # modos de suspensión, tapa, hibernación, último sueño de hardware
    ergon-sleep cycle 5                # suspender 5 veces con alarma RTC, contar las reanudaciones
    ergon-sleep cycle 3 --hibernate    # lo mismo mediante hibernación

- **"never reached hardware sleep":** la suspensión ocurrió, pero el SoC no salió
  de su estado más profundo, así que la batería se drenó como si la tapa
  estuviera abierta. Algo lo mantuvo despierto: un dispositivo, un driver o el
  firmware.
- **Un intento de hibernación informado como "did NOT resume":** la máquina
  arrancó en frío en vez de restaurar. En el Ryzen AI 300 Framework 13 esto se ha
  reportado en algunas versiones de AGESA, con `echo 0 > /sys/power/pm_async`
  como workaround. Es un solo hilo de foro y ralentiza la reanudación en todas
  partes, así que aplícalo solo donde `cycle --hibernate` muestre la falla.
- **El manejo de la tapa se elige, no es fijo.** `ergon-hardware detect` muestra
  si el firmware es solo s2idle y si la hibernación está configurada. Ambas
  juntas significan suspend-then-hibernate; cualquier otra cosa mantiene el valor
  por defecto de logind.

## El Wi-Fi desapareció y no vuelve

`pcie_aspm.policy=powersupersave` en la línea de comandos del kernel hace que el
MediaTek MT7925 (en la tarjeta AMD RZ717) falle con "driver own failed" hasta que
la máquina se apague por completo. Un reinicio o una recarga del módulo no lo
limpia. No fijes esa política; si está fijada, quítala y apaga.

## Polkit rechaza una acción de escritorio, sin ningún prompt

**Síntoma.** Un botón de la barra, un montaje, o cualquier otra cosa que cambie el
estado del sistema no hace nada en absoluto. Sin error, sin diálogo de
autenticación. Ejecutar el mismo comando en una terminal imprime

    AccessDenied: Not Authorized: <some action id>

mientras `loginctl` insiste en que la sesión es `Active=yes` en `seat0`, la
política dice `implicit active: yes`, y hay un agente de autenticación corriendo.

**Causa.** uwsm corre el compositor como `wayland-wm@hyprland.service` bajo
`user@<uid>.service`, así que todo lo que lanza el escritorio vive en

    /user.slice/user-<uid>.slice/user@<uid>.service/session.slice/...

y **no** en un scope de sesión de logind. `sd_pid_get_session()` falla para esos
procesos, así que polkit los resuelve como *ninguna sesión en absoluto*. Una
acción cuya política dice `implicit inactive: no` es entonces rechazada de plano,
y `no` es un rechazo duro y no una pregunta, por lo que no aparece ningún prompt
del agente.

Cada parte de esto se ve correcta por separado. La sesión realmente está activa;
el proceso simplemente no está en ella.

**Confírmalo con un comando**, desde dentro de la sesión y no mediante `su -`
(que no tiene seat y fallará por otra razón):

    pkcheck --action-id <action id> --process $$   # "Not authorized." = esto

y compara `cat /proc/self/cgroup` con `loginctl list-sessions`.

**Arreglo.** Concede la acción por GRUPO en vez de por actividad de la sesión, en
`/etc/polkit-1/rules.d/`. provision-arch.sh distribuye
`49-ergon-desktop.rules` haciendo exactamente eso para el cambio de perfil de
energía. Añade entradas ahí a medida que se demuestren, no de forma especulativa:
cada una concede la acción sin importar la sesión, lo que incluye ssh.

**No** persigas al agente de autenticación, el archivo de política ni el estado
Active de la sesión. Los tres ya están correctos.

## Un atajo no hace nada, y no puedes saber por qué

Tres causas distintas se presentan idénticas (la tecla no hace nada, sin error,
sin ventana) y necesitan arreglos opuestos. Establece cuál tienes **antes** de
cambiar cualquier configuración. Las tres se encontraron en secuencia en una
tarde, y en el camino se publicaron dos arreglos equivocados.

**1. La tecla nunca llega a la máquina.** Las sesiones remotas se comen los
modificadores. Sobre VNC o RDP el propio escritorio del cliente reclama SUPER
antes de que el invitado lo vea, y en macOS `Option`+letra se compone en un
carácter de tecla muerta en el cliente, así que la letra nunca se transmite en
absoluto: `CTRL+ALT+K` llega como CTRL y ALT y nada más. `RETURN` y las letras
simples sobreviven ese camino; SUPER y ALT+letra no.

**2. La tecla no se puede presionar en este teclado.** `/` es una tecla propia en
una distribución US y `SHIFT+7` en las latinoamericana, española, alemana y
francesa. Un bind en `SLASH` no puede coincidir ahí: el SHIFT que exige la
distribución es un modificador que el bind no lleva. Por eso el atajo de ayuda se
elige desde `hypr/keymap-to-xkb` en vez de fijarse en el código; ver
`hypr/common/layout.lua`.

**3. El bind se dispara y el comando falla en silencio.** Todo lo lanzado desde un
bind no tiene terminal adjunta, así que un script que escribe en stdout no
produce nada visible, y uno que muere bajo `set -e` no produce nada en absoluto.

**Distínguelas midiendo, no razonando.** Lee el dispositivo de teclado
directamente; esto necesita root y ningún paquete adicional:

    cat /dev/input/by-path/platform-i8042-serio-0-event-kbd > /tmp/keys.raw
    # presiona la combinación, luego:
    od -An -tu2 -w24 -v /tmp/keys.raw | awk '$9==1 { print $10, $11 }'

Cada línea es `keycode value` (1 = presionar, 0 = soltar). Códigos útiles:
LEFTCTRL 29, LEFTALT 56, LEFTSHIFT 42, LEFTMETA 125, ENTER 28, SLASH 53, K 37.

- Aparecen los modificadores pero no la letra → causa 1, el cliente. Nada en el
  SO lo arregla; usa un cliente con captura de teclado, o acepta la vía de escape
  `CTRL+ALT+RETURN` y trabaja desde una shell.
- Aparece todo → el compositor lo tiene. `hyprctl binds -j` muestra si el bind
  está registrado, y ejecutar el comando con stdout redirigido a un archivo
  reproduce la causa 3.

**No uses `od` para capturar.** Almacena stdout en búfer cuando es un archivo, así
que una ráfaga corta de pulsaciones nunca llega al disco y la captura se lee como
"ninguna tecla presionada", lo que se ve exactamente como la causa 1 y no lo es.

**`hyprctl keyword` no funciona con una configuración Lua.** Responde "keyword
can't work with non-legacy parsers"; usa `hyprctl eval 'hl.config({ ... })'`.

## El primer escritorio es un degradado, no flame-0

`install.sh` descarga y colorea los fondos aprobados (ERGON-127). Si no pudo
alcanzar la red imprimió un bloque de advertencia, y el escritorio muestra el
degradado hasta que lleguen los campos. El inicio de sesión reintenta en segundo
plano (`ergon-wallpaper-gen --ensure`); para hacerlo ahora:

    ergon-wallpaper-gen --fetch

luego `ergon-wallpaper` (sin archivo de estado significa flame-0; si has elegido
un fondo desde entonces, se queda elegido). La pantalla de bloqueo lo sigue: lee
`~/.local/share/ergon/lock-background.png`, un enlace que `ergon-wallpaper`
mantiene al día.
