# Odoo Admin

Odoo Admin es un framework modular escrito en Bash 5 para administrar
instalaciones de Odoo sobre Debian. El proyecto centraliza operaciones de
respaldo, restauración, archivado, mantenimiento, PostgreSQL y sistema de
archivos mediante bibliotecas con responsabilidades claramente separadas.

> El proyecto se encuentra en desarrollo. Antes de utilizarlo en producción,
> pruebe el flujo completo de respaldo y restauración en un entorno aislado.

## Arquitectura

Las aplicaciones orquestan los casos de uso y delegan las operaciones de bajo
nivel en bibliotecas reutilizables:

```text
Aplicación (backup/bin/*.sh)
        │
        ├── logger.sh   Registro de eventos
        ├── config.sh   Carga y validación de configuración
        ├── fs.sh       Operaciones de sistema de archivos
        ├── pg.sh       Operaciones de PostgreSQL
        └── archive.sh  Construcción y lectura del formato OAA
```

`archive.sh` abstrae por completo el formato físico. Las aplicaciones no deben
invocar GNU tar ni zstd directamente.

## Formato OAA

OAA (**Odoo Admin Archive**) es el formato de archivo propio del proyecto y
utiliza la extensión `.oaa`. Internamente consiste en un TAR comprimido con
zstd.

Su estructura lógica es:

```text
manifest.json
resources/
├── config/
├── filestore/
├── addons/
└── admin/
```

Los nombres de los recursos son descriptores genéricos. El Builder no conoce
conceptos de Odoo: recibe un nombre, una ruta de origen y el requisito del
recurso.

### Construcción sin staging

El Builder añade cada recurso directamente desde su ubicación original:

1. crea un directorio temporal pequeño para archivos de control;
2. genera `manifest.json`;
3. crea un TAR temporal en el mismo sistema de archivos que el destino;
4. añade los recursos mediante `tar -C`, sin copiarlos previamente;
5. comprime una sola vez con zstd;
6. verifica el archivo provisional;
7. crea atómicamente el nombre final mediante un enlace duro y elimina el
   nombre provisional;
8. elimina los temporales tanto al finalizar como ante un error.

Este diseño evita duplicar `addons`, `filestore` y los demás recursos en
`/tmp`. La implementación anterior hacía staging mediante `cp`, lo que podía
agotar un `/tmp` montado como `tmpfs` aunque el disco principal tuviera espacio.

El TAR temporal es la única copia intermedia sin comprimir. Durante la
compresión coexisten el TAR y el OAA provisional, por lo que el filesystem de
destino debe disponer de espacio para ambos, además de sus metadatos. Se
preservan permisos, marcas de tiempo, enlaces simbólicos y directorios vacíos.

## API pública de archivado

La biblioteca `scripts/archive.sh` expone:

- `archive_create`: crea y verifica un OAA antes de publicarlo;
- `archive_extract`: verifica y extrae un OAA sin reemplazar archivos existentes;
- `archive_list`: lista los recursos declarados;
- `archive_manifest`: imprime el manifiesto JSON;
- `archive_verify`: valida estructura, manifiesto y correspondencia de recursos;
- `archive_check_environment`: comprueba GNU tar, zstd y Python 3.

### Crear un archivo

La sintaxis heredada por pares conserva compatibilidad. Todos los recursos son
obligatorios:

```bash
source scripts/fs.sh
source scripts/archive.sh

archive_create \
    /var/backups/odoo/filesystem.oaa \
    config /etc/odoo \
    filestore /var/lib/odoo/filestore
```

El modo de descriptores explícitos permite distinguir recursos obligatorios y
opcionales:

```bash
archive_create \
    /var/backups/odoo/filesystem.oaa \
    --descriptors \
    config    /etc/odoo                 required \
    filestore /var/lib/odoo/filestore   required \
    addons    /opt/odoo/addons          required \
    admin     /opt/odoo-admin           optional
```

Si falta un recurso `required`, la creación falla y no publica el archivo. Si
falta uno `optional`, el manifiesto lo registra con `"included": false`.

### Consultar, verificar y extraer

```bash
archive_verify /var/backups/odoo/filesystem.oaa
archive_list /var/backups/odoo/filesystem.oaa
archive_manifest /var/backups/odoo/filesystem.oaa
archive_extract /var/backups/odoo/filesystem.oaa /ruta/de/restauracion
```

La extracción conserva la raíz lógica `resources/` para que cada recurso pueda
identificarse sin depender de su ruta original. El destino debe ser inexistente:
la operación lo crea y lo elimina si la extracción falla. Esta precondición
evita mezclar un respaldo con datos anteriores, enlaces simbólicos o una
extracción parcial.

## Manifiesto

`manifest.json` describe el archivo y sus recursos. Cada descriptor incluye:

- nombre lógico;
- ruta de origen;
- ruta interna en el OAA;
- tipo de recurso;
- requisito (`required` u `optional`);
- estado de inclusión;
- tamaño;
- número de entradas.

Los valores se serializan como JSON válido, incluidos nombres y rutas con
espacios, comillas o caracteres que requieren escape.

Los nombres de archivo con saltos de línea o retornos de carro se rechazan
durante la creación. OAA 1.0 no los admite porque sus herramientas de
inspección deben conservar una interpretación inequívoca de cada miembro.

La ruta absoluta de origen se conserva deliberadamente como dato de
trazabilidad. Por ello, el manifiesto puede revelar rutas internas del servidor:
un OAA debe tratarse como información sensible y protegerse con los mismos
controles de acceso que los datos respaldados.

## Respaldo del sistema de archivos de Odoo

`backup/bin/backup-files.sh` crea un OAA con los recursos definidos en
`config/files.conf`:

```bash
ODOO_CONFIG_DIR="/etc/odoo"
ODOO_CONFIG_REQUIRED="required"

ODOO_FILESTORE_DIR="/var/lib/odoo/filestore"
ODOO_FILESTORE_REQUIRED="required"

ODOO_ADDONS_DIR="/opt/odoo/addons"
ODOO_ADDONS_REQUIRED="required"

ODOO_ADMIN_DIR="/opt/odoo-admin"
ODOO_ADMIN_REQUIRED="required"
```

Cada variable `*_REQUIRED` acepta `required` u `optional`. Ajuste las rutas a la
instalación real antes de ejecutar el respaldo.

El destino, prefijo, formato de fecha y políticas de retención se configuran en
el mismo archivo. La aplicación valida primero las dependencias y permisos,
crea el OAA diario y después aplica las rotaciones semanal y mensual.

## Orquestador de respaldo

`backup/bin/backup.sh` es el punto de entrada oficial para ejecutar manualmente
un trabajo completo:

```bash
/opt/odoo-admin/backup/bin/backup.sh
```

El orquestador coordina, en este orden, `backup-db.sh` y `backup-files.sh`. No
duplica la creación, rotación ni retención de sus respaldos. La salida de ambos
componentes se hereda directamente para conservar toda la información
operativa, y el éxito se determina exclusivamente por sus códigos de retorno.

La política no es *fail-fast*: si el respaldo de base de datos falla, el
respaldo de archivos todavía se ejecuta. Al final se registra un resumen con el
estado y la duración individual de ambos componentes, la duración total, el
resultado global y el código. Las duraciones usan segundos monotónicos del
propio proceso y el formato `HH:MM:SS`; un componente no ejecutado muestra
`NOT_RUN`, nunca una duración ambigua de cero.

| Código | Resultado |
|---:|---|
| `0` | Ambos componentes terminaron correctamente |
| `1` | Ambos componentes fallaron |
| `2` | Sólo uno de los componentes terminó correctamente |
| `3` | Ejecución rechazada porque otro respaldo está en curso |
| `4` | Error interno previo a la ejecución de los componentes |

Para impedir trabajos simultáneos, `backup.sh` mantiene durante toda la
ejecución un bloqueo `flock` no bloqueante sobre
`/run/lock/odoo-admin-backup.lock`. La ruta puede ajustarse con
`BACKUP_LOCK_FILE` en `config/backup.conf`. El archivo de lock puede persistir:
la exclusión depende del descriptor abierto, que el sistema cierra al terminar
el proceso. El descriptor permanece abierto mientras termina el componente
activo y el lock se libera automáticamente al finalizar, incluso ante una
señal; no se elimina normalmente el archivo ni se requiere un *unlock*
explícito.

El orquestador maneja explícitamente `SIGINT`, `SIGTERM` y `SIGHUP`. Cada
componente se ejecuta en una sesión y un grupo de procesos propios mediante
`setsid --wait`. Antes de ejecutarlo se restaura la disposición predeterminada
de esas señales, incluso para `SIGINT` en shells Bash no interactivos. Al
recibir una señal, el orquestador la registra una sola vez y la reenvía
únicamente al grupo activo para terminar también sus descendientes. El padre
espera la terminación del grupo fuera del trap y después sale con la convención
Unix: `130` para `SIGINT`, `143` para `SIGTERM` y `129` para `SIGHUP`.

Si no existe un componente activo, la señal termina inmediatamente el
orquestador con el mismo código. Además, se comprueba el estado de cancelación
en cada transición crítica: después de instalar los traps, validar los
componentes y adquirir el lock; entre ambos respaldos; después del segundo
componente; y antes de clasificar o resumir el resultado. Una cancelación nunca
inicia el componente siguiente ni produce un resumen normal `COMPLETE`,
`FAILED` o `PARTIAL`. Los códigos por señal no forman parte de la API normal
`0`–`4`; representan una terminación externa. El manejo de `SIGTERM` queda
preparado para una futura integración con systemd.

Los timeouts, la programación mediante cron y las unidades o timers de systemd
pertenecen a fases posteriores y todavía no forman parte del proyecto.

Los resúmenes usan la API genérica del logger:

```bash
log_key_value "Database duration" "00:00:31"
```

`log_key_value` recibe exactamente una clave y un valor no vacíos, admite
espacios en ambos argumentos, aplica una alineación estable y escribe mediante
el flujo normal del logger, incluida la salida al logfile configurado.

## Requisitos

- Debian o un sistema compatible;
- Bash 5;
- GNU tar con soporte para zstd;
- zstd;
- Python 3;
- `flock`, provisto por `util-linux`;
- utilidades GNU habituales (`stat`, `find`, `numfmt`, entre otras);

Instalación de las dependencias principales en Debian:

```bash
sudo apt update
sudo apt install bash tar zstd python3 util-linux
```

## Pruebas

La suite cubre archivos y directorios, varios orígenes, espacios y caracteres
especiales en JSON, UTF-8, directorios vacíos, enlaces simbólicos, permisos,
timestamps, recursos opcionales y obligatorios, diagnóstico de ausencias,
publicación concurrente, archivos corruptos, manifiestos inválidos, recursos
declarados pero ausentes, path traversal, salida ya existente, limpieza ante
fallos de TAR o zstd y ausencia de staging mediante `fs_copy`.

```bash
bash tests/archive_test.sh
bash tests/backup_orchestrator_test.sh
```

Si zstd no está instalado, la suite usa exclusivamente dentro del entorno de
pruebas un helper compatible basado en gzip. Esto permite comprobar el flujo,
pero no sustituye una validación final con zstd real antes del despliegue.

Comprobaciones estáticas recomendadas:

```bash
bash -n scripts/*.sh backup/bin/*.sh tests/*.sh tests/helpers/*
shellcheck scripts/*.sh backup/bin/*.sh tests/*.sh tests/helpers/*
git diff --check
```

## Seguridad e integridad

- Un OAA no se publica hasta superar `archive_verify`.
- La publicación usa `link(2)` mediante `ln`: la creación del nombre final es
  atómica y falla si ya existe. El provisional se crea junto al destino para
  garantizar el mismo filesystem. Entre ejecuciones concurrentes sólo una
  publica; las demás no modifican el destino.
- Los fallos intermedios eliminan los archivos temporales.
- La verificación exige un único `manifest.json`, JSON y versión compatibles,
  raíz `resources/`, nombres lógicos únicos, rutas internas seguras y
  correspondencia exacta entre recursos declarados e incluidos. También valida
  invariantes internos del manifiesto, tipos conocidos y destinos seguros de
  enlaces simbólicos y enlaces duros dentro de cada recurso lógico.
- `archive_manifest` y `archive_extract` sólo operan sobre un OAA que supera la
  verificación completa.
- `archive_extract` exige un destino inexistente para impedir resultados
  mezclados.
- Si la publicación crea el nombre final pero no puede retirar el provisional,
  intenta revertir el nombre final. Si también falla el rollback, devuelve un
  estado distinto y conserva ambos nombres apuntando al mismo archivo completo;
  nunca oculta el error secundario ni deja contenido parcial.

Estas garantías reducen el riesgo de conservar respaldos parciales. Aun así, la
verificación técnica de un archivo no reemplaza una restauración periódica de
prueba.

## Desarrollo

Consulte [`AGENTS.md`](AGENTS.md) antes de modificar el proyecto. Allí se
documentan la arquitectura, las responsabilidades de cada capa, las
restricciones del formato OAA y los criterios de diseño.

Las contribuciones deben mantener compatibilidad con Bash 5, funcionar en
Debian, evitar dependencias innecesarias y superar ShellCheck.
