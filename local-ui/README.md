# local-ui — Development environment for the future Fargate jobui

> **Status: not part of the deployed HPC stack.**
>
> The HPC cluster in this repo is pure HPC — `terraform apply` does not deploy
> any web UI. Users `aws ssm start-session` into the login node and run
> `sbatch` / `snakemake` / `nextflow` directly. See the repo [README](../README.md)
> for the topology.
>
> This `local-ui/` directory exists as a development convenience for the
> **future Fargate-deployed jobui** that will be built in a later phase. The
> podman setup here lets a developer iterate on the React SPA locally against
> a (currently nonexistent) backend, so the UI is ready when the Fargate
> module ships.

## What's here

- `podman-compose.yml` — builds the frontend from `../jobui/frontend/`
- `nginx-local.conf` — serves the SPA on `localhost:3000` and reverse-proxies
  `/api/*` to `host.containers.internal:8080`

## Will it work today?

No — there is no backend listening on `:8080` once the HPC stack is deployed,
because the head node no longer runs the jobui Docker compose stack. The
backend half of jobui still lives at `jobui/backend/` as reference code, but
nothing in this repo runs it.

When the future Fargate jobui module lands:
- The backend will run on Fargate (or, for development, locally with
  `podman-compose` reading from `../jobui/backend/`)
- Local podman SPA development will work via this directory
- Tests and CI will exercise the full flow

Until then, **use the CLI**:

```bash
aws ssm start-session --target $(terraform output -raw login_node_instance_id)
# Then on the login node:
sbatch jobs/inference_job.sh
```
