# Product & Architecture Analysis: Signal-Grade Privacy and File Sharing Over Restrictive Storage Backends

This document outlines:
1. What is missing to make `vault` compelling (and worth paying for) to **Signal** users, including cryptographic agility.
2. How to solve **end-to-end encrypted file sharing** when the underlying filesystem (e.g., Google Drive) denies access by default and enforces folder/object ACLs.

---

## 1. What Would Make a Signal User Adopt (or Pay for) `vault`

The current cryptographic core (`MLKEM768-X25519` + `XChaCha20-Poly1305` + per-file `File_DEK` + `HKDF-SHA256` per-part keys in [Crypto.zig](../../lib/vfs/src/Crypto.zig)) is a strong foundation. To reach Signal-level trust and usability, the following pieces are missing:

### 1.1 Cryptographic Agility (Negotiable Ciphersuites & Signatures)
- Currently, algorithms are hardcoded (`HybridKem = MlKem768X25519`, `XChaCha20Poly1305`, `HkdfSha256`).
- Add a `cipher_suite_id` field to the catalog metadata and to `GdrvPartHeader` ([Crypto.zig](../../lib/vfs/src/Crypto.zig#L187-L197)) so vaults/files can select profiles cleanly:
  - `MLKEM768-X25519 + XChaCha20-Poly1305` (default portable).
  - `MLKEM768-X25519 + AES-256-GCM` (hardware-accelerated via AES-NI / ARMv8 on mobile & laptops).
  - `MLKEM1024 + AES-256-GCM / XChaCha20-Poly1305` (high-assurance profile).
- **Post-quantum / hybrid signatures (`Ed25519 + ML-DSA`)**: AEAD provides authenticated encryption, but **there are no authorship signatures**. In multi-user or shared folders, recipients need to verify *who* wrote or updated a file or sub-catalog without trusting the storage provider.

### 1.2 Verifiable Identities & Safety Numbers
- Today `device_id` is an arbitrary string (e.g. `"vault-desktop-01"`).
- Signal users expect a persistent **identity keypair** and a **Safety Number / QR fingerprint** so contacts and linked devices can be verified out-of-band without trusting Google, Apple, or any central directory.

### 1.3 Frictionless Device Linking, Recovery, and Revocation
- **Device linking via QR**: an existing unlocked device wraps the `VMK` for a newly scanned device's public key (`addMember`).
- **Offline recovery phrase (e.g. 24 words)**: unlike messaging, losing all devices in a VFS means losing your files permanently.
- **True revocation with VMK rotation**: deleting a key slot must rotate the `VMK`, re-wrap all `File_DEK`s and `credentials_wrapped`, and re-seal the catalog.

### 1.4 Metadata Minimization ("Sealed Sender" Philosophy)
- Never persist plaintext SQLite metadata (`./data/vault_catalog.db`) or decrypted files in `/tmp` ([read_data.zig](../src/tasks/read_data.zig#L211)).
- Obfuscate `vfs_id` in Google Drive `appProperties` ([api.gdrive.yaml](../configs/api.gdrive.yaml#L93)) using `HMAC(VMK, vault_id)`.
- Optional **size padding** on `.part` / `.pack` blobs so storage providers cannot fingerprint file types by exact byte length.

### 1.5 Plausible Deniability / Duress Partitions
- `PartitionManager` ([PartitionManager.zig](../src/PartitionManager.zig)) already separates logical partitions (`official_docs`, `archives`).
- Supporting **per-partition keys** and a **duress PIN/key** (which unlocks only a decoy partition while concealing the existence of hidden partitions) is a major differentiator for high-risk users.

### 1.6 Why Users Would Pay
1. **Encrypted multi-cloud pooling (BYOS)**: aggregate multiple free Google Drive, S3, or NAS accounts into one seamless encrypted drive without vendor lock-in.
2. **Instant encrypted streaming** (`Range` requests over 256 KiB pages via [stream.zig](../src/tasks/stream.zig)) integrated with native OS file providers (macOS File Provider / Windows Cloud Filter / iOS Files).
3. **Optional "Blind Relay" subscription**: a hosted, zero-knowledge relay for push notifications, async share invitations, and proxied transfers when underlying storage blocks external sharing—without the relay ever seeing keys or plaintext.

---

## 2. Solving File Sharing When the Underlying FS Blocks Access by Default

In Google Drive (and most private object stores), objects uploaded by Alice's account/Service Account are **private (`403 Forbidden` to everyone else)** by default. Sharing requires strictly separating the **cryptographic layer** from the **underlying FS access layer**.

### Golden Rules at the Cryptographic Layer
1. **Never share the `VMK` or Alice's OAuth/SA credentials** for partial sharing.
2. **Never mix private and shared files in the same `.pack` blob** ([Packer.zig](../../lib/vfs/src/Packer.zig)): sharing a `pack_*.pack` that bundles 1 shared file with 10 private files leaks ciphertext, existence, and metadata of private files. Packing must be scoped by `partition_id` / `share_scope`, or shared files must be written as standalone `.part` objects.
3. **Share scoped capabilities only**:
   - **Single file**: wrap the file's `File_DEK` along with its extent manifest (`node_id`, `object_id`, `inode_ulid`, `cipher_suite`, byte ranges) either to Bob's public key (`MLKEM768-X25519`) or to an ephemeral key placed in a URL `#fragment` (never sent to HTTP servers).
   - **Shared folder / partition**: create an isolated **sub-catalog** (`.vfssubcat`) encrypted with its own `Folder_MK` (`FMK`) and its own `vault_key_slots` list for participants.

### Solving the Underlying FS `403` / ACL Problem (3 Strategies)

#### Strategy A: Delegated Native Drive ACLs (Zero-Copy, Direct Download)
1. Alice's client places/moves the shared `.part` blobs into a dedicated Drive share folder and calls Drive's permissions API (`POST /drive/v3/files/{fileId}/permissions`) granting `role: reader` (or `writer`) **only on those specific ciphertext `object_id`s** to Bob's Google account (or `type: anyone` for `#fragment`-keyed E2EE links).
2. Alice sends Bob (via Signal or an encrypted mailbox) the capability manifest containing the wrapped `File_DEK` and `object_id`s.
3. Bob's `vault` client uses **Bob's own OAuth token** to fetch `getObject` / `getRange` directly from Google Drive.
- **Pros:** zero server bandwidth cost, full Google CDN speed, native `Range` streaming.
- **Cons:** leaks social graph metadata to Google (Alice shared `fileId` with Bob), and Workspace/Service Account policies may forbid external sharing.

#### Strategy B: Declarative Shared Storage Node ("Shared Drive / Shared Bucket")
- For recurring collaborators (teams, families), Alice and Bob declare a shared node in `vault.yaml` that both already have underlying FS access to (e.g., a **Google Shared Drive**, an S3/R2 bucket with scoped IAM prefixes, or a shared NAS/WebDAV).
- Using `PartitionManager` (`pinned_node` / `allowed_nodes`), the shared partition always writes to that node.
- **Pros:** zero per-file ACL churn on upload/delete; works naturally with multi-writer sub-catalogs.

#### Strategy C: Blind E2EE Dropzone or Capability Proxy (When Drive Blocks External Access)
Used when Alice's backend/organization **forbids** external ACLs or Bob has no Google account:
1. **Dropzone mode (Signal-style async attachments):**
   - Alice's client encrypts the file under a fresh `File_DEK` for Bob and uploads the `.part` blobs to an **encrypted temporary dropzone** (e.g. a blind S3/R2 relay with TTL, or an "Inbox" node Bob can read).
   - Bob downloads, verifies Alice's signature, imports into his own vault, and the ephemeral blobs are deleted.
2. **Capability-scoped proxy (zero duplicate storage):**
   - Alice's daemon (or a stateless relay holding a scoped token) exposes `GET /share/{capability_token}/{object_id}` over **PQ-TLS**, serving **still-encrypted** `.part` byte ranges from Alice's Drive only for the `object_id`s authorized by that capability. Bob decrypts locally.

### Recommended Rollout for `vault`
1. Scope `Packer` by `partition_id` / `share_scope` so private and shared files never share a `.pack`.
2. Implement **Strategy B** first (naturally follows declarative nodes + `pinned` partitions in `vault.yaml`).
3. Add **Strategy A** by adding a `create_permission` endpoint to [api.gdrive.yaml](../configs/api.gdrive.yaml) for ad-hoc Drive-to-Drive sharing.
4. Keep **Strategy C (Blind Relay / Dropzone)** as a fallback or paid tier when underlying storage forbids ACL sharing.
