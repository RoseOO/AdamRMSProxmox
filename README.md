# AdamRMS Proxmox VE Installer

One-command installer for [AdamRMS](https://adam-rms.com) on Proxmox VE.

## Usage

Run in your Proxmox VE shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/RoseOO/AdamRMSProxmox/main/adamrms.sh)"
```

## What it does

- Creates a Debian 13 LXC container
- Installs Docker + Docker Compose v2
- Prompts for MariaDB or MySQL database backend
- Deploys AdamRMS via docker-compose with health checks
- Generates secure random database credentials

## Update

From inside the container:

```bash
update_adamrms
```

Or from the Proxmox host:

```bash
pct exec <CTID> -- update_adamrms
```

## Default Resources

| Resource | Default |
|----------|---------|
| CPU | 2 cores |
| RAM | 2048 MB |
| Disk | 10 GB |

## Post-Install

- Access AdamRMS at `http://<container-ip>`
- Default login: `username` / `password!`
- **Change the default password immediately**
- Database credentials: `~/adamrms.creds` inside the container

## License

MIT
