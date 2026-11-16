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

### Option 5 — Terminal UI (TUI) + Pipe/Streaming Egress to OS Applications
- **How it works**: lightweight CLI/TUI binary (`vault-tui`) in 100% Zig communicating with daemon HTTP tasks (`vault_ls`, `vault_stream`, `vault_quotas`, `vault_gc`). Opens/streams directly into system utilities (`mpv -`, `vlc -`, `zathura -`, `glow -`, `bat -`, `less`).
- **Pros**:
  - **Zero web dependencies**: no Node, no npm, no bundler, no WebView runtime.
  - **Instant streaming**: leverages on-demand range chunks (`256 KiB`) over stdout pipes or HTTP `Range` without waiting for full download or decrypt.
  - **Reuses OS tooling**: zero custom viewers needed for video, audio, PDFs, markdown, or text files.
  - Interactive terminal navigation (keyboard shortcuts `j`/`k`, `Enter`, `g` for GC, `r` for refresh).
- **Cons**:
  - Sequential stdin pipes cannot do random seek for complex archive-based formats (like `.docx`); those require HTTP `Range` streaming or temporary file cache.

---

## Summary Matrix

| Criterion | 1. Web SPA (TS) | 2. Tauri + Web UI | 3. Embedded HTML/JS | 4. Native Zig GUI | 5. TUI + Pipes (Zig) |
| :--- | :---: | :---: | :---: | :---: | :---: |
| Development speed | High | High | Very high (MVP) | Medium/Low | **Immediate** |
| `<video>`/`Range` streaming | Native | Native | Native | External (`mpv`/`vlc`) | **Pipe to `mpv -` / HTTP** |
| Tray icon / Desktop sync | No | **Yes** | No | Possible | CLI / Daemon daemonized |
| Build dependencies | Node/Bun | Node/Bun + Rust | **None** | C/Zig UI libs | **Zig compiler only** |
| Reusable over LAN/remote | **Yes** | Desktop only | **Yes** | No | **Yes (SSH / headless)** |

---

## Recommendation

1. **Start with Option 5 (TUI + Streaming Pipes / Egress)** to have an instant, zero-dependency client in 100% Zig that lets you browse the vault, check quotas/metrics, run GC, and pipe decrypted streams on-the-fly to existing system viewers (`mpv`, `glow`, `zathura`, `less`).
2. **Add Option 1 / 3 (Web UI)** when a visual graphical browser is desired, and **Option 2 (Tauri)** for MVP 3 when desktop system tray and folder-sync watcher are required.
