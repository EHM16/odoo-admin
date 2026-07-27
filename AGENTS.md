# AGENTS.md

# Odoo Admin Framework

## Objetivo del proyecto

Este repositorio implementa **Odoo Admin**, un framework escrito en Bash 5 para administrar instalaciones de Odoo.

El proyecto NO es simplemente una colección de scripts.

Su objetivo es proporcionar una arquitectura modular para:

- respaldos
- restauraciones
- archivado
- mantenimiento
- administración de PostgreSQL
- administración de archivos
- futuras tareas de automatización

Todo el código debe seguir una arquitectura en capas.

---

# Filosofía

Cada biblioteca debe tener una única responsabilidad.

Ejemplos:

- logger.sh
    Registro de eventos.

- fs.sh
    Operaciones sobre el sistema de archivos.

- pg.sh
    Operaciones PostgreSQL.

- archive.sh
    Construcción y lectura del formato OAA.

Las aplicaciones (`backup-db.sh`, `backup-files.sh`, etc.) únicamente orquestan el flujo.

No deben contener lógica de bajo nivel.

---

# Estilo

- Bash 5
- ShellCheck clean
- Sin dependencias innecesarias
- Código portable para Debian
- Funciones pequeñas
- Una responsabilidad por función
- Comentarios descriptivos
- Nombres explícitos

---

# Formato OAA

El proyecto utiliza un formato propio llamado **OAA (Odoo Admin Archive)**.

Actualmente la extensión es:

    .oaa

Internamente utiliza:

- GNU tar
- zstd

NO se utilizará ZIP.

NO se utilizará 7zip.

La decisión es definitiva.

---

# Objetivo de archive.sh

archive.sh NO es un wrapper de GNU tar.

archive.sh implementa el formato OAA.

GNU tar es únicamente un detalle interno de implementación.

La API pública debe abstraer completamente el formato físico.

Las funciones públicas son similares a:

- archive_create
- archive_extract
- archive_list
- archive_verify
- archive_manifest

La implementación interna puede cambiar sin afectar a la API pública.

---

# Builder OAA

Internamente archive.sh utiliza un Builder.

El ciclo de vida esperado es:

Builder Begin

↓

Agregar Manifest

↓

Agregar Recursos

↓

Cerrar Builder

↓

Verificar

Las funciones privadas previstas son:

- _builder_begin
- _builder_add_manifest
- _builder_add_resource
- _builder_finish
- _builder_cleanup

---

# Arquitectura esperada

Las aplicaciones llaman:

archive_create()

↓

archive.sh

↓

Builder

↓

GNU tar

↓

zstd

La aplicación nunca debe invocar tar directamente.

---

# Recursos

Los recursos pueden ser:

- directorios
- archivos

El Builder nunca debe saber qué es Odoo.

No debe conocer conceptos como:

- addons
- filestore
- config
- PostgreSQL

Únicamente recibe descriptores de recursos.

Ejemplo conceptual:

Nombre

Origen

Destino dentro del OAA

Eso permite reutilizar el Builder para cualquier tipo de respaldo.

---

# Problema encontrado

La primera implementación construía un workspace temporal.

El algoritmo era aproximadamente:

copiar recursos

↓

crear manifest

↓

crear TAR

↓

comprimir

Esto provocó un problema muy importante.

Los recursos completos eran copiados a:

/tmp

En sistemas Debian, normalmente /tmp está montado como tmpfs.

Esto produjo errores como:

cp: error al escribir...
No queda espacio en el dispositivo

Aunque el disco tenía espacio disponible.

El problema NO es falta de espacio en disco.

El problema es la duplicación completa de los recursos dentro del workspace.

---

# Restricción importante

La solución NO debe consistir en:

- cambiar TMPDIR
- aumentar tmpfs
- copiar a otro directorio

Eso únicamente mueve el problema.

Debe eliminarse completamente la necesidad de copiar todos los recursos.

---

# Objetivo de la nueva implementación

La nueva implementación debe construir el archivo OAA directamente.

Los recursos deben añadirse desde su ubicación original.

Debe evitarse crear una copia completa de:

- addons
- filestore
- configuración

Solamente pueden existir pequeños archivos temporales como:

- manifest.json

o archivos de control similares.

Nunca una segunda copia completa de todos los recursos.

---

# Restricciones

La solución debe:

- preservar permisos
- preservar timestamps
- preservar enlaces simbólicos
- preservar directorios vacíos
- funcionar con GNU tar
- funcionar con zstd
- evitar duplicación innecesaria de datos
- mantener una API limpia
- ser fácilmente extensible

---

# Lo que NO se busca

No buscamos un parche.

No buscamos simplemente hacer que funcione.

Buscamos rediseñar archive.sh para que sea una implementación limpia del formato OAA.

Si durante el análisis encuentras una arquitectura mejor que cumpla todos estos objetivos, se prefiere una mejora de diseño antes que una solución mínima.

Antes de modificar el código:

1. Analiza la arquitectura actual.
2. Identifica por qué existe el problema.
3. Propón una arquitectura mejor si es necesario.
4. Después implementa la solución.

La prioridad es la calidad de la arquitectura, no la cantidad de código.
