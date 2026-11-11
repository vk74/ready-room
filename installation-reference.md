# Installation reference

Companion to the [README](README.md) , a short reference for non-obvious installer settings and day-two operations.

System prerequisites (podman, cockpit, fail2ban, …) are installed only on Deploy (option 2), not when the README command or Configure (option 1) runs. Deploy also installs the Cockpit File browser (Tools) when the host package is available; option 1 does not.

Re-run `./install.sh` from `~/app/` anytime to reconfigure, apply changes, restore from backup, or uninstall.

## Host SSH vs app login

Deploy enables SSH autoban via fail2ban; application login lockout stays in the app (Valkey). Two separate lockouts:

- **Host SSH** — fail2ban jail `sshd` (kit file `/etc/fail2ban/jail.d/sshd-kit.local`). Failed SSH passwords are banned on the host.
- **Application login** — Valkey counters on `POST /api/auth/login`, response `LGN-ERR-429`. This is not fail2ban.

To allow an admin IP or Tailscale CGNAT, add it to `ignoreip` in `/etc/fail2ban/jail.d/sshd-kit.local` (for example `100.64.0.0/10`), then:

```bash
sudo fail2ban-client reload sshd
```

Note: on Ubuntu 26 / OpenSSH 10, `PerSourcePenalties` can also throttle SSH from a busy tester IP (e.g. repeated failed auth). That is unrelated to fail2ban; do not confuse it with an `sshd` jail ban.

## Settings reference

### Data storage (wizard steps 6–7)

The installer can place persistent data on separate disks to protect the OS and improve disk I/O. Mount extra drives **before** running configure ([prep guide](prepare-your-vm-for-evi-deployment.md)).

- **Step 6** — database volume (`APP_DATA_PATH` in `~/app/config/app.env`)
- **Step 7** — file storage volume (`APP_FS_DATA_PATH`; falls back to `APP_DATA_PATH` if unset)
- **Step 7 (continued)** — file storage capacity ceiling (`APP_FS_VOLUME_MAX_GB` in `~/app/config/app.env`, default **100**)

Podman volume names: **`db_data`** (PostgreSQL) and **`fs_data`** (SeaweedFS). When you pick a separate disk, data is stored under `{mount}/data/db` and `{mount}/data/fs`. Empty paths keep both volumes on the system disk (default Podman location).

DB and FS can use **different** mount points — useful when database and uploads grow at different rates.

**File storage capacity** sets the SeaweedFS `-volume.max` limit (each internal volume file is up to 1 GB). It is a **maximum capacity ceiling**, not a pre-allocated disk reservation — files grow as users upload. The installer shows free space on the selected disk and warns if the limit exceeds available space. To change later: edit `APP_FS_VOLUME_MAX_GB` in `config/app.env`, then apply/restart (option 3 in `./install.sh` or Cockpit).

### Release version (wizard step 8)

The chosen release downloads a version-matched kit archive from GitHub. Templates, Cockpit panels, and container images all come from that release — pick a specific version if you need a known baseline. Stable release versions are mnamed with numbers only (like 0.20.7), beta version have extra markers after dash (0.20.8-b1). Do not install beta versions on your production server as this may break DB schema causing manual restore operations. 

### Demo data (wizard step 5)

Optional one-time seed during first deploy. The installer disables re-seeding afterward, so restarts and updates do not reload demo content.

## Secrets

Secrets are sensitive credentials kept out of `~/app/config/app.env`. They live in `~/app/config/app.secrets.env` (created at install, not committed to git).

| Variable                | Used for                                                   |
|-------------------------|------------------------------------------------------------|
| `APP_POSTGRES_PASSWORD` | PostgreSQL superuser (`postgres`)                          |
| `APP_DB_PASSWORD`       | Application DB role used by evi (`app_service`)            |
| `APP_ADMIN_DB_PASSWORD` | Admin DB role (`evidba`) and pgAdmin login                 |
| `APP_VALKEY_PASSWORD`   | Valkey cache (`state` container)                           |
| `APP_JWT_PRIVATE_KEY`   | JWT signing — rotating it invalidates active user sessions |

**File storage credentials** are not in `config/app.secrets.env`. SeaweedFS S3 keys are stored as the Podman secret `fs_credentials`. Change them via reconfigure or a full apply/restart cycle, not a simple env edit.

### Changing secrets after installation

1. Edit `~/app/config/app.secrets.env`.
2. Apply: `./install.sh` → option 3 (*apply configuration and restart containers*), or Cockpit app admin tools → Container Environment → Apply.
3. DB password changes take effect after container restart; log in to pgAdmin again if needed. JWT changes sign everyone out.

## Tips and tricks

- Mount data disks before configure (steps 6–7) — the installer lists available mounts and recommends the largest non-system disk.
- Default app login after install: `admin` / `lock` — change the password on first login.
- Cockpit admin UI: `https://<host>:9090` with your Linux user credentials. Backups, updates, and DB tools are in the **app admin tools** panel.
- Self-signed TLS shows a browser security warning — expected for internal or IP-based installs.
- Internet is required for the release list, kit download, and container image pulls.
- Inspect volumes: `podman volume inspect db_data` and `podman volume inspect fs_data`; paths are also in `config/app.env`.
- Existing installs: `./install.sh` menu offers prerequisite repair, reconfigure, restart, restore, and uninstall.
- If deploy pauses because the host needs a reboot, reboot, then run `./install.sh` from `~/app/` and choose deploy (option 2). The saved answers stay; the fresh menu remains while `.install-config` exists, even if `config/app.env` is already there.
- The installer transcript does not print database passwords. The final summary shows `admin` / `lock` and, when demo data was seeded, demo `lock`. The pgAdmin password is `APP_ADMIN_DB_PASSWORD` in `config/app.secrets.env`.
