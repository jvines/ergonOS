# Concesiones de seguridad que este repositorio hace a propósito

Cada opción de aquí debilita algo para comprar comodidad. Cada entrada dice qué
debilita, qué compra y qué sigue siendo cierto en cualquier caso, de modo que la
decisión sea una que tomaste tú y no una que te pasó por defecto.

## El grupo docker es root sin contraseña

Pertenecer al grupo `docker` permite a cualquier proceso montar `/` con bind y
hacer chroot en él a través del socket. Eso no es "root para el humano frente al
teclado": es root para cada proceso de la sesión: un agente de código que sigue
una instrucción inyectada en un prompt, un `pip install` con un paso de
construcción malicioso, cualquier cosa que alcance `/var/run/docker.sock`. Lo
que derrota es la barrera de la contraseña de sudo, y faillock con ella. LUKS
sigue protegiendo el disco en reposo; esa amenaza es independiente y esto no
cambia nada en ella.

`DOCKER_GROUP=0|1` en `hosts/<host>/host.env`, por defecto 0:

- **0**: el aprovisionamiento nunca añade el grupo. `docker` necesita `sudo`,
  que no requiere ninguna instalación nueva: el propio demonio se habilita
  incondicionalmente de cualquier manera. Docker sin root es la respuesta final
  para un host donde incluso `sudo docker` es demasiado, una vez que la suite de
  la VM muestre compose funcionando bajo delegación de cgroup v2; nada aquí lo
  configura todavía.
- **1**: el aprovisionamiento te añade, y `ergon doctor` advierte en cada
  ejecución nombrando DOCKER_GROUP=1 como la razón, de modo que la concesión
  siga visible en vez de diluirse en "así es esta máquina".

El aprovisionamiento solo AÑADE con esta opción, nunca quita: volverla a 0 no
deshace una membresía concedida cuando estaba en 1, porque un reaprovisionamiento
que quita en silencio el acceso a docker de tu propia sesión es una sorpresa
peor que la que la opción existe para corregir. La comprobación `docker-group` de
`ergon doctor` informa la membresía real de `groups`, no la opinión de host.env,
de modo que una máquina aprovisionada antes de que existiera esta opción, o una
a la que alguien le hizo `usermod` a mano, igual recibe la verdad: DOCKER_GROUP=1
advierte nombrándolo como la concesión elegida, DOCKER_GROUP=0 con membresía de
todos modos advierte como deriva, con el comando `gpasswd -d` para deshacerla.

Esa comprobación lee la membresía con un nombre de usuario explícito (`groups
"$(id -un)"`), no con el `groups` a secas que el aprovisionamiento también usa
internamente. El `groups` a secas responde por los grupos suplementarios en
caché del PROCESO QUE LLAMA desde su último inicio de sesión, no por una
consulta en vivo a `/etc/group`; coreutils lo dice en su propio `--help`. Una
terminal, un panel de tmux o un master de ssh dejados abiertos a través de un
`usermod` harían que doctor se devolviera a sí mismo su propia respuesta
obsoleta: "no está en el grupo", en una máquina donde un proceso nuevo ya lo
tiene.

## sudo es completo y protegido por contraseña; faillock es lo que pasa cuando fallas

`%wheel ALL=(ALL:ALL) ALL`: wheel, que en un notebook de un solo usuario eres
tú, puede ejecutar cualquier cosa como root. No hay NOPASSWD en ninguna parte de
una instalación real; el único lugar donde esa cadena aparece en este
repositorio es `test/arch-vm/*`, escrita dentro de un arnés de VM desechable
para que una ejecución de pruebas con script no necesite que nadie escriba una
contraseña en un pipe. Enviar esa línea a una máquina real sería exactamente el
error que este párrafo existe para que alguien note.

El aprovisionamiento no toca `timestamp_timeout`, así que tampoco se pide cada
vez: el valor por defecto del propio sudo de Arch guarda un éxito en caché por
cinco minutos por tty (`sudo -V` en una instalación nueva lo informa), no una
contraseña en cada invocación. Es la misma concesión que hace el grupo docker de
arriba, solo que más estrecha y acotada en el tiempo: durante cinco minutos
después de escribir la contraseña, cualquier cosa que corra en esa terminal, un
agente de código o un script de compilación incluidos, tiene root mediante sudo
del mismo modo que lo tendría mediante el socket de docker.

El valor por defecto de Arch para la barrera detrás de esa contraseña
(`pam_faillock`, `deny = 3`, `unlock_time = 600`) está pensado para un login
compartido por personas que podrían estar adivinando, y en un notebook de un
solo usuario lo que hace sobre todo es dejar fuera a la única persona que tiene
derecho a estar ahí: tres caracteres mal escritos durante una sesión de
depuración, o manos frías en un observatorio a las 3 am, cuestan diez minutos en
una máquina que ya exigió una contraseña de LUKS para llegar hasta aquí. El
aprovisionamiento escribe `/etc/security/faillock.conf` con `deny = 10`,
`unlock_time = 120`, `fail_interval = 900`: sigue acotado frente a alguien
sentado ante una sesión desbloqueada y sin sesión iniciada, que es la única
amenaza que este control realmente atiende aquí, sin ser lo que te deja fuera de
tu propio notebook. `faillock --user <name> --reset` limpia un bloqueo que aun
así ocurra; ver `ergon explain troubleshooting`.

## Lo entrante se descarta, y Docker publica en localhost

Este notebook se conecta al Wi-Fi de congresos y observatorios, donde todos los
demás hosts de la subred son desconocidos, y hasta ERGON-20 nada filtraba lo
entrante. El aprovisionamiento ahora escribe `/etc/nftables.conf` y habilita
`nftables.service`: una tabla, `inet ergon`, cuya cadena input descarta por
defecto.

Lo que queda abierto, y por qué ninguno es opcional:

- loopback, y todo lo establecido o relacionado, que es lo que hace que sigan
  funcionando las respuestas DNS y cada conexión que abre esta máquina.
- **todo** ICMP e ICMPv6, no una lista de tipos escogidos a mano. Si descartas
  el neighbour discovery de ICMPv6, IPv6 deja de funcionar por completo; si
  descartas packet-too-big, el MTU de la ruta se convierte en agujero negro, lo
  que se presenta como una transferencia que parte, mueve unos pocos KB y luego
  se cuelga para siempre.
- el cliente DHCP, tanto v4 como v6. Conntrack no cubre v4: el cliente interno
  de NetworkManager hace DISCOVER/OFFER sobre `AF_PACKET`, que nunca llega al
  hook input, pero una renovación por rebinding se transmite por broadcast y su
  respuesta no coincide con ninguna entrada de conntrack.
- `tailscale0`, y UDP 41641 para que tailscale pueda conectarse directamente en
  vez de retransmitir por DERP. La tailnet es de confianza; la LAN no. El ssh
  desde la LAN se descarta junto con todo lo demás, que es la respuesta
  buscada: sshd no está habilitado en una instalación nueva, y la flota llega a
  esta máquina por la tailnet.

`ergon ssh-enable` (ERGON-142) es la forma de encender sshd: se niega hasta que
`~/.ssh/authorized_keys` tenga una clave válida, y deja estas reglas intactas,
así que es alcanzable por la tailnet y sigue sin serlo desde la LAN.

La comprobación de portal cautivo (ERGON-129) hace que NetworkManager descargue
`http://ping.archlinux.org/nm-check.txt` en cada conexión y cada cinco minutos.
Es una petición HTTP simple que le dice a archlinux.org que esta IP está en
línea, y es lo que permite a `ergon captive` notar la página de login de un
hotel. Borra `/etc/NetworkManager/conf.d/20-ergon-connectivity.conf` para
desactivarla (la siguiente ejecución del aprovisionamiento la vuelve a escribir).

mDNS (UDP 5353) está abierto, para el descubrimiento de impresoras sin drivers y
para que esta máquina resuelva un nombre `*.local` propio (ERGON-40). Se acota
por DESTINO, no por origen ni por interfaz: un notebook no tiene un nombre fijo
para "la LAN" como `tailscale0` es un nombre fijo para la tailnet. 224.0.0.251 y
`ff02::fb` son grupos multicast de enlace local que ningún router conforme
reenvía más allá del segmento local (RFC 5771; `ff02::` es por definición
ámbito de enlace local en IPv6), así que un paquete que llega al hook input
dirigido a cualquiera de los dos fue necesariamente enviado en la red en la que
esta máquina esté ahora. Una consulta unicast directa a la propia dirección de
este host en el 5353 sigue chocando con la política de descarte con la que
empezó esta sección.

LocalSend (TCP y UDP 53317, ERGON-118) está abierto solo a direcciones de origen
privadas: RFC 1918, link-local, ULA de IPv6 y link-local. Un notebook no tiene
un nombre fijo para "la LAN", así que la regla es por dirección de origen, con
el mismo descarte de interfaces virtuales primero para que un puente de docker o
una VM no se confundan con ella. Una dirección pública se descarta como todo lo
demás. Un host hostil en el mismo Wi-Fi aún puede alcanzar el puerto, que es el
costo de recibir archivos del teléfono de un desconocido; LocalSend pregunta
antes de aceptar una transferencia.

Excepto desde una interfaz virtual (ERGON-69): un puente de docker, podman o
libvirt, el veth de un contenedor, el tap de una VM y un túnel VPN son cada uno
un segmento local propio, así que el destino por sí solo admitía mDNS también
desde ellos. Se excluyen por **tipo** de interfaz (`meta iifkind`), no por
nombre. Una lista de nombres se deja fuera todo runtime en el que nadie pensó,
mientras que el tipo es como el kernel llama al dispositivo sin importar quién
lo creó. Una NIC física no tiene tipo, así que la exclusión nunca la alcanza. Lo
que no se restringe es avahi mismo: sigue anunciando los servicios de esta
máquina en esas interfaces, de salida, lo que equivale a un contenedor
aprendiendo el nombre de host que de todos modos podría leer.

### El conjunto de reglas nunca debe vaciar todo el ruleset

Las reglas de Docker llegan al kernel a través de iptables-nft, que es el
**mismo** backend nf_tables. Por tanto `flush ruleset` destruye las cadenas
`DOCKER` y `DOCKER-USER` de un demonio en ejecución, y cada contenedor pierde su
red sin que ningún registro diga por qué. El nuestro destruye una tabla por
nombre.

El `nftables.service` de upstream se detiene con exactamente ese comando
(`ExecStop=/usr/sbin/nft flush ruleset`), así que en las distros que lo traen
(Debian es una) `systemctl restart nftables`, lo que cualquiera hace tras editar
un ruleset, borraría las cadenas de Docker por muy bien acotado que esté el
archivo. El aprovisionamiento escribe un drop-in que reduce la detención a `nft
destroy table inet ergon`.

**La unidad de Arch no es la de upstream**, y escribir ese drop-in contra la
equivocada es lo que dejó a la primera máquina Arch real sin nada que filtrara
lo entrante. Arch distribuye tres líneas (`Type=oneshot` y `ExecStart=/usr/bin/nft
-f /etc/nftables.conf`) sin `RemainAfterExit=`, sin `ExecReload=` y sin
`ExecStop=`. systemd ejecuta los comandos de detención de un oneshot en el
instante en que `ExecStart` termina, a menos que se fije `RemainAfterExit=yes`,
así que añadir un `ExecStop` a esa unidad destruía la tabla que acababa de
cargar, en cada arranque, mientras `systemctl enable --now` seguía devolviendo
cero. Por eso el drop-in fija las tres directivas en vez de reducir una que se
supone que el paquete tiene, y la etapa de aprovisionamiento le pregunta al
kernel por la cadena cargada en vez de confiar en un código de salida.

### Los puertos de contenedores publicados se enlazan a 127.0.0.1

Un puerto publicado pasa por DNAT y se entrega a través de FORWARD, así que la
cadena input nunca lo ve: `docker run -p 8080:80` en una máquina con firewall
sigue abierto para toda la sala. `/etc/docker/daemon.json` fija `"ip":
"127.0.0.1"`, de modo que el enlace por defecto es loopback y publicar fuera de
la máquina es algo que dices en voz alta:

    docker run -p 0.0.0.0:8080:80 ...        ports: ["0.0.0.0:8080:80"]

**Lo que cuesta:** un servicio de compose al que hoy llega otro host de la flota
deja de responder hasta que su puerto se republique así. El tráfico de los
puentes de docker se descarta también con todo lo demás, de modo que un
contenedor que llegue de vuelta a la puerta de enlace del host
(`host.docker.internal`, `--add-host ...:host-gateway`) se cuelga; abrir eso
corresponde a `/etc/nftables.conf` mediante el aprovisionamiento, no a una regla
añadida a mano que la siguiente recarga descarta.

El mismo archivo limita los registros de contenedores a 10 MB x 5. `json-file` no
tiene ningún límite por defecto, y un contenedor charlatán llena `/`, momento en
que todo en la máquina falla a la vez y se lee como una falla de disco y no como
la de un contenedor.

El aprovisionamiento **fusiona** esas cuatro claves con `jq` en vez de escribir
el archivo. Todo otro archivo de `/etc` que posee es política de ergon que nada
más toca, pero `daemon.json` es donde una máquina guarda su propio estado:
`data-root` en `/home` porque `/` es pequeño, una entrada `insecure-registries`
para el registry que aloja chiki, un bloque de proxy. Una escritura del archivo
completo descarta eso y reinicia dockerd en el mismo aliento, y el demonio vuelve
sobre `/var/lib/docker` donde no está ninguna de las imágenes, contenedores ni
volúmenes de la máquina. Un `daemon.json` que no se parsea se deja intacto con
una advertencia: es la edición a medias de alguien, dockerd no corre con él de
ninguna manera, y el archivo es la única copia.

`ergon doctor` lleva ambas mitades: `firewall` falla cuando nftables no está
activo, y `docker-publish` falla cuando daemon.json no fija el enlace. La
política de la cadena necesita `CAP_NET_ADMIN` para leerse, así que como tu
propio usuario doctor dice que no puede comprobarlo sin root en vez de inventar
una respuesta; `docker-publish` es una lectura de archivo y responde en ambos
casos.

Doctor sondea root por separado de pedir la política, porque son dos hechos
distintos y mezclarlos ocultaba el peor estado. `nftables.service` es
`Type=oneshot`, y el drop-in de arriba lo vuelve `RemainAfterExit=yes`, que es
también lo que hace que valga la pena preguntar `is-active` aquí, y por qué la
fila no puede quedarse ahí: la unidad sigue *activa* después de que alguien
escribe `nft flush ruleset` mientras depura, y una fila `firewall` que leía un
`nft list` fallido como "no soy root" informó ok, a root, en una máquina con un
ruleset vacío. Una unidad activa sin tabla `inet ergon` es ahora una falla dura.

## Qué protege realmente LUKS, y qué contiene la ESP sin cifrar

El cifrado de disco completo responde a un notebook robado o perdido, no a un
proceso que ya corre en él: `cryptsetup open` al arrancar es la última pregunta
que esta máquina hace sobre el disco, así que una sesión comprometida o una
extensión maliciosa ya tienen todo lo que la contraseña ocultaría. Lo que queda
protegido es exactamente el caso del equipo apagado: la mochila olvidada en un
tren, el notebook sustraído en un observatorio.

La contraseña se escribe una vez, en el prompt de Plymouth en el initramfs
(ERGON-123). La ESP no está cifrada y contiene systemd-boot, una imagen de kernel
unificada por kernel, y los kernels e imágenes initramfs de los snapshots
recientes que `ergon-boot-entries` copia allí para que el menú de arranque pueda
iniciarlos. Nada de eso es secreto: son los mismos archivos que distribuyen los
paquetes de Arch, y el initramfs no lleva ninguna clave. La raíz (`/home`,
`/etc`, el swapfile y con él toda imagen de hibernación) permanece dentro de
LUKS2, con una clave Argon2id derivada solo de la contraseña. Hay un keyslot y
ningún archivo de clave.

**Lo que debilita, frente al diseño anterior:** quien tenga el disco apagado
puede reemplazar lo que hay en la ESP. Un kernel manipulado vería la contraseña
la próxima vez que se escriba. El diseño de GRUB (`/boot` dentro de LUKS) tenía
el mismo agujero un paso antes (el propio GRUB vivía en la ESP sin cifrar), así
que no es una clase nueva de ataque, y la respuesta a ambos es Secure Boot con
tus propias claves, que es opcional (más abajo).

**Secure Boot con tus propias claves (opcional, ERGON-124).** `ergon secureboot
enable` crea un conjunto de claves con sbctl (guardado en `/var/lib/sbctl`,
dentro de LUKS), firma systemd-boot, las UKI y los kernels de snapshot en la ESP,
y registra las claves junto con las de Microsoft, de modo que las option ROM de
GPU y una instalación de Windows junto a esta sigan funcionando. Se niega a
menos que el firmware esté en modo de configuración: `systemctl reboot
--firmware-setup`, luego bajo Secure Boot elige "Reset to Setup Mode", "Clear
Secure Boot keys" o "Delete all keys" (nunca "Restore factory keys"), guarda,
arranca, ejecútalo otra vez, y después activa Secure Boot en el mismo menú. Desde
entonces el hook de mkinitcpio de sbctl firma cada UKI al construirse, su hook de
pacman vuelve a firmar systemd-boot, ergon-boot-entries firma cada kernel de
snapshot que copia, y el aprovisionamiento vuelve a firmar todo. `ergon
secureboot status` y `ergon doctor` (`secure-boot`) muestran el modo de
configuración, activado o desactivado, y cualquier archivo sin firmar. No
cubierto: las imágenes initramfs de las entradas de snapshot se cargan sin
verificar (las UKI llevan las suyas dentro de la firma), y en una máquina que se
movió fuera de GRUB la entrada de menú de GRUB ya no arranca. Nada cambia para
una máquina que nunca lo ejecuta.

**Si no arranca después de habilitarlo:** desactiva Secure Boot en el firmware
(o restablece al modo de configuración), arranca y ejecuta `ergon secureboot
status`; nombra el archivo sin firmar, y `sudo ergon secureboot sync` lo firma.
Tus datos nunca dependieron de Secure Boot, solo la comprobación de que el
kernel es tuyo.

**Inicio de sesión automático.** Con `AUTOLOGIN=1` (el valor por defecto del
instalador), greetd inicia la sesión tras el desbloqueo sin pedir contraseña, de
modo que la contraseña del disco es la única al arrancar. La pantalla de bloqueo
sigue pidiendo tu contraseña al reanudar y tras la inactividad, y `sudo` también.

**Instalar sin cifrado.** El instalador pregunta si cifrar el disco (`ENCRYPT`,
por defecto sí). `ENCRYPT=0` pone btrfs directamente sobre la partición: sin
contraseña, un splash sin prompt, y con inicio de sesión automático la máquina
pasa del botón de encendido al escritorio sin preguntar nada. Quien tenga el
notebook entonces tiene todo lo que hay en él, `/home` y la imagen de
hibernación incluidos; la pantalla de bloqueo solo protege una máquina que ya
está encendida. Queda registrado en `/etc/ergon/install.env` y no se puede
cambiar sin reinstalar. `ergon doctor` advierte sobre el inicio de sesión
automático en una raíz sin cifrar solo cuando esa no fue la respuesta del
instalador.

**El llavero no tiene contraseña.** Nadie escribe una contraseña de inicio de
sesión con la que PAM pueda desbloquear un llavero, así que el llavero por
defecto (`Default_keyring`) se guarda sin una: lo que Chromium, VS Code o Discord
guardan ahí está protegido por el cifrado del disco, como el resto de `/home`, y
es legible por cualquier proceso que corra como tú, como el resto de `/home`.

Las instalaciones anteriores a ERGON-123 tienen GRUB con `/boot` dentro de LUKS2
y un archivo de clave aleatorio en el initramfs, de modo que la contraseña se
escribe una vez en GRUB. Ese archivo de clave está cifrado en reposo con todo lo
demás. Esas máquinas pueden pasar al diseño de arriba (`ergon-boot-migrate run`,
ERGON-125; opcional: `BOOT_MIGRATE=1` en host.env permite que el
aprovisionamiento lo haga). El archivo de clave sale del initramfs antes de que
se construya la primera UKI, ya que en la ESP sería la clave del disco en claro,
y el menú de arranque nunca ofrece un snapshot anterior al cambio: su initramfs
aún contiene la clave. Su keyslot permanece hasta que lo retires
(`ergon-boot-migrate --help`). GRUB también permanece, como una entrada en el
menú de systemd-boot y detrás de él en el orden de arranque del firmware; desde
ahí pide la contraseña dos veces.

## TRIM pasa a través del cifrado de disco

dm-crypt descarta cada discard a menos que el mapeo los permita, y hasta ERGON-34
nada aquí los permitía: btrfs activa su discard asíncrono por sí mismo, al
montar, solo para un dispositivo que acepta discards, así que al SSD bajo
`/dev/mapper/cryptroot` nunca se le dijo qué bloques estaban libres: velocidad de
escritura y desgaste, perdidos a lo largo de meses.

**Lo que debilita:** qué bloques están libres se vuelve visible en el disco en
bruto, de modo que quien lo tenga apagado puede saber aproximadamente cuán lleno
está y adivinar el sistema de archivos. **Lo que sigue siendo cierto:** ni un
solo byte de lo que contienen los bloques usados, y nada sobre la contraseña.

Las instalaciones nuevas arrancan con `rd.luks.options=discard`, y el instalador
abre el volumen con `--allow-discards --persistent`, lo que escribe la bandera en
el encabezado LUKS2 para todo abridor posterior, la ISO de rescate incluida. En
instalaciones con GRUB el aprovisionamiento escribe la misma bandera
(`cryptsetup refresh --persistent`, desbloqueado con su archivo de clave de
arranque, de modo que nunca pide nada). `fstrim.timer` corre semanalmente
encima. No hay opción: el aprovisionamiento vuelve a poner la bandera si se
quita. La fila `trim` de `ergon doctor` falla cuando el mapper muestra DISC-MAX
0, también sobre un disco que no acepta discards en absoluto.

## Las actualizaciones esperan a la suite de la VM

`ergon update` actualiza al Arch que la suite de la VM instaló y pasó por última
vez, no al de hoy: `packages/tested-date` nombra un día de
archive.archlinux.org, y `/etc/pacman.d/ergon-mirrorlist` apunta core, extra y
multilib a él. Todo el sistema se mantiene ahí, y las instalaciones nuevas
también parten de ahí. Lo que compra: un Hyprland que renombra un campo Lua llega
a esta máquina solo después de que una sesión de escritorio haya arrancado con él
y sus binds se hayan registrado.

**Lo que cuesta:** las correcciones de seguridad también esperan. La suite corre
semanalmente, y en cualquier push que toque el instalador, así que una
corrección normalmente va como máximo una semana atrás, en una máquina cuyo
checkout `ergon sync` mantiene al día, ya que el día llega en él como cualquier
otro archivo. `ergon update` dice cuán antiguo es su día, y la fila `arch-date`
de doctor advierte pasadas dos semanas, cuando el checkout está obsoleto o la
suite ha dejado de pasar. `ergon update --latest` toma ahora mirrors en vivo, sin
probar, una vez; `ergon channel rolling` lo hace en cada actualización
(ERGON-99), y `ergon channel` sin argumento dice en cuál está esta máquina. **Lo
que sigue siendo cierto:** nunca se hace downgrade de nada. De vuelta en el día
probado tras mirrors en vivo, un `ergon update` simple mantiene la máquina donde
está, sin actualizar nada, hasta que llegue un día probado posterior a su última
sincronización en vivo: volver antes mezclaría las compilaciones de ese día con
otras más nuevas, y `pacman -Suu` haría downgrade de formatos de datos que ya
migraron (un perfil de Firefox rechaza un Firefox más antiguo). La forma de
volver ahora a un estado probado es `ergon rollback`. Las filas `channel` y
`arch-date` de doctor dicen en cuál de estos está la máquina. Los paquetes AUR
siguen sus propios pines en `packages/aur`, compilados contra las bibliotecas del
día mantenido.

## Las extensiones de VS Code corren como tú, fuera de pacman

El bundle vscode instala `code` con pacman, y la parte de pacman termina ahí. Las
extensiones vienen de Open VSX a `~/.vscode-oss/extensions`, adonde no llega ni
el registro del bundle ni ninguna revisión de este repositorio. Una extensión es
código ordinario en el extension host con tus privilegios. No hay sandbox:
Workspace Trust puede mantener una fuera en una carpeta en la que no confías, y
no cambia nada una vez que corre. `extensions.autoUpdate` está activado por
defecto, así que lo que corra mañana es lo que su publicador haya enviado esta
noche.

Open VSX es además una barrera más débil que el marketplace de Microsoft. Un
namespace pertenece a quien lo creó primero, y solo uno *verificado* tiene a su
dueño confirmado, de modo que el nombre de un proveedor que el proveedor nunca
registró allí puede ser de cualquiera. Lo que compra son las extensiones que la
gente ya conoce (ruff, Jupyter, el depurador) para una compilación que los
términos del marketplace de Microsoft excluyen.

Lo que sigue siendo cierto en cualquier caso: ergon no instala ninguna
extensión. `ergon new` escribe `.vscode/extensions.json`, VS Code ofrece lo que
lista, y tú dices que sí. Cada ID que recomienda está en un namespace verificado
y se instaló limpiamente con `code --install-extension` en la 1.138.
`ergon-bundle remove vscode` quita `code` y deja `~/.vscode-oss` a tu cargo.

### Copilot Chat viene incluido

`code` 1.138 distribuye GitHub Copilot Chat 0.66.0 como extensión incorporada
(cerca de 300 MB del paquete) con un agent host de Copilot al lado, y su
`product.json` marca la extensión para que se actualice sola. Comprobado en un
perfil nuevo, sin sesión iniciada, dos minutos inactivo bajo un compositor sin
cabeza:

- la extensión nunca se activó. El agent host arrancó y buscó un proxy para
  `api.githubcopilot.com`, y no siguió ninguna consulta DNS ni conexión.
- el único tráfico fue Electron descargando su diccionario de corrector
  ortográfico en-US desde `redirector.gvt1.com`, y la búsqueda de actualización
  de `github.copilot-chat` contra `open-vsx.org`, cuyo namespace de GitHub no
  lleva Copilot, así que hoy no encuentra nada. Si alguna vez lo hace, esa
  actualización también se salta pacman.

Iniciar sesión en GitHub es lo que lo enciende. Para quitarlo de la interfaz en
cambio, fija `"chat.disableAIFeatures": true` en
`~/.config/Code - OSS/User/settings.json`: con eso el agent host no arranca en
absoluto. La búsqueda de actualización sigue corriendo.

## Theia responde a los nombres de scripting de ds9, en loopback

`environment.d/60-theia.conf` fija `THEIA_XPA=public`, de modo que Theia registra
los puntos de acceso XPA `DS9:ds9` y `THEIA:fitsviewer` como lo hace ds9, y un
script `xpaset -p ds9 ...` existente lo maneja sin cambios (ERGON-73). Un
`pyds9.DS9()` a secas encuentra a Theia (medido, pyds9 1.8.1). Antes de Theia
8f422f3 el segundo punto de acceso era `DS9:fitsviewer`: un `DS9()` a secas
coincidía con ambos y lanzaba "too many ds9 instances", así que había que nombrar
el objetivo, `pyds9.DS9("DS9:ds9")`.
El valor por defecto de Theia es privado: un directorio 0700 por instancia al que
solo llega `theiactl`. Desde Theia 4a797dc `theiactl` lista y maneja también las
instancias públicas. Entre 185357b y esa versión llegaba SOLO a las privadas, de
modo que bajo esta configuración no listaba nada y xpaget/xpaset eran la vía de
entrada. Lo que "public" debilita es quién puede manejar el visor: abrir
cualquier archivo que su usuario pueda leer, cambiar la visualización, leer de
vuelta la ruta abierta y las regiones, cerrarlo. XPA no tiene autenticación
propia; en un notebook de un solo usuario "cualquier usuario local" eres tú y tus
propios procesos, el mismo conjunto que ya puede ejecutar `theiactl`.

Es público para esta máquina y no más allá, y eso es la segunda línea del mismo
archivo, `XPA_METHOD=localhost`. El método por defecto de libxpa es inet en
todas las interfaces; medido, `xpans` en `0.0.0.0:14285` y `:14286` y cada punto
de acceso en un puerto `0.0.0.0` aleatorio. El firewall descarta eso desde la
LAN pero acepta `tailscale0` (ver "Lo entrante se descarta" arriba), así que sin
ella cualquier host de la tailnet podría haber abierto archivos en el visor, y
cerrarlo. `localhost` es el mismo transporte TCP enlazado a `127.0.0.1`; un
script que no fije `XPA_METHOD` igual lo alcanza. La API de scripting HTTP de
Theia no se ve afectada en ningún caso: loopback, con un token bearer 0600 por
instancia.

Para mantener a Theia privado, pon `THEIA_XPA=private` en un archivo posterior
de `~/.config/environment.d/` (por ejemplo `61-theia-private.conf`) e inicia una
sesión nueva. La variable pesa más que la elección de Settings -> DS9 scripts de
Theia, así que la ventana de Settings no puede deshacerla.
