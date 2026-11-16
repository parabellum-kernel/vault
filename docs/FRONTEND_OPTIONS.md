# Frontend Options for Vault (MVP 2)

> Analysis of alternatives for the **Vault** graphical interface connected to the local backend (`flowdata-engine` + `inbound_http` on `127.0.0.1:8787` + `libvault.so`).

---

## Key UI Requirements for Vault
1. **Dropbox-style VFS explorer**: folder tree, upload (drag & drop / file picker), rename, delete, and logical partition selector.
2. **Preview / `HTTP Range` streaming**: play video/audio or view PDFs/images instantly without downloading the entire file.
3. **Real-time observability**: quota bars per node/partition, API unit consumption (60 s), `RangeCache` hits/misses, job queue, and `runGc` button.
4. **Desktop experience** *(optional in a later phase)*: system tray icon, native synced-folder picker, and daemon autostart.

---

## Options Comparison

### Option 1 — Web UI SPA (TypeScript + Vite + React / Solid / Svelte)
- **How it works**: web application consuming the REST/SSE API on `127.0.0.1:8787` (the same routes as Postman/Insomnia).
- **Pros**:
  - Native media playback with `<video src="http://127.0.0.1:8787/stream/..." controls>` using the browser's HTTP `Range` support with no extra code.
  - File/folder drag & drop, tables, and observability charts are very fast to build.
  - Aligned with the ecosystem's Webapp/TypeScript pattern (`ARCH-032`).
  - Can be opened either in a browser or inside a native window (Option 2).
- **Cons**:
  - Requires a JS/TS toolchain (`npm`/`bun`/`pnpm`) to build the frontend.
  - In a pure browser there is no system tray or daemon autostart.

### Option 2 — Desktop App with Tauri v2 (Web UI + Native Shell)
- **How it works**: wraps the exact Web UI from Option 1 in an OS-native WebView (without bundling Chromium like Electron).
- **Pros**:
  - Lightweight binary (~10 MB) with a **Dropbox-style tray icon**, native notifications, and native local folder dialogs.
  - Can automatically launch and supervise the daemon/engine process when the app opens.
  - Reuses 100% of the Option 1 frontend code.
- **Cons**:
  - Adds Rust/Cargo to the build if you compile the desktop shell.

### Option 3 — Minimalist Embedded Web UI (HTML + CSS + Vanilla JS / Preact / HTMX without bundler)
- **How it works**: a few static files (or embedded in Zig with `@embedFile`) served directly at `http://127.0.0.1:8787/`.
- **Pros**:
  - **Zero `node_modules`**, zero bundler, single-package deployment.
  - Ideal for a quick control panel/explorer from day one.
- **Cons**:
  - If the UI grows significantly (virtualized tree, multiple modals, filters, per-file sync status), maintaining untyped JS without components becomes heavier.

### Option 4 — Native Zig GUI (DVUI / Raylib / Dear ImGui / GTK)
- **How it works**: interface compiled directly in Zig communicating with the daemon or `DaemonState`.
- **Pros**:
  - 100% Zig, no WebView or JavaScript, minimal RAM usage.
- **Cons**:
  - No built-in video/PDF player (for `Range` streaming you would have to launch external `mpv` or `vlc`).
  - More manual effort for modern file explorers, drag-and-drop, and rich tables.

---

## Summary Matrix

| Criterion | 1. Web SPA (TS) | 2. Tauri + Web UI | 3. Embedded HTML/JS | 4. Native Zig GUI |
| :--- | :---: | :---: | :---: | :---: |
| Development speed | High | High | Very high (MVP) | Medium/Low |
| `<video>`/`Range` streaming | Native | Native | Native | External (`mpv`/`vlc`) |
| Tray icon / Desktop sync | No | **Yes** | No | Possible |
| Build dependencies | Node/Bun | Node/Bun + Rust | **None** | C/Zig UI libs |
| Reusable over LAN/remote | **Yes** | Desktop only | **Yes** | No |

---

## Recommendation

1. **Start with Option 1 (TypeScript Web UI)** — or **Option 3** if you want 0 JS dependencies at the start — targeting `http://127.0.0.1:8787`. This lets you validate all tasks (`vault_ls`, `vault_upload`, `vault_read`, `vault_quotas`, `vault_metrics`, `vault_gc`) and `Range` streaming immediately.
2. **Move to Option 2 (Tauri)** when entering **MVP 3 (Dropbox-style syncer)** and you need a tray icon, native folder picker, and automatic desktop daemon management.
