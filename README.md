# n8n Custom Node Upload — one-command installer

Add an **"Upload your own node (.tgz)"** control to your self-hosted **n8n**, so you (or your users) can install custom community nodes straight from the browser — **no rebuilds, no image changes, no restart**.

Uploaded packages become **real community nodes**: they show up in **Settings → Community Nodes** with n8n's own **uninstall / update** buttons, and load **instantly** on modern n8n via native integration.

> It uses only n8n's official extension points — `EXTERNAL_HOOK_FILES` (backend) and `EXTERNAL_FRONTEND_HOOKS_URLS` (frontend). **The n8n Docker image is never modified.** Everything lives in the `.n8n` data volume, so it survives container updates.

---

## Install (one command)

SSH into the server running n8n and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/AakashKhambhaliya/n8n-custom-node-upload/main/install-custom-node-upload.sh | bash
```

The script auto-detects your n8n container and Docker Compose project, drops the hook files into the data volume, writes a `docker-compose.override.yml`, and restarts n8n.

At the end it prints an **ADMIN TOKEN** — **save it**. You'll paste it once in the browser the first time you upload a node.

## Uninstall (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/AakashKhambhaliya/n8n-custom-node-upload/main/uninstall-custom-node-upload.sh | bash
```

Or, equivalently, run the installer with a flag:

```bash
curl -fsSL https://raw.githubusercontent.com/AakashKhambhaliya/n8n-custom-node-upload/main/install-custom-node-upload.sh | bash -s -- --uninstall
```

This removes the hooks and the override file and restarts n8n. **Nodes you already installed keep working** and remain manageable in Settings → Community Nodes.

---

## How to use it

1. In n8n, go to **Settings → Community Nodes → Install**.
2. In the install popup you'll now see **"Upload your own node (.tgz)"**.
3. Choose a `.tgz` produced by `npm pack` and click **Upload & install**.
4. First upload only: paste the **ADMIN TOKEN** the installer printed.
5. On modern n8n it goes live immediately. (On older n8n a **Restart n8n** button appears — click it once.)

### Building a `.tgz` from a node project

```bash
cd your-n8n-node-project
npm install
npm run build      # must produce the compiled files listed under "n8n.nodes"
npm pack           # creates your-node-1.0.0.tgz  <-- upload this
```

The uploaded package must be a valid n8n node package — its `package.json` needs an `n8n` section listing the built `nodes` (and optionally `credentials`) files. The installer validates this and rejects anything that isn't a real node package or is missing its built files.

---

## Requirements

- n8n running in **Docker** (Docker Compose recommended — Hostinger's n8n VPS template works out of the box).
- Shell access to the host (SSH).
- `curl` (or `wget`) on the host.

## Verify it's live

```bash
curl -s http://localhost:5678/rest/custom-nodes/status
# {"ok":true,"feature":"custom-node-upload","native":true,"tokenConfigured":true}
```

- `native: true`  → live install/uninstall with no restart.
- `native: false` → fallback mode (installs to `~/.n8n/nodes`, needs a one-time restart per node). Everything still works.

---

## Security notes

- Every install/remove/restart call requires the **admin token** (`x-custom-node-token` header). Keep it private — anyone with it can install code that runs inside your n8n process.
- Uploads are size-capped (50 MB) and installed with `npm install --ignore-scripts`, so package lifecycle scripts don't execute during install.
- Only expose n8n over HTTPS. The token is sent as a header, so TLS matters.
- Only upload nodes you trust. A node's code runs with your n8n's privileges.

## Endpoints added (all under `/rest/custom-nodes/`)

| Method | Path        | Auth  | Purpose                                  |
|--------|-------------|-------|------------------------------------------|
| GET    | `/status`   | none  | Health/mode check                        |
| GET    | `/list`     | none  | List uploaded packages                   |
| GET    | `/ui.js`    | none  | Serves the frontend upload widget        |
| POST   | `/install`  | token | Install an uploaded `.tgz`               |
| POST   | `/remove`   | token | Remove a package                         |
| POST   | `/restart`  | token | Restart n8n (fallback mode only)         |

---

## Troubleshooting

- **"No running n8n container found"** — start n8n first (`docker ps` should list it).
- **Upload widget doesn't appear** — hard-refresh the browser; confirm the container restarted after install; check `docker logs <container>` for `[custom-node-hooks] routes registered`.
- **"CUSTOM_NODE_ADMIN_TOKEN not set on server"** — the container didn't pick up the env var; re-run the installer, or `docker compose up -d` in the compose directory.
- **Container isn't compose-managed** — the installer prints the three `-e` flags to add when you recreate the container manually.

## License

MIT — see [LICENSE](LICENSE).
