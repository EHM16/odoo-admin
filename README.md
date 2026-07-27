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
7. lo publica mediante un movimiento atómico que no sobrescribe archivos;
8. elimina los temporales tanto al finalizar como ante un error.

Este diseño evita duplicar `addons`, `filestore` y los demás recursos en
`/tmp`. La implementación anterior hacía staging mediante `cp`, lo que podía
agotar un `/tmp` montado como `tmpfs` aunque el disco principal tuviera espacio.

El TAR temporal es la única representación intermedia grande. Se preservan
permisos, marcas de tiempo, enlaces simbólicos y directorios vacíos.

## API pública de archivado

La biblioteca `scripts/archive.sh` expone:

- `archive_create`: crea y verifica un OAA antes de publicarlo;
- `archive_extract`: extrae un OAA en un directorio de destino;
- `archive_list`: lista los recursos declarados;
- `archive_manifest`: imprime el manifiesto JSON;
- `archive_verify`: valida estructura, manifiesto y correspondencia de recursos;
- `archive_check_environment`: comprueba la disponibilidad de GNU tar y zstd.

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
identificarse sin depender de su ruta original.

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

## Requisitos

- Debian o un sistema compatible;
- Bash 5;
- GNU tar con soporte para zstd;
- zstd;
- utilidades GNU habituales (`stat`, `find`, `numfmt`, entre otras);
- Python 3 únicamente para la validación JSON incluida en las pruebas.

Instalación de las dependencias principales en Debian:

```bash
sudo apt update
sudo apt install bash tar zstd
```

## Pruebas

La suite cubre archivos y directorios, varios orígenes, espacios en rutas,
directorios vacíos, enlaces simbólicos, permisos, timestamps, recursos
opcionales y obligatorios, archivos corruptos, salida ya existente, limpieza
ante fallos de TAR o zstd y ausencia de staging mediante `fs_copy`.

```bash
bash tests/archive_test.sh
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
- La salida final no sobrescribe un archivo existente.
- El archivo provisional se crea junto al destino para mantener la publicación
  en el mismo sistema de archivos.
- Los fallos intermedios eliminan los archivos temporales.
- El manifiesto y el contenido se validan antes de aceptar el archivo.

Estas garantías reducen el riesgo de conservar respaldos parciales. Aun así, la
verificación técnica de un archivo no reemplaza una restauración periódica de
prueba.

## Desarrollo

Consulte [`AGENTS.md`](AGENTS.md) antes de modificar el proyecto. Allí se
documentan la arquitectura, las responsabilidades de cada capa, las
restricciones del formato OAA y los criterios de diseño.

Las contribuciones deben mantener compatibilidad con Bash 5, funcionar en
Debian, evitar dependencias innecesarias y superar ShellCheck.
