# AdamRMS Proxmox VE Installer

One-command installer for [AdamRMS](https://adam-rms.com) on Proxmox VE, built in the style of [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE).

## What it does

Creates a Debian 13 LXC container and installs AdamRMS with a database backend inside Docker:

- AdamRMS (ghcr.io/adam-rms/adam-rms:latest)
- MariaDB or MySQL (you choose during install)
- Docker + Docker Compose v2
- Automatic database creation and health checking

## Usage

### Fresh Install

Run in your Proxmox VE shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/RoseOO/AdamRMSProxmox/main/ct/adamrms.sh)"
```

### Update

From inside the LXC container, run:

```bash
update_script
```

Or via the Proxmox shell:

```bash
pct exec <CTID> -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/RoseOO/AdamRMSProxmox/main/install/adamrms-install.sh)"
```

## Default Resources

| Resource | Default |
|----------|---------|
| CPU | 2 cores |
| RAM | 2048 MB |
| Disk | 10 GB |
| OS | Debian 13 |

## Post-Install

- Access AdamRMS at `http://<container-ip>`
- Default login: `username` / `password!`
- **Change the default password immediately**
- Database credentials are stored in `~/adamrms.creds`

## Database

Choose between MariaDB (LTS) or MySQL 8.0 during installation. Both are configured with:
- Automatic database creation
- Persistent volume (`adamrms_db_data`)
- Health checks before AdamRMS starts

## License

MIT - see LICENSE
