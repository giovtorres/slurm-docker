# slurm-docker

All-in-one [Slurm](https://slurm.schedmd.com/) container on Rocky Linux (8, 9, or 10). Runs MariaDB,
slurmdbd, slurmctld, slurmd (3 nodes), slurmrestd, and SSH in a single container.

## Quick start

```bash
cp .env.example .env
make build && make up
```

Wait ~20 seconds, then `make shell` to access the cluster.

## Supported versions

25.11.x (default), 25.05.x, 24.11.x. Switch with:

```bash
make set-version VER=24.11.7
make rebuild
```

## Configuration

All settings go in `.env` (see `.env.example`):

| Variable | Default | Description |
|----------|---------|-------------|
| `SLURM_VERSION` | `25.11.4` | Slurm version to build |
| `ROCKY_VERSION` | `10` | Rocky Linux major version (8, 9, or 10) |
| `MYSQL_USER` | `slurm` | MariaDB user |
| `MYSQL_PASSWORD` | `password` | MariaDB password |
| `EXTRA_PACKAGES` | | Additional packages to install at startup |
| `ROOT_PASSWORD` | | Set root password for SSH |
| `SSH_PERMIT_ROOT_LOGIN` | `prohibit-password` | SSH root login policy |
| `SSH_PASSWORD_AUTH` | `no` | Enable SSH password auth |

### Slurm configs

Version-specific configs in `config/{25.11,25.05,24.11}/slurm.conf`, shared configs in `config/common/`. Edit live:

```bash
docker exec -it slurm vi /etc/slurm/slurm.conf
docker exec slurm scontrol reconfigure
```

## Exposed ports

- **2222** — SSH
- **6820** — slurmrestd

## Make targets

Run `make` to see all available commands. Key targets: `build`, `up`, `down`, `clean`, `rebuild`, `shell`, `test`, `status`, `logs`.

## Multi-arch builds

```bash
docker buildx build --platform linux/amd64,linux/arm64 .
```

## Adding a new Slurm version

1. Create `config/XX.YY/slurm.conf`
2. Add to `SUPPORTED_VERSIONS` in `Makefile`
3. Add to CI matrix in `.github/workflows/test.yml`
