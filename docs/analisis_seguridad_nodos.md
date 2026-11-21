# Analysis: User Management, Transport PQC, Node Assignment & Startup Responsiveness

Scope: `vault/src`, `vault/configs`, and `lib/vfs/src`. I **could not** inspect the `rest_api` driver (it lives in `../sdk` / `../extension`), so any remarks about TLS are limited to what is visible in this codebase.

---

## 1. User / Device Management (Concern #1) — Confirmed

### Current State
- The cryptographic foundation is solid: `VMK` is wrapped per device using `MLKEM768-X25519` ([Crypto.zig](../../lib/vfs/src/Crypto.zig#L10-L52)), and per-file DEKs are wrapped with the VMK.
- `CatalogPort` already provides `putKeySlot` / `getKeySlot` / `deleteKeySlot` ([CatalogPort.zig](../../lib/vfs/src/CatalogPort.zig#L15-L17)).

### Gaps & Issues
| # | Issue | Location |
|---|---|---|
| U1 | Only **one** key slot (the admin's) is created in `initVault`. `Vault` has no API to add or revoke a second device/user. `deleteKeySlot` is only used in the conformance test. | [Provisioner.zig#L89-L97](../../lib/vfs/src/Provisioner.zig#L89-L97) |
| U2 | No VMK rotation. Revoking a device without rotating the VMK is ineffective because the revoked device already knows the VMK. | — |
| U3 | No roles (admin / write / read-only) and no user identity separate from the device (`slot_id == label == device_id`). | [Provisioner.zig#L90-L96](../../lib/vfs/src/Provisioner.zig#L90-L96) |
| U4 | **Critical:** `Vault.open(...) catch try Vault.create(...)`. Any error when opening (network failure, wrong key, corrupted catalog, device without a slot) **creates a brand-new vault** with the same `vault_id` and uploads a new `.vfscat`. An unauthorized device ends up creating a parallel vault instead of failing. | [VaultState.zig#L136-L158](../src/VaultState.zig#L136-L158) |
| U5 | `device.key` is stored in plaintext (`pk‖sk`) with default permissions, and **write errors are silently ignored** (`catch {}`). If it cannot be persisted, every mount generates a new key → `open` fails → U4 creates another vault. | [VaultState.zig#L202-L218](../src/VaultState.zig#L202-L218) |
| U6 | Slot AAD is only `device_id`, not bound to `vault_id`. Binding to `vault_id‖slot_id` prevents cross-vault slot reuse. | [Crypto.zig#L27-L45](../../lib/vfs/src/Crypto.zig#L27-L45) |
| U7 | Workaround overriding `device_id` when it equals `"vault-desktop-01"`. | [container.zig#L40](../src/container.zig#L40) |

### Proposal
- `Vault.addMember(device_id, pk, role)`: an already-unlocked device wraps the VMK for the new `pk` → `putKeySlot`.
- `Vault.revokeMember(device_id)`: `deleteKeySlot`, generate a **new VMK**, re-wrap all DEKs in the catalog (metadata only, no data re-upload), re-wrap the VMK for remaining slots, and re-wrap `credentials_wrapped`.
- Add `role` and `added_by` to `vault_key_slots` and enforce the role in write tasks.
- In `mountConfiguredVault`: only call `create` when `discoverCatalogObjectId` returns `CatalogNotFound`. Propagate all other errors.
- `device.key`: use mode `0600`, fail on write errors, and optionally seal it with a passphrase or the OS keyring.

---

## 2. Transport-Layer PQC (Concern #2) — Confirmed

- PQC is currently applied **only at rest** (VMK wrapping). Data and catalog use XChaCha20-Poly1305 (symmetric, already quantum-resistant). Searching `tls|https|transport` in `lib/vfs/src` yields nothing: the library delegates all transport to the driver.
- Content is already protected end-to-end even over classical TLS. What remains exposed to "harvest-now-decrypt-later" over classical TLS is:
  - OAuth tokens / service account JWT assertions.
  - Plaintext metadata: `appProperties` with `vfs_role=catalog` and `vfs_id={vault_id}` in Drive ([api.gdrive.yaml#L93](../configs/api.gdrive.yaml#L93)), object names (`{inode}_{n}.part` / `pack_*.pack`), sizes, and access patterns.
- Future REST APIs (MVP 1) and `inbound_http` / `stream.zig` serve **decrypted plaintext** — this is where transport security matters most.

### Proposal
1. Check which TLS groups the `rest_api` driver offers (negotiating hybrid `X25519MLKEM768` if supported by the TLS stack) and expose a declarative setting, e.g. `tls: { min_version: "1.3", groups: [X25519MLKEM768], require_pq: true }`. **Not verified** because the driver source is outside this scope.
2. For the daemon↔client channel (REST/stream/inter-device sync): TLS 1.3 with hybrid PQ key exchange, or a custom Noise-like channel reusing `HybridKem` with device keys as identities.
3. Reduce plaintext metadata: replace `vfs_id` with `HMAC(VMK, vault_id)` (`HMAC(device_key)` would not work because other devices must still be able to discover the catalog).

---

## 3. Google Drive Account-to-Node Assignment (Concern #3) — Confirmed

### Why It Is Currently Neither Declarative Nor Deterministic
| # | Issue | Location |
|---|---|---|
| N1 | Node ID is hardcoded to `"user-01"` and the vault is created with a **single** node. | [VaultState.zig#L132](../src/VaultState.zig#L132), [L155](../src/VaultState.zig#L155) |
| N2 | There is only one `gdrive_primary` datasource with a single `node_id` and `credentials`. The adapter passes `node_id` as a filter prefix (`"node:obj"`), so every `node_id` hits the same handle and credentials. | [pipeline.yaml#L43-L50](../configs/pipeline.yaml#L43-L50), [RepoBlobStoreAdapter.zig#L156](../../lib/vfs/src/RepoBlobStoreAdapter.zig#L156) |
| N3 | `sa_keys_dir`, `user_key_path`, and `bootstrap_cred` are parsed but **unused anywhere** in `src/`. | [config.zig#L160-L168](../src/config.zig#L160-L168) |
| N4 | `NodeConfig.secret_config` (credentials wrapped with the VMK) is never populated: `credentials_wrapped` encrypts an empty string. | [Provisioner.zig#L13-L17](../../lib/vfs/src/Provisioner.zig#L13-L17) |
| N5 | `PartitionUploadPolicy` supports `allowed_node_ids` and `pinned_node_id`, but the `vault.yaml` parser does not read them and `container.zig` passes `&.{}`. `pinned_node_id` is never set, so the `pinned` policy **always returns null** and uploads fail. | [config.zig#L200-L210](../src/config.zig#L200-L210), [container.zig#L57-L66](../src/container.zig#L57-L66), [PartitionManager.zig#L84-L88](../src/PartitionManager.zig#L84-L88) |
| N6 | **Source of non-determinism:** `listStorageNodes` reads `storage_nodes` with an empty filter and no ordering. `first_fit`, `most_available` tie-breaking (strict `>`, so first wins), primary-node fallback (`nodes[0]`), and `initVault` primary selection all depend on that order. Additionally, `random` is non-deterministic by design. | [RepoCatalogAdapter.zig#L262-L274](../../lib/vfs/src/RepoCatalogAdapter.zig#L262-L274), [PoolAllocator.zig#L135-L146](../../lib/vfs/src/PoolAllocator.zig#L135-L146), [VfsSession.zig#L115-L117](../../lib/vfs/src/VfsSession.zig#L115-L117), [Provisioner.zig#L124](../../lib/vfs/src/Provisioner.zig#L124) |
| N7 | `writePacked` does not use the partition's upload policy (only `.auto_pack_enabled = true`). Packed uploads ignore `allowed_nodes`. | [write_data.zig#L60](../src/tasks/write_data.zig#L60) |
| N8 | `CompositeBlobStore` (routing by `node_id` to distinct backends) exists in `lib/vfs`, but `vault` does not use it. | [CompositeBlobStore.zig](../../lib/vfs/src/CompositeBlobStore.zig) |
| N9 | If `get_quota` omits `limit`, it defaults to `u64::MAX`. An "unlimited" (or misparsed) account attracts all uploads under `most_available`. | [api.gdrive.yaml#L19](../configs/api.gdrive.yaml#L19) |

### Proposed Declarative Schema (`vault.yaml`)
```yaml
vault:
  id: default
  nodes:                       # list order = deterministic priority
    - id: gdrive:sa-01
      datasource: gdrive_sa01  # one rest_api datasource per account
      credentials: ./configs/sa_keys/vfs-sa-01.json
      catalog_role: primary
    - id: gdrive:sa-02
      datasource: gdrive_sa02
      credentials: ./configs/sa_keys/vfs-sa-02.json
      catalog_role: replica
    - id: gdrive:user
      datasource: gdrive_user
      credentials: ./configs/user_keys/oauth_user.json

partitions:
  - name: official_docs
    upload_policy: pinned
    pinned_node: gdrive:sa-01
  - name: archives
    upload_policy: most_available
    allowed_nodes: [gdrive:sa-02, gdrive:user]
```
Required changes:
1. `config.zig`: parse `nodes[]`, `allowed_nodes`, and `pinned_node`.
2. `VaultState.mountConfiguredVault`: build a `CompositeBlobStore` with one `RepoBlobStoreAdapter` per datasource, pass all `NodeConfig` entries (with `secret_config` = credentials) to `Vault.create`, and select the primary node from config instead of `"user-01"`.
3. Reconcile on mount: nodes present in config but missing from `storage_nodes` → add; removed nodes → mark `status = draining` (do not delete).
4. Determinism: sort `listStorageNodes` by `node_id` (or an explicit `priority` column) and break ties by `node_id` in `selectMostAvailableAccount`.
5. Propagate the partition's `upload_policy` to `writePacked` as well.

---

## 4. Startup Unresponsiveness & In-Memory Catalog

### Root Cause
With a small catalog (e.g. 2 files), startup unresponsiveness is **not** caused by decrypting file data — no file contents are decrypted at startup, only the single `.vfscat` catalog snapshot ([Provisioner.zig#L169-L212](../../lib/vfs/src/Provisioner.zig#L169-L212), [SyncCoordinator.zig#L111-L132](../../lib/vfs/src/SyncCoordinator.zig#L111-L132)).

The UI freezes because **synchronous network and DB I/O run on the TUI thread before the event loop starts**:
1. `VaultAppCtx.onStart` ([tui_plugin.zig#L839-L848](../src/tui_plugin.zig#L839-L848)) synchronously dispatches `ls` and `quotas` before entering key/event polling.
2. The first `ls` triggers [getOrMountVault](../src/container.zig#L34-L69) (holding the `global_state_lock` spinlock) and [mountConfiguredVault](../src/VaultState.zig#L134-L172), chaining sequential HTTPS roundtrips to Google Drive (`discoverCatalogObjectId` → `getObject`, plus `createPartition` `mkdir` commits if partitions are not yet in the catalog).
3. After decrypting the snapshot, [importSnapshotImpl](../../lib/vfs/src/RepoCatalogAdapter.zig#L605-L623) performs 4 `clear_table` calls followed by **one individual `write_row` per `storage_node`, `inode`, `extent`, and `pending_gc`** without wrapping them in a single transaction. While negligible for 2 files, this becomes a disk-fsync bottleneck as the catalog grows.

### Proposal
1. **Asynchronous TUI mount/load (eliminates the UI freeze):** Render the TUI immediately with a `"Mounting / loading..."` state and run the initial `mount`, `ls`, and `quotas` dispatches on a background worker thread, updating panels via the tick loop once ready so keyboard input (`q`, navigation) remains responsive from millisecond 0.
2. **In-memory catalog (security + scalability):** Since the catalog is downloaded and decrypted on every startup anyway, keeping an on-disk `./data/vault_catalog.db` provides no real persistence and leaves plaintext metadata on disk. Switch `vfs_catalog_db` in [pipeline.yaml#L36-L40](../configs/pipeline.yaml#L36-L40) to `:memory:` or use `lib/vfs`'s built-in [InMemoryCatalog.zig](../../lib/vfs/src/InMemoryCatalog.zig) directly. (Note: this alone will not fix the startup freeze without async TUI loading, since HTTPS roundtrips dominate for small catalogs.)

---

## 5. Minor Findings
- `open` writes the **decrypted** file to `/tmp/vault-{inode}-{name}` (world-readable depending on umask, never cleaned up). [read_data.zig#L211](../src/tasks/read_data.zig#L211)
- Hardcoded `1700000000` timestamps in mount, partitions, write, rename, and delete (affects `mtime`, leases, and GC).
- `createPartition(...) catch {}` silently swallows partition provisioning errors. [container.zig#L66](../src/container.zig#L66)

## Suggested Order of Work
1. **U4 + U5:** Prevent phantom vaults (small, high-impact fix in `VaultState.zig`).
2. **Startup responsiveness:** Async TUI `onStart` / background load + in-memory catalog (`:memory:` or `InMemoryCatalog`).
3. **N5 + N6 + N1/N3/N8:** Declarative and deterministic node assignment.
4. **U1–U3, U6:** Members, roles, and revocation with VMK rotation.
5. **Transport:** Inspect `rest_api` driver, add `tls` config, and PQ daemon channel.
