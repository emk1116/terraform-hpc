# Local podman UI for Titan HPC

This directory runs the Titan HPC frontend on your laptop while the rest of
the stack (Slurm, FSx, Aurora, compute) lives in AWS. There is **no public
ingress** to the AWS stack — the local UI reaches the head node through an
SSM port-forwarding tunnel, so there is no ALB, no public IP, no ACM cert.

## Prerequisites

- `aws` CLI v2 with valid credentials (`aws sts get-caller-identity` works)
- The Session Manager plugin (`aws ssm start-session` must succeed)
- `podman` and `podman-compose` (or substitute `docker compose`)
- A successful `terraform apply` of the HPC stack

## Run

```bash
# Terminal 1 — SSM port-forward to the head node (leave running)
$(terraform output -raw ssm_port_forward_command)

# Terminal 2 — start the UI
cd local-ui
podman-compose up --build
```

Open <http://localhost:3000>. Sign in with the credentials from
`terraform output admin_temp_password_command` (run that command separately).
You will be redirected to `/change-password` on first login.

## Topology

```
┌───────────────────┐       ┌───────────────────┐       ┌──────────────────┐
│  Your laptop      │       │  SSM tunnel       │       │  AWS head node   │
│                   │       │  (no public IP)   │       │                  │
│  Browser ───┐     │       │                   │       │  nginx :80       │
│             │     │       │                   │       │    │             │
│  podman SPA │     │       │                   │       │    ▼             │
│  nginx :80 ─┼─────┼──:8080┼───────────────────┼──:80──┼─ jobui-backend   │
│             │     │       │                   │       │   :8000          │
│             │     │       │                   │       │                  │
│  /api/* ────┘     │       │                   │       │                  │
└───────────────────┘       └───────────────────┘       └──────────────────┘
```

- Browser sees `http://localhost:3000` for everything — same origin, no CORS
- `localhost:3000/api/*` is reverse-proxied to `host.containers.internal:8080`
- That maps to your laptop's `:8080` which is the SSM tunnel endpoint
- The tunnel forwards to the head node's port 80 (nginx → FastAPI)

## Troubleshooting

- **`Bad Gateway` from nginx** — the SSM tunnel is not running. Check Terminal 1.
- **`host.containers.internal` does not resolve** — your podman/distro doesn't
  set this automatically. Replace it in `nginx-local.conf` with the actual IP
  of your host gateway (often `10.0.2.2` on rootless podman).
- **CORS errors in browser console** — should never happen with this setup
  since the browser only talks to localhost. If you do see them, the frontend
  is bypassing the proxy and going direct to the head node.
