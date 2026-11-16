# Especificación Funcional y Diseño de la Aplicación de Escritorio (VFS Client)

> Especificación limpia de funcionalidades y arquitectura de la aplicación de escritorio (estilo Dropbox + servidor local de jobs) construida sobre `lib/vfs` (`ARCH-037B`) y adaptadores `BlobStorePort` (`lib-gdrive-vfs`, `local-vfs`, `s3-vfs`, `ssh-vfs`).

---

## 1. Alcance: Qué pertenece a la App vs. a las Librerías

- **Responsabilidad de las librerías** (`lib/vfs`, `lib-gdrive`, `lib-gdrive-vfs`): cifrado, formato `GDRVPART`, `Packer`, `RangeCache`, `PoolAllocator` (`UploadPolicy`), `SyncCoordinator` (CAS), `BlobStorePort` y `ApiQuotaMetrics`.
- **Responsabilidad de la App**:
  1. Ciclo de vida del **Daemon único** y su API local (HTTP/REST + SSE/WS) para GUI, CLI y jobs externos.
  2. Persistencia local (`SQLite` implementando `vfs.CatalogPort.VTable` + custodia cifrada de `device_sk` y credenciales de nodos).
  3. Cola de trabajos en segundo plano, sincronizador bidireccional de carpetas y servidor de streaming `HTTP Range`.
  4. Interfaz gráfica de usuario (GUI) y comandos CLI.

---

## 2. Arquitectura de Procesos

```text
+-------------------+      +-------------------+      +-------------------+
|   GUI Escritorio  |      |        CLI        |      |   Apps / Scripts  |
+---------+---------+      +---------+---------+      +---------+---------+
          |                          |                          |
          +--------------------------+--------------------------+
                                     | HTTP/REST + SSE/WS (127.0.0.1 / Unix Socket)
                                     v
          +-----------------------------------------------------+
          |                 VFS App Daemon                      |
          |  - Gestor de Vaults / Particiones (vfs.Vault)       |
          |  - Cola de Jobs (upload, pack, download, sync, gc)  |
          |  - Sync Engine (watcher local <-> vault.refresh())  |
          |  - Media Streamer (GET /stream/<inode_id> Range)    |
          +------------+---------------------------+------------+
                       |                           |
                       v                           v
          +------------------------+   +------------------------+
          | SQLite (CatalogPort)   |   | CompositeBlobStore     |
          | caché local + estado   |   | (GDriveBlobStore, ...) |
          +------------------------+   +------------------------+
```

**Invariante**: solo el Daemon mantiene abiertos los `vfs.Vault` activos (`vmk`, `current_etag`, `RangeCache`), evitando carreras `412 Precondition Failed` entre GUI, CLI y sincronizador.

---

## 3. Especificación Funcional

### F1. Gestión de Vaults, Claves y Particiones Lógicas
- **Desbloqueo / Creación**: asistente inicial para crear un vault nuevo (`Vault.create`) o abrir uno existente (`Vault.open` / `discoverCatalogObjectId`), protegiendo la clave privada `device_sk` en local con passphrase o keyring del SO.
- **Particiones lógicas**:
  - Soportar múltiples vaults independientes en configuración (aislamiento total de claves y cuotas, p. ej. partición de 5 GiB para documentos oficiales).
  - Soportar políticas de asignación por carpeta/operación (`MostAvailable`, `FirstFit`, `Random`, `PinnedAccount`) sobre pools homogéneos o híbridos (`CompositeBlobStore`).

### F2. Explorador VFS (GUI & CLI)
- Navegación jerárquica (`listDir`, `stat`), creación de directorios (`mkdir`), renombrado/movido (`rename`) y borrado (`delete`).
- **Subida inteligente**:
  - Archivos pequeños (`<= small_file_threshold`) → agrupados automáticamente en cola de lote con `vault.writePacked(...)`.
  - Archivos grandes → subidos con `vault.write(...)`.
- **Descarga**: exportación de archivos individuales o carpetas a disco local.

### F3. Streaming Multimedia y Previsualización (`HTTP Range`)
- Endpoint local `GET /stream/<vault_id>/<inode_id>` con soporte completo de cabeceras `Range: bytes=start-end` y `206 Partial Content`.
- Permite abrir vídeos, audio o PDFs directamente desde VLC, `mpv` o el navegador haciendo *seek* instantáneo gracias a `vault.readAt(...)` + `RangeCache` LRU en RAM.

### F4. Sincronización Bidireccional (Carpeta Local ↔ VFS)
- Vincular una carpeta local con un directorio del VFS.
- Detectar cambios locales (watcher / escaneo por `mtime` + hash) y cambios remotos (`vault.refresh()` periódico).
- **Resolución de conflictos**: si ambos lados modificaron el mismo archivo, conservar la versión remota y renombrar la local a `"nombre (conflicted copy).ext"`.
- **Seguridad de borrado**: ejecutar siempre `vault.refresh()` antes de lanzar `vault.runGc()` para no eliminar blobs referenciados por otro dispositivo.

### F5. Cola de Jobs y Modo Servidor (CLI / Automatizaciones)
- API local para encolar trabajos asíncronos (`upload`, `download`, `sync`, `gc`), consultar su progreso por SSE/WebSocket, pausarlos o cancelarlos.
- Ingesta desde apps externas/CLI: permite recibir rutas de archivos locales cerrados (p. ej. segmentos de vídeo/streams ya finalizados) para subirlos sin bloquear la aplicación emisora.

### F6. Observabilidad y Mantenimiento
- **Cuotas de almacenamiento**: vista global y por nodo usando `vault.getQuotas()` (`0` peticiones remotas), más acción bajo demanda en *Settings* (`vault.syncQuotasFromRemote()`) para verificar la cuota real en el proveedor.
- **Métricas de API (por backend)**: para nodos Google Drive (`GDriveBlobStore.getApiMetrics()`), mostrar unidades consumidas en los últimos 60 s frente a los límites (`325,000` usuario / `1,000,000` proyecto), tráfico `bytes_uploaded` / `bytes_downloaded`, errores `429` y ratio de aciertos de `RangeCache`.
- **Garbage Collector**: indicador de blobs pendientes de limpieza y botón/tarea programada para ejecutar `vault.runGc()`.

---

## 4. Roadmap de Implementación

1. **MVP 1 — Core Daemon + SQLite `CatalogPort` + API REST**:
   - Adaptador SQLite validado con `CatalogPort.runConformanceSuite`.
   - Daemon HTTP local con endpoints para F1, F2, F3 (`GET /stream/...` con `Range`), F5 (cola de jobs) y F6 (cuotas + métricas).
   - Exportar colección **Postman** e **Insomnia** con todos los endpoints de la API local del daemon para pruebas e integración.
2. **MVP 2 — GUI de Escritorio + CLI**:
   - Web UI embebida (servida por el propio binario) o GUI nativa conectada al daemon + cliente CLI ligero.
3. **MVP 3 — Sincronizador Estilo Dropbox (F4)**:
   - Watcher bidireccional, cola automática `writePacked`/`write` y gestión de conflictos.
4. **MVP 4 — Montaje FUSE / POSIX (Opcional)**:
   - Exponer el VFS como punto de montaje del SO reutilizando el mismo daemon y `RangeCache`.
