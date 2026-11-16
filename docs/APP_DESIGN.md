# Functional Specification and Design of the Desktop Application (VFS Client)

> Clean specification of features and architecture for the desktop application (Dropbox-style + local job server) built on top of `lib/vfs` (`ARCH-037B`) and `BlobStorePort` adapters (`lib-gdrive-vfs`, `local-vfs`, `s3-vfs`, `ssh-vfs`).

---

## 1. Scope: What Belongs to the App vs. the Libraries

- **Library responsibility** (`lib/vfs`, `lib-gdrive`, `lib-gdrive-vfs`): encryption, `GDRVPART` format, `Packer`, `RangeCache`, `PoolAllocator` (`UploadPolicy`), `SyncCoordinator` (CAS), `BlobStorePort`, and `ApiQuotaMetrics`.
- **App responsibility**:
  1. Lifecycle of the **single Daemon** and its local API (HTTP/REST + SSE/WS) for GUI, CLI, and external jobs.
  2. Local persistence (`SQLite` implementing `vfs.CatalogPort.VTable` + encrypted custody of `device_sk` and node credentials).
  3. Background job queue, bidirectional folder syncer, and `HTTP Range` streaming server.
  4. Graphical user interface (GUI) and CLI commands.

---

## 2. Process Architecture

```text
+-------------------+      +-------------------+      +-------------------+
|    Desktop GUI    |      |        CLI        |      |   Apps / Scripts  |
+---------+---------+      +---------+---------+      +---------+---------+
          |                          |                          |
          +--------------------------+--------------------------+
                                     | HTTP/REST + SSE/WS (127.0.0.1 / Unix Socket)
                                     v
          +-----------------------------------------------------+
          |                 VFS App Daemon                      |
          |  - Vault / Partition Manager (vfs.Vault)            |
          |  - Job Queue (upload, pack, download, sync, gc)     |
          |  - Sync Engine (local watcher <-> vault.refresh())  |
          |  - Media Streamer (GET /stream/<inode_id> Range)    |
          +------------+---------------------------+------------+
                       |                           |
                       v                           v
          +------------------------+   +------------------------+
          | SQLite (CatalogPort)   |   | CompositeBlobStore     |
          | local cache + state    |   | (GDriveBlobStore, ...) |
          +------------------------+   +------------------------+
```

**Invariant**: only the Daemon keeps active `vfs.Vault` instances open (`vmk`, `current_etag`, `RangeCache`), preventing `412 Precondition Failed` races between GUI, CLI, and syncer.

---

## 3. Functional Specification

### F1. Vault, Key, and Logical Partition Management
- **Unlock / Create**: initial wizard to create a new vault (`Vault.create`) or open an existing one (`Vault.open` / `discoverCatalogObjectId`), protecting the `device_sk` private key locally with a passphrase or OS keyring.
- **Logical partitions**:
  - Support multiple independent vaults in configuration (complete isolation of keys and quotas, e.g., a 5 GiB partition for official documents).
  - Support per-folder/operation allocation policies (`MostAvailable`, `FirstFit`, `Random`, `PinnedAccount`) over homogeneous or hybrid pools (`CompositeBlobStore`).

### F2. VFS Explorer (GUI & CLI)
- Hierarchical navigation (`listDir`, `stat`), directory creation (`mkdir`), rename/move (`rename`), and deletion (`delete`).
- **Smart upload**:
  - Small files (`<= small_file_threshold`) → automatically grouped into a batch queue with `vault.writePacked(...)`.
  - Large files → uploaded with `vault.write(...)`.
- **Download**: export individual files or folders to local disk.

### F3. Media Streaming and Preview (`HTTP Range`)
- Local endpoint `GET /stream/<vault_id>/<inode_id>` with full support for `Range: bytes=start-end` headers and `206 Partial Content`.
- Allows opening videos, audio, or PDFs directly in VLC, `mpv`, or the browser with instant seeking thanks to `vault.readAt(...)` + in-RAM LRU `RangeCache`.

### F4. Bidirectional Sync (Local Folder ↔ VFS)
- Link a local folder with a VFS directory.
- Detect local changes (watcher / `mtime` + hash scan) and remote changes (periodic `vault.refresh()`).
- **Conflict resolution**: if both sides modified the same file, keep the remote version and rename the local one to `"name (conflicted copy).ext"`.
- **Delete safety**: always run `vault.refresh()` before launching `vault.runGc()` so blobs referenced by another device are never deleted.

### F5. Job Queue and Server Mode (CLI / Automations)
- Local API to enqueue asynchronous jobs (`upload`, `download`, `sync`, `gc`), monitor progress via SSE/WebSocket, pause, or cancel them.
- Ingestion from external apps/CLI: accepts paths of closed local files (e.g., finished video segments/streams) to upload them without blocking the emitting application.

### F6. Observability and Maintenance
- **Storage quotas**: global and per-node view using `vault.getQuotas()` (`0` remote requests), plus an on-demand action in *Settings* (`vault.syncQuotasFromRemote()`) to verify the actual quota on the provider.
- **API metrics (per backend)**: for Google Drive nodes (`GDriveBlobStore.getApiMetrics()`), display units consumed in the last 60 s against limits (`325,000` user / `1,000,000` project), `bytes_uploaded` / `bytes_downloaded` traffic, `429` errors, and `RangeCache` hit ratio.
- **Garbage Collector**: indicator of blobs pending cleanup and a button/scheduled task to run `vault.runGc()`.

---

## 4. Implementation Roadmap

1. **MVP 1 — Core Daemon + SQLite `CatalogPort` + REST API**:
   - SQLite adapter validated with `CatalogPort.runConformanceSuite`.
   - Local HTTP daemon with endpoints for F1, F2, F3 (`GET /stream/...` with `Range`), F5 (job queue), and F6 (quotas + metrics).
   - Export **Postman** and **Insomnia** collections with all local daemon API endpoints for testing and integration.
2. **MVP 2 — Desktop GUI + CLI**:
   - Embedded Web UI (served by the binary itself) or native GUI connected to the daemon + lightweight CLI client.
3. **MVP 3 — Dropbox-Style Syncer (F4)**:
   - Bidirectional watcher, automatic `writePacked`/`write` queue, and conflict management.
4. **MVP 4 — FUSE / POSIX Mount (Optional)**:
   - Expose the VFS as an OS mount point reusing the same daemon and `RangeCache`.
