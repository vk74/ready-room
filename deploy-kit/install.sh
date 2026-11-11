#!/usr/bin/env bash
# Version: 0.27.4
# Purpose: Interactive installer for application production deployment (images-only; no build).
# Deployment file: install.sh
# Logic:
# - Single entry point: main_menu() always.
# - Interactive start opens the wizard without apt; host packages are installed only in
#   deploy_full() from prerequisites.conf (option 2).
# - Fresh install (no config): 2-step flow — 1) configure (collect all settings including version),
#   2) deploy (download kit, install prerequisites, apply config, start containers).
# - Existing install (CONFIG_EXISTS=1 and INSTALL_CONFIG_EXISTS=0): manage deployment — check prerequisites,
#   reconfigure, restart, restore from backup, uninstall. While .install-config exists, the fresh 2-step
#   menu stays even if both env files exist.
# - Non-interactive: __cockpit_apply_restart re-runs run_deploy_init + systemctl restart without prompts (Cockpit admin panel).
# - Non-interactive: __continue_deploy resumes deploy_full() after exec re-launch with version-matched installer.
#
# Changes in v0.27.4:
# - Default APP_INSTALL_REPO is vk74/ready-room.
# - load_deploy_env() rewrites an empty or legacy install repository (owner vk74, repository evi) to the kit template value and saves it in config/app.env.
# - guided_setup() saves APP_INSTALL_REPO from the kit template into config/app.env on every save.
# - restore_sync_deploy_kit() downloads the latest kit from APP_INSTALL_REPO when the backup version is missing there and the host kit is incomplete.
# - execute_restore() rebinds restored env, kit scripts, and package.json to APP_INSTALL_REPO so an older archive cannot leave that legacy repository in place.
#
# Changes in v0.27.2:
# - Use APP_INSTALL_REPO for bootstrap github-auth.sh download, release tag listing, and kit archive download; export APP_INSTALL_REPO in load_deploy_env().
#
# Changes in v0.26.3:
# - Cockpit app-admin install goes through install_cockpit_app_admin_panel(), which calls
#   scripts/host/cockpit-panel-sync.sh --sync-only --sudo-mode=interactive.
# - Kit scripts are invoked from scripts/host, scripts/admin, scripts/tls, and scripts/lib.
# - Bootstrap downloads scripts/lib/github-auth.sh from the Contents API, then from
#   raw.githubusercontent.com. ensure_executable marks every scripts/**/*.sh executable.
#
# Changes in v0.26.2:
# - De-brand runtime paths, filenames, and user-visible product name to application/app.
# - Read and write APP_* configuration keys.
# - Cockpit admin panel installs from cockpit-app-admin into /usr/local/share/cockpit/app-admin.
# - Install, kit download, guided setup, and restore use config/app.env and config/app.secrets.env.
# 
# Changes in v0.25.4:
# - Runtime config is config/app.env and config/app.secrets.env (templates app.template.env and app.secrets.template.env).
# - When the new templates are on disk, rename leftover config/evi.env and config/evi.secrets.env before the existing-install check.
# - download_release_kit_archive copies app.template.env to config/app.env, or an older kit's evi.template.env to config/evi.env.
# - execute_restore renames a restored evi.env / evi.secrets.env to app.env / app.secrets.env when the new names are absent.
#
# Changes in v0.25.3:
# - When this deploy seeded demo data, the final summary shows demo account status active and password lock in the same green field format as the admin password, plus an IMPORTANT note to change those passwords on a production install.
#
# Changes in v0.25.2:
# - Restore selects the newest data archive by modification time and parses versions that contain dots. The evi-v archive for that exact version is preferred.
# - Restore wipes an existing installation before import (config/backup is kept) and synchronizes the deploy kit to the backup version before prerequisites are installed.
# - Quadlet network startup uses network-network.service. Volume units start before fs_data and state_data import. Database readiness waits for TCP on 127.0.0.1.
# - Restore removes decrypted archives, image tars, and volume dumps as soon as they are consumed, prunes unused images after a healthy start, and can delete the backup files that were just restored.
# - A backup data path that is not writable on this machine is replaced by a path chosen here. Demo seeding is forced off before pg_restore.
#
# Changes in v0.24.5:
# - Cockpit admin panel copy includes helper.update.status.js next to evi-update.js.
#
# Changes in v0.24.4:
# - Final summary does not print the pgAdmin password. The pgAdmin block names EVI_ADMIN_DB_PASSWORD in evi.secrets.env.
# - While .install-config exists, the fresh 2-step menu stays even if config/evi.env and config/evi.secrets.env already exist. The existing-install menu appears only after a successful deploy removes .install-config.
#
# Changes in v0.23.12:
# - Final summary shows a demo-accounts password section (password lock) only when this deploy seeded demo data. The flag is read before deploy_up resets EVI_SEED_DEMO_DATA to false.
# - deploy_full / restore_install_prerequisites: journald caps via
#   journald-limits-ensure.sh (--sudo-mode=interactive). Restore applies
#   journald in both needs_install branches (same precedent as install_sshd_jail).
#
# Changes in v0.23.10:
# - After UFW in deploy_full() and after the restore needs_install skip, call
#   install-fail2ban.sh via install_sshd_jail() (hard-fail). Final summary
#   prints SSH autoban on/off + bantime/maxretry.
# - sshd-kit.local always sets action=%(action_)s (fail2ban 1.1.x); upgrade
#   rewrites older banaction=ufw-only drop-ins with empty actions.
#
# Changes in v0.23.9:
# - Uninstall wrapper is run_uninstall(); it calls scripts/uninstall.sh.
# - Start state-volume.service with the other volume units so the evi-state
#   named volume exists before the Valkey container starts (AOF persistence).
# - deploy_ensure_dirs creates EVI_DATA_PATH/state when a separate data disk is set,
#   matching the EVI_DATA_VOLUME_OPTIONS_STATE bind-mount.
# - Empty APP_LIMIT_MEM_STATE is filled from host RAM (test/compact/medium/large/xlarge)
#   and persisted; valkey.conf is rendered (not copied) on deploy and restore via
#   deploy_apply_and_render_state_memory. Reverse-map uses deploy_state_profile_name_for_limit.
# - check_resources uses deploy_host_mem_gib / deploy_check_host_mem: < 2 GiB returns 1
#   (deploy/restore die); 2–4 GiB warns (test, not production) and prints the profile.
# - deploy_ensure_dirs only creates directories; it no longer copies valkey.conf.
#
# Changes in v0.23.8:
# - After required cockpit apt in deploy_full() and restore_install_prerequisites(), call
#   install-cockpit-files.sh (best-effort; never fails Deploy). Restore uses --rewrite-origin.
#   Configure / guided_setup / menu start do not install cockpit-files.
# - File-browser helper is invoked with --sudo-mode=interactive (not sudo -n).
#
# Changes in v0.23.6:
# - Bootstrap self-heal (scripts/github-auth.sh missing on first boot) now tries the
#   anonymous Contents API download first, falling back to Authorization: Bearer
#   (EVI_GITHUB_TOKEN / .github-token) only if that fails.
# - Dropped the eager require_github_token gate before main_menu and in
#   __continue_deploy — installs no longer die on a missing key before knowing
#   whether the repo actually needs one. load_github_token still runs (no prompt).
# - fetch_github_evi_release_tags / download_release_kit_archive failure messages now
#   hint "the evi repository may be private — set EVI_GITHUB_TOKEN" when the HTTP
#   code is 401/403/404 and no token was available.
# - deploy_pull_images uses the new podman_pull_ghcr helper (anonymous pull first,
#   login-and-retry only on failure) instead of an unconditional login before pulling.
#
# Changes in v0.23.4:
# - GitHub access-key gate: source github-auth.sh after SCRIPTS_DIR, require_github_token
#   before the wizard, load_github_token (no prompt) on __continue_deploy.
# - GitHub HTTP via github_curl (release tags + kit archive / tarball fallback).
# - persist_github_token after config/secrets are created; GHCR login before image pulls
#   (login failure is a warning, not a deploy abort).
# - No host apt before the wizard; removed EVI_BOOTSTRAP_APT_PACKAGES / ensure_bootstrap_packages.
# - Pending-reboot check runs after deploy apt (not before the menu).
# - generate_password falls back to /dev/urandom if openssl is missing.
# - Configure requires curl already on the host (clear error, no apt).
#
# Changes in v0.23.1:
# - File version aligned to the 0.23.1 release (was 1.44.0).
# - Clean-VM bootstrap + README one-liner (curl/podman/cockpit before the wizard).
# - Disk picker: local block devices only (no snap/bind mounts).
# - Noninteractive apt (`DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l`) so needrestart cannot block or restart sshd during bootstrap/deploy.
# - Single bootstrap call after CLI handlers; pending-reboot gate (`/var/run/reboot-required`) before the wizard.
# - Download kit via release asset, fall back to GitHub API tarball/codeload when githubusercontent CDN is blocked; README bootstrap uses Contents API raw Accept.
#
# Changes in v1.44.0:
# - On startup, install host packages needed on a clean VM (curl, uidmap, podman, ufw, …)
#   so the wizard can fetch releases before deploy. Same set as the README one-liner.
# - detect_available_disks: only real local block devices (/dev/…), skip snap/bind mounts
#   (e.g. Firefox /var/snap/.../host-hunspell).
#
# Changes in v1.43.0:
# - confirm() accepts Latin y/Y and Cyrillic у/У (empty still uses default y).
# - Rootless host check moved to scripts/check-rootless-host.sh: TUN required, LXC subuid
#   remapped into 0-65535 when 100000:65536 makes newuidmap fail. No rootful fallback.
# - Legacy apt line in an older prereq path now installs uidmap and ufw as well.
# - Rootless check errors are written for unprepared operators (what is missing, which VM
#   types, where to enable it). Summary no longer says "image pulls failed" when the host check failed.
#
# Changes in v1.42.0:
# - Apply only /etc/sysctl.d/99-evi-rootless.conf (ip_unprivileged_port_start). Do not run
#   sysctl --system: on LXC/Proxmox that reprints Permission denied on kernel/fs keys and
#   can abort a set -e installer. Same change in check-prerequisites.sh and
#   sync-host-prerequisites.sh.
#
# Changes in v1.41.0:
# - Rootless Podman on LXC/Proxmox: detect user-namespace failure (newuidmap) before image pull,
#   print a host-specific hint (CT features nesting + keyctl), and fail the deploy instead of
#   claiming the stack is online with 0 containers. sysctl --system remains non-fatal (LXC).
# - display_final_summary() only prints "evi is online" when deploy up succeeded.
#
# Changes in v1.40.0:
# - prompt_fs_volume_capacity() (step 7 continued): removed the 10000 GB upper bound on file
#   storage capacity. SeaweedFS's own -volume.max flag has no inherent ceiling (it is not
#   pre-allocated; each volume file is only created on demand), and the wizard's disk
#   free-space warning already catches unrealistic values relative to the selected disk — a
#   fixed upper bound added no real protection. Only the 10 GB minimum and integer-format
#   check remain.
# - Same function: made the GB unit explicit in both the field description and the prompt
#   itself ("enter a whole number of gigabytes (GB), minimum 10, no fixed upper limit" /
#   "max file storage capacity in GB, minimum 10"), and in the validation message ("enter a
#   whole number of GB, at least 10 (e.g. 10, 100, 5000)") — the input is a plain integer
#   with no unit suffix, so this was ambiguous before.
#
# Changes in v1.39.0:
# - Installation summary now shows the default admin password as "lock" (matches the
#   db/init/07_system_users.sql default for new installations, down from eviLock).
#
# Changes in v1.38.0:
# - Added prompt_fs_volume_capacity() after FS disk selection (step 7): configurable SeaweedFS
#   capacity ceiling (default 100 GB) with disk free-space context and overrun warning.
# - collect_config()/deploy_full(): persist and apply INSTALL_FS_VOLUME_MAX_GB -> EVI_FS_VOLUME_MAX_GB.
# - load_deploy_env(): export EVI_FS_VOLUME_MAX_GB (default 100) and EVI_FS_VOLUME_MAX for quadlet render.
#
# Changes in v1.37.0:
# - Retro-futurist (80s/90s) visual restyle of signature moments, pure bash + 16-color ANSI, no new deps.
# - New centralized theme layer near color defs: COLOR_OK/UNICODE_OK/STYLE_ENABLED gates, neon palette
#   (NEON_CYAN/MAGENTA/AMBER/GREEN/DIM), double-line box-drawing chars with ASCII fallback, BOX_W=64,
#   restyled SYM_* glyphs, interactive ARROW prompt prefix.
# - New helpers: _repeat, box_top/box_bottom, panel_row/panel_row_center (right border always aligned),
#   hr, banner_evi (embedded EVI block logo + version; monochrome cyan to avoid poor multi-hue combos
#   on themed consoles), section(), phase(), title_box().
# - main_menu() banner replaced with banner_evi; menu group separators + status line recolored to neon;
#   menu selects use ARROW prompt. Non-tty/Cockpit/NO_COLOR/dumb-term degrade to plain ASCII.
# - Guided setup step headers routed through section(); prompt_data_storage_path header too.
# - deploy_full(): top title via title_box(); phase headers via phase(). collect_config/guided_setup
#   titles via title_box(). Deployment summary header and final summary ("evi is online") restyled.
# - render_disk_bar(): neon fill + dim empty, ASCII fallback when not UTF-8.
#
# Changes in v1.36.7:
# - UFW: call scripts/ufw-ensure-active.sh before opening application ports and before
#   apply_firewall_admin_tools so rules are applied on hosts where ufw was installed but inactive.
#
# Changes in v1.36.6:
# - Updated default pgAdmin container image fallback to docker.io/dpage/pgadmin4:9.15
#   in load_deploy_env().
#
# Changes in v1.36.5:
# - Cockpit panel install (all three paths: prerequisites install, deploy_full phase 3, restore prerequisites):
#   now also installs evi-update.js into /usr/local/share/cockpit/evi-admin/.
# - Cockpit panel install now renders and installs evi-update-dispatch.sh from
#   cockpit-evi-admin/evi-update-dispatch.sh.tpl (with DEPLOYMENT_DIR substitution) and sets chmod 755.
#   This restores Updates section actions (Check/Download/Install) on fresh installs and restore flows.
#
# Changes in v1.36.4:
# - quadlet template fs.container: fix corrupted non-comment line that prevented fs.service from loading (see template v1.8.1).
# - deploy_up/do_apply_restart/restore/cockpit repair: capture systemctl is-active without `|| echo failed` so stdout is not duplicated (inactive/failed + failed).
#
# Changes in v1.36.3:
# - collect_config(): split data storage selection into two consecutive steps:
#   step 6 for DB volume path (EVI_DATA_PATH) and step 7 for FS volume path
#   (EVI_FS_DATA_PATH with fallback to EVI_DATA_PATH).
# - collect_config()/deploy_full(): persist and apply INSTALL_FS_DATA_PATH from .install-config.
# - deploy_full() phase 4: writes both EVI_DATA_PATH and EVI_FS_DATA_PATH to evi.env,
#   creates db/fs bind directories according to the selected paths.
# - load_deploy_env()/deploy_ensure_dirs(): export/use EVI_FS_DATA_PATH with fallback to EVI_DATA_PATH.
# - Version steps renumbered: evi version selection moved from step 7 to step 8.
#
# Changes in v1.36.2:
# - Default EVI_FS_BUCKET fallback: fs -> evi-fs (S3 invalid bucket name when length < 3).
#
# Changes in v1.36.1:
#
# Changes in v1.36.0:
#   renamed volume from fs_data to fs_data; renamed secret function to deploy_prepare_fs_credentials;
#   updated containers list, restore block, image pull, and success message.
#
# Changes in v1.35.0:
# - Removed evi- prefix from Podman network unit: evi-network.service -> network.service (two systemctl start calls).
#   Removed evi_ prefix from Valkey secret name default: evi_valkey_password -> valkey_password.
#
# Changes in v1.34.0:
# - Removed evi- prefix from Podman volume names: evi_fs_data -> fs_data
#   (restore block: rm, create, inspect, import, messages).
#   Removed evi- prefix from Podman secret names: evi_jwt_private_key -> jwt_private_key,
#   Removed evi- prefix from systemd unit files: evi-disk-monitor.* -> disk-monitor.*.
#   Removed evi- prefix from registry image name defaults: ghcr.io/vk74/evi-* -> ghcr.io/vk74/*.
#
# Changes in v1.33.0:
# - Renamed all container names to short forms without evi- prefix:
#   evi-db -> db, evi-be -> be, evi-fe -> fe, evi-state -> state,
#   evi-reverse-proxy -> reverse-proxy, evi-pgadmin -> pgadmin.
#   Updated all systemctl, podman exec/cp/logs calls and unit lists accordingly.
#
# Changes in v1.32.0:
# - Data storage disk selection: collect_config() step 6 detects available disks via findmnt,
#   shows visual list with ASCII progress bars, recommends non-system disk with most free space.
#   Single-disk systems get a warning with option to exit and add a data disk.
# - New functions: detect_available_disks(), render_disk_bar().
# - deploy_full() phase 4: applies INSTALL_DATA_PATH to evi.env, creates data/db and data/fs dirs.
# - load_deploy_env(): exports EVI_DATA_PATH with empty default.
# - deploy_up() and do_apply_restart(): install/restart evi-disk-monitor systemd timer.
# - Version steps renumbered: data storage is step 6, evi version is step 7.
#
# Changes in v1.30.0:
# - Removed cockpit-evi-pgadmin install blocks from all three install contexts (first-run, phase 3,
#   and restore_install_prerequisites). pgAdmin is now accessible via the DB Tools section inside
#   the evi-admin Cockpit panel. Legacy evi-pgadmin dir is cleaned up by install-cockpit-panels.sh.
#
# Changes in v1.29.0:
# - restore_from_backup(): replaced manual podman/systemctl check with restore_install_prerequisites() call.
#   Prerequisites (podman, cockpit, panels) are now auto-installed during restore on both new and existing servers.
# - New restore_install_prerequisites(): sources prerequisites.conf from kit, checks if packages already present,
#   installs apt packages + cockpit + panels + update kit if needed; clear error messages on failure.
# - restore_from_backup(): added auto-scan of CONFIG_DIR/backup (default backup dir) as first scan candidate,
#   covers existing installation scenario where backup files live in ~/evi/config/backup/.
#   Parent dir (~/) is still scanned for new server scenario. Menu shows 0-2 auto-found options dynamically.
# - scan_backup_directory(): fixed README grep patterns from pipe-table format to Key: value format
#   (e.g. '^Created: ' instead of '| Created ') to match actual README-RESTORE-STEP-BY-STEP.md output.
# - main_menu(): renamed "install containers and restore app data from backup" to "restore evi from full backup"
#   in both fresh and existing menus.
# - Version-matched installer re-exec: after download_release_kit_archive() replaces install.sh on disk,
#   deploy_full() detects the version mismatch and exec's the version-matched installer so all deployment
#   phases (prerequisites, cockpit, config, containers) run with the correct version's code.
# - deploy_full(): save _running_installer_ver before locals shadow global INSTALL_VERSION.
#   After successful download, compare on-disk install.sh version with _running_installer_ver.
#   If different and on-disk has __continue_deploy: exec install.sh __continue_deploy (seamless continuation).
#   If different and on-disk lacks __continue_deploy (old version): clean env files, exec install.sh to old menu.
# - New CLI entry point __continue_deploy: sets _EVI_CONTINUE_DEPLOY=1, calls deploy_full(); on re-exec the
#   kit version already matches so download is skipped and phases 2-5 run with the correct version's code.
# - deploy_full(): skip "proceed with deployment?" confirmation when _EVI_CONTINUE_DEPLOY=1 (user already confirmed).
# - do_apply_restart(): safety guard that re-execs to main menu if on-disk install.sh version differs from running.
#
# Changes in v1.27.6:
# - Step 4 manual password entry: added confirmation re-prompt for each password;
#   mismatch resets the loop so the user must re-enter both values.
#
# Changes in v1.27.5:
# - __cockpit_apply_restart: replaced do_apply_restart delegation with direct run_deploy_init + systemctl
#   restart call so do_apply_restart remains unchanged (no EVI_NONINTERACTIVE plumbing needed).
# - do_apply_restart: reverted EVI_NONINTERACTIVE changes; restored original interactive-only read prompts.
#
# Changes in v1.27.4:
# - __cockpit_apply_restart CLI: run do_apply_restart with EVI_NONINTERACTIVE=1 (no press-enter prompts; exit 1 on failure).
# - do_apply_restart: honor EVI_NONINTERACTIVE for read/return vs exit behavior.
#
# Changes in v1.27.3:
# - Main menu (existing install): blank line after banner; warning line in yellow/bold; line
#   "current status: evi configured to work at …" from EVI_DOMAIN via get_evi_main_url_for_menu().
# - deploy_full(): require prerequisites.conf (fail with err/return 1 if missing or invalid EVI_PREREQ_*);
#   removed silent defaults when manifest is absent.
#
# Changes in v1.27.2:
# - Main menu (fresh install): option labels "environment configuration" and "deploy evi".
# - Removed main menu status block (display_status) and helpers only used there
#   (check_prerequisites_status, check_deployment_status).
#
# Changes in v1.27.1:
# - Lazy-source scripts/render-templates.sh via ensure_render_templates_sourced() so bootstrap installs
#   that only download install.sh from raw GitHub reach the main menu; a top-level source failed when
#   scripts/ was absent before deploy downloaded the full kit archive.
# - Removed temporary NDJSON debug logging used while diagnosing the bootstrap source failure.
#
# Changes in v1.27.0:
# - 2-step installation: fresh install now uses collect_config() → deploy_full() instead of
#   3 separate menu options (prerequisites → configure → deploy). This ensures the cockpit panels
#   are always installed from the correct kit version matching the user's chosen release.
# - collect_config(): new function that collects all user configuration (domain, TLS, firewall,
#   passwords, demo data, evi version) and saves to .install-config file without touching system.
# - deploy_full(): new function that reads .install-config, downloads kit archive for the chosen
#   version, sources prerequisites.conf, installs system prerequisites, installs cockpit panels,
#   applies saved configuration, and runs deploy_up().
# - prerequisites.conf: deploy-kit now includes a bash-sourceable prerequisites manifest. install.sh
#   sources it during deploy to determine apt packages, sysctl, and UFW rules dynamically.
# - download_release_kit_archive(): now also copies install.sh and prerequisites.conf from the
#   kit archive to SCRIPT_DIR so future runs use the version-matched installer.
# - main_menu(): fresh install shows 2 primary options (configure, deploy) plus restore/uninstall.
#   Existing install menu is unchanged.
#
# Changes in v1.26.1:
# - execute_restore(): restore SeaweedFS data when evi-data/fs/evi_fs_data.tar exists
#   (podman volume rm -f, volume create if missing, podman volume import into evi_fs_data).
#
# Changes in v1.26.0:
# - Archive-based version selection: step 6 options 1 (latest) and 2 (choose release version) now download the full
#   kit archive (evi-<version>.tar.gz) from GitHub Release file instead of only evi.template.env. When the selected
#   version differs from the current kit version, download_release_kit_archive() replaces deploy-kit files, update-kit,
#   package.json, and re-creates config env files from the new templates. Ensures version-consistent deploy-kit + images.
# - New functions: get_current_kit_version(), download_release_kit_archive().
# - Removed download_evi_release_template_env() (replaced by full archive download).
# - Step 6 option 2 label renamed from "choose release version (all containers from that release)" to "choose release version".
# - deploy_up(): after successful deployment, always set EVI_SEED_DEMO_DATA=false in evi.env to prevent
#   re-seeding demo data on future restarts or updates (one-time action).
#
# Changes in v1.25.0:
# - Update kit source: only sibling update-kit/ at repository root (${SCRIPT_DIR}/update-kit or ../update-kit); removed dev-ops/update-kit paths (breaking).
# - download_evi_release_template_env: raw URL uses deploy-kit/env/evi.template.env at repository root.
#
# Changes in v1.24.1:
# - Guided setup step 6: option "latest" fetches the same GitHub Releases list as manual selection, picks the first tag matching x.y.z (skips prereleases like 0.15.2-b1), downloads that release's evi.template.env, and applies EVI_*_IMAGE like manual mode. Shared fetch uses per_page=100; canceling the summary confirmation removes any pending release template temp file.
# - Fixed fetch_github_evi_release_tags: renamed internal local variable tags_raw → _tags_result so printf -v correctly writes to the caller's variable (previously bash resolved printf -v "tags_raw" to the function's own local, leaving the caller's tags_raw empty; this broke both latest and manual release list).
#
# Changes in v1.24.0:
# - Extracted render functions (deploy_compute_limits_block, deploy_prepare_proxy_tls_mounts,
#   deploy_render_template_file, deploy_render_caddyfile, deploy_render_quadlets) into
#   scripts/render-templates.sh. Sourced here for reuse by apply-update.sh.
# - Added DEPLOY_KIT_DIR variable (= SCRIPT_DIR) required by render-templates.sh contract.
#
# Changes in v1.23.1:
# - Fixed load_deploy_env(): added export EVI_FS_IMAGE with default so it is available to deploy_render_template_file().
#
# Changes in v1.23.0:
#   EVI_FS_ACCESS_KEY+EVI_FS_SECRET_KEY in apply_auto_secrets() and uninstall-evi.sh secrets list.
#
# Changes in v1.22.1:
# - Step 6 option 2: "choose release version" — list from GitHub Releases API, user enters release number (1 = latest). Fetch evi.template.env from selected release and apply all EVI_*_IMAGE to evi.env so proxy/state/pgadmin match that release. Configuration summary shows only release version (no container names).
#
# Changes in v1.22.0:
# - Deploy update kit: install_prerequisites_all() copies update-kit/ (repo root, sibling of deploy-kit) to ~/evi/update/ on fresh install
#   so Cockpit update panel dispatch can find check-updates.sh, download-update.sh at ~/evi/update/scripts/.
#   Skips if ~/evi/update/scripts/ already exists (re-run safe).
#
# Changes in v1.21.3:
# - Restore fix: call deploy_prepare_valkey_secret after JWT registration so Valkey podman secret exists before evi-state starts (evi-state and evi-be/evi-worker no longer fail on restore).
#
# Changes in v1.21.2:
# - evi-state fix: deploy_ensure_dirs now requires valkey.conf (die if missing). deploy/state/valkey.conf added so sparse-checkout deploy includes it; after flatten, SCRIPT_DIR/state/valkey.conf exists and is copied to config/state/valkey/.
#
# Changes in v1.21.1:
# - Cleanup of obsolete change notes.
#
# Changes in v1.21.0:
# - Fixed valkey.conf path in deploy_ensure_dirs: use SCRIPT_DIR/state/valkey.conf so config is copied after deploy flatten.
# - Added evi-worker: render evi-worker.container, EVI_PODMANARGS_LIMITS_WORKER, pull EVI_STATE_IMAGE and EVI_WORKER_IMAGE, start evi-worker in deploy_up and do_apply_restart and restore; get_project_containers and units lists include evi-state and evi-worker.
# - Pauses for evi-state: sleep 2 before and sleep 3 after starting evi-state in deploy_up and restore so Valkey is ready before evi-be starts.
#
# Changes in v1.20.2:
# - EVI_VALKEY_PASSWORD: auto-generate when blank in deploy_prepare_valkey_secret and persist to evi.secrets.env; added to apply_auto_secrets keys so "auto-generate missing secrets" includes Valkey password.
#
# Changes in v1.20.1:
# - evi-state.volume quadlet removed: evi-state is diskless (tmpfs), volume never existed in production
#
# Changes in v1.20.0:
# - evi-state is diskless (tmpfs): no longer start evi-state-volume.service before evi-state
#
# Changes in v1.31.0:
# - Removed three cockpit-evi-update install blocks: update panel is now embedded inside
#   cockpit-evi-admin (Updates nav section). Standalone cockpit-evi-update no longer ships.
#
# Changes in v1.18.5:
# - Prerequisites installation: deploy cockpit-evi-update panel (check, download, install updates via Cockpit sidebar).
#
# Changes in v1.18.4:
# - Guided reconfiguration: skip Step 6 (version selection) and default to "keep current version" to prevent accidental upgrades during reconfiguration.
#
# Changes in v1.18.3:
# - UFW workflow: single path for first run and reconfigure. apply_firewall_admin_tools() always runs ufw-delete-rules.sh (remove existing 9090/5445, print each removal) then ufw-add-rules.sh (add from evi.env). Renamed ufw-configure.sh → ufw-add-rules.sh, ufw-reconfigure.sh → ufw-delete-rules.sh.
#
# Changes in v1.18.2:
# - UFW for cockpit/pgadmin (9090, 5445) moved to deploy/scripts/ufw-configure.sh (first-time) and ufw-reconfigure.sh (reconfigure/restore). apply_firewall_admin_tools() now calls these scripts: "configure" when CONFIG_EXISTS=0 (guided first run), "reconfigure" when CONFIG_EXISTS=1 (guided reconfigure) or restore. Reconfigure deletes existing rules by number (skip empty/non-numeric to avoid "Usage" errors) then adds from evi.env.
#
# Changes in v1.18.1:
# - apply_firewall_admin_tools: use "grep -E '(9090|5445)/' || true" in pipeline so that when no rules exist (first config) the pipeline does not fail under set -o pipefail; script no longer exits at firewall step.
#
# Changes in v1.18.0:
# - apply_firewall_admin_tools: remove all existing rules for 9090/5445 by rule number (ufw status numbered, delete in reverse order) before adding new rules so reconfiguration does not leave duplicate rules.
# - apply_firewall_admin_tools: add separate UFW rules per port (9090 and 5445) for allowed_ips and allowed_cidr so each port gets its own IPv4/IPv6 rules, consistent with localhost and any.
#
# Changes in v1.17.0:
# - Re-run UX: main menu section header "new deployment" → "manage deployment" when CONFIG_EXISTS.
# - Option 1 re-run: "check & repair prerequisites" — dispatches to deploy/scripts/check-prerequisites.sh (diagnose → report → repair → verify) instead of blind reinstall.
# - Option 2 re-run label: "reconfigure containers environment"; post-reconfigure reminder to run option 3.
# - Option 3 re-run label: "apply configuration and restart containers" (was "redeploy and restart"); function renamed do_redeploy → do_apply_restart.
#
# Changes in v1.16.0:
# - Deploy kit / runtime config split: introduced CONFIG_DIR (~/evi/config) for all runtime data.
# - evi.env, evi.secrets.env now created and read from config/ instead of env/.
# - TLS certificates stored in config/tls/ (previously env/tls and state/tls).
# - EVI_STATE_DIR default changed from ~/.local/share/evi to config/state/ (JWT, pgadmin, Caddyfile).
# - deploy_ensure_dirs creates config/ and subdirs: tls, state, state/reverse-proxy, state/secrets, state/pgadmin/data, backup, updates.
# - deploy_prepare_proxy_tls_mounts uses TLS_DIR (config/tls) instead of EVI_STATE_DIR/tls.
# - deploy_prepare_manual_tls_files imports certs to config/tls.
# - ensure_config_files creates env files in config/ from templates in env/.
# - Restore functions write to config/ paths.
# - Templates (env/*.template.*) remain in deploy kit root; only deploy kit is overwritten on update.
# - Guided configuration: guided_setup() supports reconfigure mode (guided_setup reconfigure). In reconfigure, each step has "0) keep current setting" (step 2: "keep current certificate"); step 5 (demo data) skipped — demo data can be deployed only during initial setup.
# - No podman build; daily operations (status, logs, restart, backup, etc.) via Cockpit (evi admin panel at :9090).
#
# Changes in v1.15.5:
# - Uninstall (option 5): when uninstall-evi.sh exits with code 2 (success), install.sh exits so control returns to shell; uninstall-evi.sh shows two commands (cd ~ and rm -rf ~/evi) for final cleanup.
#
# Changes in v1.15.4:
# - Installation summary: standardized three blocks (evi web-application, cockpit (admin tool), pgadmin (database management)); headers without checkmarks; address/account/password in green; notes line per block; evi default admin credentials (admin / eviLock) and pgAdmin password from EVI_ADMIN_DB_PASSWORD shown explicitly.
# - Prerequisites installation summary: only installed tools list and IMPORTANT note; cockpit and pgadmin text blocks removed.
#
# Changes in v1.15.3:
# - Step 6 (manual container versions): list order reversed — 1 = newest, last number = oldest; list limited to 30 versions.
# - Step 6: prompt "(enter version number or press enter to use X.Y.Z version)"; empty input selects latest (first in list).
# - Configuration summary: when step 6 choice is "latest", show actual image:tag from env instead of "latest (from template)".
#
# Changes in v1.15.2:
# - Colors: use ANSI-C quoting ($'...') so status symbols and colors render in terminal; added BOLD for IMPORTANT lines.
#
# Changes in v1.15.1:
# - Deployment summary: removed redundant "=== deployment complete! ===" line; removed build step from summary (script only pulls images, no build).
# - Option 3: confirm before deploy/redeploy ("Start deployment now? [y/N]") to avoid accidental start.
# - Guided setup message: "deploy and start" instead of "build and start".
# - Uninstall (option 5): single confirmation only (double confirmation removed in uninstall-evi.sh).
#
# Changes in v1.15.0:
# - Step 6 (EVI version): "which evi version do you want to deploy?" — 1) latest (use template), 2) manually set container versions (list tags from registry via evi-registry-tags.sh, then choose per evi-fe/evi-be/evi-db). Reconfigure: 0) keep current.
# - Apply: EVI_FE_IMAGE, EVI_BE_IMAGE, EVI_DB_IMAGE written to evi.env only when user chose manual; otherwise unchanged (latest/keep).
#
# Changes in v1.14.5:
# - Re-run improvements: menu option "guided configuration (recommended for first-time setup)" renamed to "guided configuration".
# - Step 2 (TLS): option 0 renamed to "keep current certificate"; when user selects 0, wizard no longer asks to place certificates — current cert in TLS_DIR is used as-is.
# - Step 5 (demo data): skipped in reconfigure mode; note "demo data can be deployed only during initial setup"; EVI_SEED_DEMO_DATA not updated on reconfigure.
#
# Changes in v1.14.4:
# - Unified first-run and re-run: single main_menu() for both; CONFIG_EXISTS flag; banner when config exists; option 3 = deploy vs redeploy. Removed evi-reconfigure.sh entry point.
# - guided_setup(reconfigure): same steps with "0) keep current" and indices 1,2,3 aligned to first-run; menu_env_config calls guided_setup reconfigure when CONFIG_EXISTS.
# - Uninstall logic moved to deploy/scripts/uninstall-evi.sh; uninstall_evi() only calls that script. uninstall-evi.sh: state dir removed with sudo (pgadmin data); UFW rules by rule number (80/443/9090/5445); cockpit panels without suppressing errors; /usr/local and /usr/share cockpit paths.
#
# Changes in v1.14.3:
# - Deployment summary: new display_final_summary() with two blocks (evi application, admin tools cockpit/pgadmin), styled like prerequisites summary; self-signed cert note when EVI_TLS_MODE=manual
# - Main menu and reconfigure menu: new group "uninstall" with option 5 "uninstall evi (remove everything)"
# - New uninstall_evi(): double confirmation, removes containers/volumes/secrets/images, state and config dirs, quadlets, cockpit panels, UFW rules, sysctl, apt packages (podman, cockpit, curl, openssl); prints instruction to run rm -rf ~/evi
#
# Changes in v1.14.2:
# - After completing guided configuration (step 2, sub-step 1), return to main menu instead of env config menu so user can immediately choose deployment (option 3)
#
# Changes in v1.14.1:
# - Restore: apply firewall rules (ports 80/443 and admin 9090/5445 from evi.env) after restoring env
# - deploy_ensure_dirs(): chown -R 5050:5050 for pgadmin/data so restored pgadmin4.db has correct ownership
#
# Changes in v1.14.0:
# - Removed evictl from deploy: no chmod, no references. Daily ops and upgrade via Cockpit; redeploy/restore via install.sh and deploy scripts.
#
# Changes in v1.13.0:
# - Main menu: grouped options (deployment / restore), added option 4 "install app data and containers from backup"
# - New function scan_backup_directory(): pre-validates backup directory, parses README for metadata (version, date, platform, encryption)
# - New function restore_from_backup(): interactive restore flow with 2 backup location options (parent dir / custom path),
#   pre-scan display, password prompt for encrypted backups, full restore (decrypt, extract, load images, restore env/TLS/JWT/pgAdmin,
#   deploy init, start DB, pg_restore, start services, summary)
# - Restore uses deploy_* functions directly (no evictl dependency), skips JWT key generation to preserve restored key
#
# Changes in v1.12.2:
# - Cockpit evi-admin: backup form UI — estimate JSON parsing with ANSI strip, ~/evi/config/backup in UI, password visibility toggle, progress bar during backup
#
# Changes in v1.12.1:
# - Cockpit: install cockpit-evi-admin package ("evi admin tools" panel with backup form, nav sidebar)
# - Cockpit: generate evi-admin-dispatch.sh from template with actual deployment directory path
# - Cockpit: renamed pgAdmin sidebar label from "pgAdmin (evi)" to "evi pgAdmin"
#
# Changes in v1.12.0:
# - Guided configuration: step 1–5 labels shown with green "step N:" only (question text default color)
# - Deployment summary: replaced evictl info with numbered list — (1) main app address https://EVI_DOMAIN, (2) cockpit admin from <allowed> at :9090; get_cockpit_allowed_summary() from EVI_FIREWALL_ADMIN_*
#
# Changes in v1.11.0:
# - pgAdmin: removed interactive email prompt from prerequisites; use hardcoded login evidba@pgadmin.app (override via EVI_PGADMIN_EMAIL in evi.env)
# - load_deploy_env() defaults EVI_PGADMIN_EMAIL to evidba@pgadmin.app when unset
# - run_deploy_init() pgAdmin validation simplified to non-empty check only
# - Prerequisites summary: pgAdmin block shows explicit account and password (evidba@pgadmin.app, EVI_ADMIN_DB_PASSWORD)
# - Cockpit: install cockpit-evi-pgadmin package to add "pgAdmin (evi)" link in sidebar (redirects to host:5445; no credentials on page)
#
# Changes in v1.10.0:
# - Guided setup (first run): removed "keep current setting" from all steps; reordered steps to 1-access, 2-TLS, 3-firewall, 4-passwords, 5-demo. Options renumbered (e.g. step 1: 1-3, step 4: 1-2).
# - Reconfigure flow moved to evi-reconfigure.sh: guided_reconfigure() with same step order and "keep current" as option 1; empty-password guard when keeping passwords.
#
# Changes in v1.9.3:
# - Subsequent run: delegate to evi-reconfigure.sh; removed menu_subsequent and reconfigure_edit_existing. New menu: exit, guided config, edit evi.env, edit evi.secrets.env, redeploy. Redeploy uses do_apply_restart (init + restart only; no image pull — uses existing images; evi-db volume preserved). Upgrading to new image versions is separate (e.g. evictl update). Guided setup: "keep current setting" as first option in every step.
#
# Changes in v1.9.2:
# - Prerequisites: UFW only opens application ports 80, 443. Admin ports 9090/5445 are configured only in Step 2 (environment configuration).
#
# Changes in v1.9.1:
# - apply_firewall_admin_tools: delete "from 127.0.0.1" rules for 9090/5445 before applying allowed_ips/allowed_cidr/any so chosen policy takes effect; add proto tcp to rules.
#
# Changes in v1.9.0:
# - Guided setup: new Step 2 "from which computers may admins connect to cockpit?" (allowed_ips, allowed_cidr, localhost, any, skip).
# - EVI_FIREWALL_ADMIN_ACCESS and EVI_FIREWALL_ADMIN_ALLOWED in evi.env; apply_firewall_admin_tools() applies UFW rules after save.
# - Steps renumbered: TLS=3, passwords=4, demo data=5.
#
# Changes in v1.8.5:
# - Removed prerequisites submenu; option 1 in main menu directly starts installation
# - Combined mandatory and optional prerequisites into single step
# - Option 1 renamed to "install prerequisites (requires sudo)"
# - pgAdmin email asked at start (after confirm, before apt-get)
# - Rephrased pgAdmin email prompt
# - Summary renamed to "prerequisites installation summary"; added podman/curl/openssl, green checkmarks, highlighted key data
#
# Changes in v1.8.4:
# - Menu banners show script version (parsed from header)
#
# Changes in v1.8.3:
# - pgAdmin: removed localhost-only restriction; default EVI_PGADMIN_HOST=0.0.0.0 for browser access from any computer (port 5445)
#
# Changes in v1.8.2:
# - Relaxed check_os(): accept Ubuntu, Debian, Linux Mint, Pop!_OS and other Debian-based distros (ID allowlist + ID_LIKE)
#
# Changes in v1.8.1:
# - Restored Step 4 (demo data question) in guided setup
#
# Changes in v1.8.0:
# - Menu numbering: exit/back options moved to position 0 in all menus for consistency
# - Guided setup: changed confirmation prompt to "save and apply this configuration?"
#
# Changes in v1.7.2:
# - Improved get_container_status to use 'podman inspect' for more reliable status detection.
# - Added 5s delay after starting services to ensure containers are registered before checking status.
#
# Changes in v1.7.0:
# - Deploy fully in install.sh: no evictl during install. Init and up (JWT, TLS, Quadlet/Caddyfile, pull, systemctl start) in install.sh with detailed logging.
# - Detailed pull log (image name, ID, size) and pull error stderr; per-unit start status (X/Y services active).
# - Overall result in deployment summary uses actual container status (SUCCESS only when all containers running).
# - Pull uses --platform from host arch (linux/amd64, linux/arm64, etc.) to avoid pulling wrong arch and Exec format error.
#
# Changes in v1.6.0:
# - Deploy from images only: removed "build" step; deploy = init + up.
# - Removed Manage menu; recommend ./evictl for daily operations in summary.
# - Config exists: show reduced menu (deploy again, reconfigure=edit existing files, evictl, exit); reconfigure only opens editor, no overwrite from template.
#
# Changes in v1.5.4:
# - Unified numbering: replaced letters with numbers in option 2 (environment configuration) for consistency with option 1
# - All guided setup questions now use numeric options (1/2/3) instead of letters for better consistency
#
# Changes in v1.5.3:
# - Added deployment summary after deploy option (option 3)
# - Summary displays: overall result, step statistics, critical errors, container status
# - Color-coded output (green for success, red for errors, yellow for warnings)
# - Tracks execution time for each step (build/init/up)
# - Shows container health status and uptime
#
# Changes in v1.5.2:
# - Updated pgAdmin instructions with correct login credentials
# - pgAdmin email is requested during GUI tools installation (validated, no .local domains)
#
# Changes in v1.5.1:
# - Added pgAdmin configuration to install_gui_tools()
# - pgAdmin runs as container alongside other evi services
# - pgAdmin accessible only from localhost (127.0.0.1:5445)
# - Pre-configured connection to evi-db with admin user
#
# Changes in v1.5.0:
# - Cleanup prompt moved to evictl (appears after successful deployment)
# - Cleanup removes source code files (back/, front/, db/, docs/, README.md, etc.)
# - Cleanup can be run immediately after deployment or later via evictl cleanup
#
# Changes in v1.4.0:
# - Improved guided setup: clearer option names (a/b/c) 
# - Added option for public domain to use own certificates (not just Let's Encrypt)
# - Added comprehensive certificate validation (format, key match, expiry, domain match)
# - Certificate validation shows errors in red with detailed reasons
#
# Changes in v1.3.0:
# - Complete menu restructure: prerequisites, env config (guided/manual), deploy, manage
# - Added deployment readiness status display in main menu
# - Added guided setup questionnaire (access type, TLS, passwords)
# - Removed internal TLS mode (only manual and letsencrypt)
# - All text in lowercase for consistent styling
#
# Changes in v1.2.0:
# - Added TLS Certificate Management menu
# - Auto-generate self-signed certificates for internal deployments
#

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploy kit paths (overwritten on update)
ENV_DIR="${SCRIPT_DIR}/env"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
TEMPLATE_ENV="${ENV_DIR}/app.template.env"
TEMPLATE_SECRETS="${ENV_DIR}/app.secrets.template.env"
TPL_DIR="${SCRIPT_DIR}/quadlet-templates"
PROXY_DIR="${SCRIPT_DIR}/reverse-proxy"
DEPLOY_KIT_DIR="${SCRIPT_DIR}"

# Deployment root for github-auth.sh (on the server this is ~/app after kit flatten).
# Fresh bootstrap has only install.sh — fetch scripts/lib/github-auth.sh before sourcing.
# Tries the Contents API, then raw.githubusercontent.com, anonymously first; falls back
# to a Bearer token (APP_GITHUB_TOKEN or .github-token) only if both anonymous attempts
# fail. Mirrors the open-first, PAT-fallback contract implemented in github-auth.sh's
# github_curl — this cannot call that function yet because the library isn't sourced.
export APP_HOME="${SCRIPT_DIR}"
APP_INSTALL_REPO="${APP_INSTALL_REPO:-vk74/ready-room}"
export APP_INSTALL_REPO
_app_boot_file="${SCRIPTS_DIR}/lib/github-auth.sh"
if [[ ! -f "${_app_boot_file}" ]]; then
  mkdir -p "${SCRIPTS_DIR}/lib"
  _app_boot_ok=0
  _app_boot_try() {
    local _url
    for _url in \
        "https://api.github.com/repos/${APP_INSTALL_REPO}/contents/deploy-kit/scripts/lib/github-auth.sh?ref=main" \
        "https://raw.githubusercontent.com/${APP_INSTALL_REPO}/main/deploy-kit/scripts/lib/github-auth.sh"; do
      if curl "$@" -sS --fail --connect-timeout 15 --max-time 60 \
          -H "Accept: application/vnd.github.raw" \
          -o "${_app_boot_file}" \
          "${_url}" 2>/dev/null; then
        return 0
      fi
    done
    return 1
  }
  if _app_boot_try; then
    _app_boot_ok=1
  fi
  if [[ "${_app_boot_ok}" -eq 0 ]]; then
    _app_boot_token="${APP_GITHUB_TOKEN:-}"
    if [[ -z "${_app_boot_token}" && -s "${APP_HOME}/.github-token" ]]; then
      _app_boot_token="$(head -n 1 "${APP_HOME}/.github-token" || true)"
      _app_boot_token="${_app_boot_token%$'\r'}"
    fi
    if [[ -n "${_app_boot_token}" ]]; then
      _app_boot_cfg="$(mktemp "${TMPDIR:-/tmp}/app-gh-curl-XXXXXX")"
      chmod 600 "${_app_boot_cfg}"
      printf 'header = "Authorization: Bearer %s"\n' "${_app_boot_token}" > "${_app_boot_cfg}"
      _app_boot_token=""
      if _app_boot_try -K "${_app_boot_cfg}"; then
        _app_boot_ok=1
      fi
      rm -f "${_app_boot_cfg}"
    fi
  fi
  if [[ "${_app_boot_ok}" -ne 1 ]] || [[ ! -s "${_app_boot_file}" ]] || ! grep -q 'load_github_token' "${_app_boot_file}"; then
    rm -f "${_app_boot_file}"
    printf 'error: could not download scripts/lib/github-auth.sh from GitHub.\nIf the repository is private, set APP_GITHUB_TOKEN and try again.\n' >&2
    exit 1
  fi
fi
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/lib/github-auth.sh"

# Runtime config paths (preserved across updates)
CONFIG_DIR="${SCRIPT_DIR}/config"
TLS_DIR="${CONFIG_DIR}/tls"
TARGET_ENV="${CONFIG_DIR}/app.env"
TARGET_SECRETS="${CONFIG_DIR}/app.secrets.env"

CONFIG_EXISTS=0
[[ -f "${TARGET_ENV}" ]] && [[ -f "${TARGET_SECRETS}" ]] && CONFIG_EXISTS=1

# 2-step install: config file persists user choices between configure and deploy steps
INSTALL_CONFIG="${SCRIPT_DIR}/.install-config"
INSTALL_CONFIG_EXISTS=0
[[ -f "${INSTALL_CONFIG}" ]] && INSTALL_CONFIG_EXISTS=1

APP_STATE_DIR_DEFAULT="${CONFIG_DIR}/state"
APP_QUADLET_DIR_DEFAULT="${HOME}/.config/containers/systemd"

INSTALL_VERSION=$(sed -n '1,20p' "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]:-$0}")" 2>/dev/null | grep -m1 '^# Version: ' | sed 's/^# Version:[[:space:]]*//' || echo "?")

# Password minimum length
MIN_PASSWORD_LENGTH=12

# pgAdmin web-console login username (hardcoded; override via APP_PGADMIN_EMAIL in app.env)
APP_PGADMIN_EMAIL_DEFAULT="evidba@pgadmin.app"

# --- Retro-futurist theme layer ---------------------------------------------
# Decoration is centralized so it stays consistent and can degrade safely.
# COLOR_OK   : emit ANSI only on an interactive terminal that wants color.
# UNICODE_OK : use box-drawing / block glyphs only under a UTF-8 locale.
# STYLE_ENABLED: master gate for the decorative (neon) layer.
# When disabled (pipes, Cockpit dispatch, NO_COLOR, dumb term) every themed
# helper falls back to the plain ASCII output the rest of the kit expects.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  COLOR_OK=1
else
  COLOR_OK=0
fi
case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) UNICODE_OK=1 ;;
  *) UNICODE_OK=0 ;;
esac
STYLE_ENABLED="${COLOR_OK}"

# Colors (ANSI-C quoting so escapes render in terminal)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
NC=$'\033[0m' # No Color
BOLD=$'\033[1m'

# Neon palette (bright 16-color SGR) — only populated when styling is on.
if [[ "${STYLE_ENABLED}" -eq 1 ]]; then
  NEON_CYAN=$'\033[1;36m'
  NEON_MAGENTA=$'\033[1;35m'
  NEON_AMBER=$'\033[1;33m'
  NEON_GREEN=$'\033[1;32m'
  DIM=$'\033[2m'
else
  # No color context (pipe, Cockpit dispatch, NO_COLOR, dumb term): blank the
  # entire palette — base + neon — so non-terminal output stays clean (SKILL 13).
  RED=''; GREEN=''; YELLOW=''; CYAN=''; GRAY=''; NC=''; BOLD=''
  NEON_CYAN=''
  NEON_MAGENTA=''
  NEON_AMBER=''
  NEON_GREEN=''
  DIM=''
fi

# Box-drawing characters (double-line), ASCII fallback when not UTF-8.
if [[ "${UNICODE_OK}" -eq 1 ]]; then
  BOX_TL='╔'; BOX_TR='╗'; BOX_BL='╚'; BOX_BR='╝'; BOX_H='═'; BOX_V='║'
  RULE_CH='─'; ARROW_CH='▶'; SECT_CH='▒'; DOT_CH='·'
else
  BOX_TL='+'; BOX_TR='+'; BOX_BL='+'; BOX_BR='+'; BOX_H='='; BOX_V='|'
  RULE_CH='-'; ARROW_CH='>'; SECT_CH='#'; DOT_CH='-'
fi
# Total visible width of framed panels (including both border columns).
BOX_W=64

# Status symbols
if [[ "${UNICODE_OK}" -eq 1 ]]; then
  SYM_OK="${NEON_GREEN}[✓]${NC}"
  SYM_FAIL="${RED}[✗]${NC}"
  SYM_WARN="${NEON_AMBER}[!]${NC}"
  SYM_PENDING="${GRAY}[○]${NC}"
else
  SYM_OK="${NEON_GREEN}[+]${NC}"
  SYM_FAIL="${RED}[x]${NC}"
  SYM_WARN="${NEON_AMBER}[!]${NC}"
  SYM_PENDING="${GRAY}[~]${NC}"
fi

# Interactive prompt prefix (used by the menu selects).
if [[ "${STYLE_ENABLED}" -eq 1 ]]; then
  ARROW="${NEON_CYAN}${ARROW_CH}${NC} "
else
  ARROW=""
fi

# --- Helpers ---

log() { printf "${NEON_CYAN}[install]${NC} %s\n" "$*"; }
info() { printf "${NEON_GREEN}info:${NC} %s\n" "$*"; }
warn() { printf "${NEON_AMBER}warn:${NC} %s\n" "$*"; }
err() { printf "${RED}error:${NC} %s\n" "$*"; }
die() { err "$*"; exit 1; }

# Repeat a character N times (pure bash, no seq/printf-brace tricks).
_repeat() {
  local n="$1" ch="$2" out=''
  while (( n-- > 0 )); do out+="${ch}"; done
  printf '%s' "${out}"
}

# Framed-panel primitives. All rows are exactly BOX_W columns wide so the
# right border always lines up regardless of content length.
box_top() {
  printf '%s%s%s%s%s\n' "${NEON_CYAN}" "${BOX_TL}" "$(_repeat $((BOX_W - 2)) "${BOX_H}")" "${BOX_TR}" "${NC}"
}
box_bottom() {
  printf '%s%s%s%s%s\n' "${NEON_CYAN}" "${BOX_BL}" "$(_repeat $((BOX_W - 2)) "${BOX_H}")" "${BOX_BR}" "${NC}"
}
# panel_row "<visible text incl. leading indent>" "<text color>"
panel_row() {
  local text="$1" color="${2:-}"
  local inner=$((BOX_W - 2))
  local len=${#text}
  local pad=$((inner - len))
  (( pad < 0 )) && pad=0
  printf '%s%s%s%s%s%s%*s%s%s%s\n' \
    "${NEON_CYAN}" "${BOX_V}" "${NC}" \
    "${color}" "${text}" "${NC}" \
    "${pad}" "" \
    "${NEON_CYAN}" "${BOX_V}" "${NC}"
}
# panel_row_center "<visible text>" "<text color>"
panel_row_center() {
  local text="$1" color="${2:-}"
  local inner=$((BOX_W - 2))
  local len=${#text}
  local total=$((inner - len))
  (( total < 0 )) && total=0
  local left=$((total / 2))
  local right=$((total - left))
  printf '%s%s%s%*s%s%s%s%*s%s%s%s\n' \
    "${NEON_CYAN}" "${BOX_V}" "${NC}" \
    "${left}" "" \
    "${color}" "${text}" "${NC}" \
    "${right}" "" \
    "${NEON_CYAN}" "${BOX_V}" "${NC}"
}

# Full-width neon scanline rule.
hr() {
  if [[ "${STYLE_ENABLED}" -eq 1 ]]; then
    printf '%s%s%s\n' "${DIM}${NEON_CYAN}" "$(_repeat "${BOX_W}" "${RULE_CH}")" "${NC}"
  else
    printf '%s\n' "$(_repeat "${BOX_W}" '-')"
  fi
}

# Main installer banner: embedded APP block logo + tagline + version.
banner_app() {
  local ver="${INSTALL_VERSION}"
  if [[ "${STYLE_ENABLED}" -ne 1 ]]; then
    echo "+--------------------------------------------------------------+"
    printf "| %-60s |\n" "application installation manager  ·  version ${ver}"
    echo "+--------------------------------------------------------------+"
    return
  fi
  local blk='#'
  [[ "${UNICODE_OK}" -eq 1 ]] && blk='█'
  local logo=(
    "   ###   #####  #####"
    "  #   #  #    # #    #"
    "  #####  #####  #####"
    "  #   #  #      #"
    "  #   #  #      #"
  )
  # Monochrome on purpose: multi-hue combos can look poor on themed consoles.
  box_top
  panel_row "" ""
  local row
  for row in "${logo[@]}"; do
    panel_row "${row//#/${blk}}" "${NEON_CYAN}${BOLD}"
  done
  panel_row "" ""
  panel_row "  app // deployment console" "${NEON_CYAN}${BOLD}"
  panel_row "  installer v${ver}" "${NEON_CYAN}"
  panel_row "" ""
  box_bottom
}

# Styled section header for guided-setup steps.
# section "step 1" "how will users connect?"
section() {
  local tag="$1" title="$2"
  if [[ "${STYLE_ENABLED}" -eq 1 ]]; then
    printf '\n%s%s%s %s%s%s  %s%s%s\n' \
      "${NEON_MAGENTA}" "${SECT_CH}${SECT_CH}" "${NC}" \
      "${NEON_CYAN}${BOLD}" "${tag}" "${NC}" \
      "${BOLD}" "${title}" "${NC}"
    printf '%s%s%s\n' "${DIM}${NEON_CYAN}" "$(_repeat "${BOX_W}" "${RULE_CH}")" "${NC}"
  else
    printf '\n%s: %s\n' "${tag}" "${title}"
  fi
}

# Styled phase header for the deploy pipeline.
# phase "1/5" "downloading evi kit"
phase() {
  local num="$1" title="$2"
  if [[ "${STYLE_ENABLED}" -eq 1 ]]; then
    printf '\n%s>> phase %s%s  %s%s%s\n' \
      "${NEON_AMBER}${BOLD}" "${num}" "${NC}" \
      "${NEON_CYAN}${BOLD}" "${title}" "${NC}"
  else
    printf '\n--- phase %s: %s ---\n' "${num}" "${title}"
  fi
}

# Centered framed title (used for top-level screen headers).
title_box() {
  local title="$1"
  if [[ "${STYLE_ENABLED}" -eq 1 ]]; then
    echo ""
    box_top
    panel_row_center "${title}" "${NEON_CYAN}${BOLD}"
    box_bottom
  else
    printf '\n=== %s ===\n' "${title}"
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local reply
  read -r -p "${prompt} [${default}]: " reply
  reply="${reply:-$default}"
  # Latin y and Cyrillic у (common when the layout was Russian)
  [[ "$reply" =~ ^[YyуУ] ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_executable() {
  find "${SCRIPTS_DIR}" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

# Noninteractive apt: no needrestart TUI, do not restart sshd mid-install.
app_apt_get() {
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get "$@"
}

# Official Cockpit File browser (optional). Never fails Deploy or restore.
install_cockpit_files_best_effort() {
  if [[ -f "${SCRIPTS_DIR}/host/install-cockpit-files.sh" ]]; then
    bash "${SCRIPTS_DIR}/host/install-cockpit-files.sh" "${SCRIPT_DIR}" \
      --sudo-mode=interactive "$@" \
      || warn "cockpit file browser (cockpit-files) was not installed; continuing"
  fi
}

# Kit-managed fail2ban sshd jail. Hard-fail if the helper is missing or exits non-zero.
install_sshd_jail() {
  if [[ ! -f "${SCRIPTS_DIR}/host/install-fail2ban.sh" ]]; then
    err "install-fail2ban.sh is missing (${SCRIPTS_DIR}/host/install-fail2ban.sh)"
    return 1
  fi
  bash "${SCRIPTS_DIR}/host/install-fail2ban.sh" "${SCRIPT_DIR}" \
    --sudo-mode=interactive "$@"
}

# Host journald caps drop-in. Hard-fail if the helper is missing or exits non-zero.
install_journald_limits() {
  if [[ ! -f "${SCRIPTS_DIR}/host/journald-limits-ensure.sh" ]]; then
    err "journald-limits-ensure.sh is missing (${SCRIPTS_DIR}/host/journald-limits-ensure.sh)"
    return 1
  fi
  bash "${SCRIPTS_DIR}/host/journald-limits-ensure.sh" "${SCRIPT_DIR}" \
    --sudo-mode=interactive "$@"
}

# Install the Cockpit app-admin panel from this kit.
# $1 info message when the package is present and the installer returns.
# $2 warn message when cockpit-app-admin/manifest.json is absent.
# $3 optional log line printed before install.
install_cockpit_app_admin_panel() {
  local success_msg="$1"
  local missing_msg="$2"
  local start_msg="${3:-}"
  if [[ -f "${SCRIPT_DIR}/cockpit-app-admin/manifest.json" ]]; then
    if [[ -n "${start_msg}" ]]; then
      log "${start_msg}"
    fi
    bash "${SCRIPT_DIR}/scripts/host/cockpit-panel-sync.sh" "${SCRIPT_DIR}" --sync-only --sudo-mode=interactive
    info "${success_msg}"
  else
    warn "${missing_msg}"
  fi
}

# After deploy apt: pause if the host needs a reboot. Does not block the wizard.
pause_deploy_if_reboot_required() {
  if [[ ! -e /var/run/reboot-required ]]; then
    return 0
  fi

  warn "this host has a pending reboot. deploy is paused until after reboot."

  local reason=""
  if [[ -r /var/run/reboot-required ]]; then
    reason="$(tr -s '[:space:]' ' ' < /var/run/reboot-required 2>/dev/null || true)"
    reason="${reason#"${reason%%[![:space:]]*}"}"
    reason="${reason%"${reason##*[![:space:]]}"}"
    if [[ -n "${reason}" ]]; then
      log "reason: ${reason}"
    fi
  fi

  if [[ -f /var/run/reboot-required.pkgs ]]; then
    local pkgs=""
    pkgs="$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null || true)"
    pkgs="${pkgs#"${pkgs%%[![:space:]]*}"}"
    pkgs="${pkgs%"${pkgs##*[![:space:]]}"}"
    if [[ -n "${pkgs}" ]]; then
      log "packages that requested reboot: ${pkgs}"
    fi
  fi

  echo ""
  log "reboot this host, then run: cd ~/app && ./install.sh"
  log "and choose deploy again (your configuration is saved)."
  echo ""

  if confirm "reboot this host now?" n; then
    if ! sudo reboot; then
      err "reboot failed. reboot the host yourself, then run: cd ~/app && ./install.sh and choose deploy again."
      return 1
    fi
    return 1
  fi

  log "ok. reboot when you can, then run: cd ~/app && ./install.sh and choose deploy again."
  return 1
}

ensure_config_files() {
  mkdir -p "${CONFIG_DIR}"
  if [[ ! -f "${TARGET_ENV}" ]]; then
    cp "${TEMPLATE_ENV}" "${TARGET_ENV}"
    info "created ${TARGET_ENV} from template."
  fi
  if [[ ! -f "${TARGET_SECRETS}" ]]; then
    cp "${TEMPLATE_SECRETS}" "${TARGET_SECRETS}"
    info "created ${TARGET_SECRETS} from template."
  fi
  persist_github_token
}

# --- Validation Functions ---

validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || return 1
  local mask="${cidr##*/}"
  [[ "$mask" -ge 0 && "$mask" -le 32 ]]
}

validate_password() {
  local pass="$1"
  [[ ${#pass} -ge ${MIN_PASSWORD_LENGTH} ]]
}

validate_email() {
  local email="$1"
  # Basic format: user@domain.tld
  if [[ ! "${email}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 1
  fi
  # Reject .local domains (not valid for email)
  if [[ "${email}" =~ \.local$ ]]; then
    return 1
  fi
  # Reject localhost domain
  if [[ "${email}" =~ @localhost$ ]]; then
    return 1
  fi
  return 0
}

is_private_ip() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^127\. ]]
}

# Detect real block-device mounts, filtering out virtual/service FS.
# Populates parallel arrays: _DISK_MOUNTS, _DISK_TOTAL, _DISK_USED, _DISK_FREE, _DISK_PCT, _DISK_IS_SYS.
# Returns 0 on success (at least one disk found).
detect_available_disks() {
  _DISK_MOUNTS=()
  _DISK_TOTAL=()
  _DISK_USED=()
  _DISK_FREE=()
  _DISK_PCT=()
  _DISK_IS_SYS=()

  local sys_dev=""
  sys_dev=$(df --output=source / 2>/dev/null | tail -1 | tr -d '[:space:]') || true
  local home_dev=""
  home_dev=$(df --output=source "${HOME}" 2>/dev/null | tail -1 | tr -d '[:space:]') || true

  local skip_fs="tmpfs|devtmpfs|squashfs|overlay|fuse\.snapfuse|proc|sysfs|cgroup2?|efivarfs|securityfs|debugfs|tracefs|configfs|fusectl|pstore|bpf|hugetlbfs|mqueue|devpts|autofs|binfmt_misc|ramfs|nsfs"

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local mount_target="" source_dev="" fstype="" size_h="" used_h="" pct_raw=""
    mount_target=$(echo "${line}" | awk '{print $1}')
    source_dev=$(echo "${line}" | awk '{print $2}')
    fstype=$(echo "${line}" | awk '{print $3}')
    size_h=$(echo "${line}" | awk '{print $4}')
    used_h=$(echo "${line}" | awk '{print $5}')
    pct_raw=$(echo "${line}" | awk '{print $6}')

    # Local block devices only. Snap bind-mounts (Firefox hunspell) look like a second disk.
    [[ "${source_dev}" == /dev/* ]] || continue
    [[ "${source_dev}" == *\[* ]] && continue
    [[ "${mount_target}" == /snap/* || "${mount_target}" == /var/snap/* ]] && continue
    [[ "${mount_target}" == /boot || "${mount_target}" == /boot/* ]] && continue
    [[ "${mount_target}" == /sys/* ]] && continue
    [[ "${mount_target}" == /proc/* ]] && continue
    [[ "${mount_target}" == /run/* ]] && continue
    [[ "${mount_target}" == /dev/* ]] && continue
    echo "${fstype}" | grep -qE "^(${skip_fs})$" && continue

    local is_sys=0
    if [[ "${source_dev}" == "${sys_dev}" ]] || [[ "${mount_target}" == "/" ]]; then
      is_sys=1
    fi
    if [[ "${source_dev}" == "${home_dev}" ]] && [[ "${mount_target}" != "/" ]]; then
      is_sys=1
    fi

    local free_h=""
    free_h=$(df -h --output=avail "${mount_target}" 2>/dev/null | tail -1 | tr -d '[:space:]') || free_h="?"

    _DISK_MOUNTS+=("${mount_target}")
    _DISK_TOTAL+=("${size_h}")
    _DISK_USED+=("${used_h}")
    _DISK_FREE+=("${free_h}")
    _DISK_PCT+=("${pct_raw}")
    _DISK_IS_SYS+=("${is_sys}")
  done < <(findmnt -rno TARGET,SOURCE,FSTYPE,SIZE,USED,USE% --real 2>/dev/null || true)

  [[ ${#_DISK_MOUNTS[@]} -gt 0 ]]
}

# Render ASCII progress bar: render_disk_bar <use_percent> → "[████████░░░░░░░░░░░░]"
render_disk_bar() {
  local pct="${1%%%}"
  pct="${pct:-0}"
  local width=20
  local filled=$(( pct * width / 100 ))
  [[ ${filled} -gt ${width} ]] && filled=${width}
  local empty=$(( width - filled ))
  local ch_full='#' ch_empty='-'
  [[ "${UNICODE_OK}" -eq 1 ]] && { ch_full='█'; ch_empty='░'; }
  local fbar="" ebar=""
  local i
  for (( i=0; i<filled; i++ )); do fbar+="${ch_full}"; done
  for (( i=0; i<empty; i++ )); do ebar+="${ch_empty}"; done
  if [[ "${STYLE_ENABLED}" -eq 1 ]]; then
    printf "[%s%s%s%s%s]" "${NEON_CYAN}" "${fbar}" "${DIM}" "${ebar}" "${NC}"
  else
    printf "[%s%s]" "${fbar}" "${ebar}"
  fi
}

# Prompt user to choose a disk for a specific persistent data group.
# Sets global SELECTED_DATA_PATH to:
# - empty string: use default Podman volume location (system disk)
# - <mount>/data: use bind-mounted data directory on selected disk
prompt_data_storage_path() {
  local step_label="$1"
  local title="$2"
  local data_kind="$3"
  SELECTED_DATA_PATH=""

  section "${step_label}" "${title}"
  echo ""

  if detect_available_disks; then
    local disk_count=${#_DISK_MOUNTS[@]}
    local non_sys_count=0
    local best_non_sys_idx=-1
    local best_non_sys_free=0
    local i
    for (( i=0; i<disk_count; i++ )); do
      if [[ "${_DISK_IS_SYS[$i]}" -eq 0 ]]; then
        non_sys_count=$((non_sys_count + 1))
        local free_bytes
        free_bytes=$(df -B1 --output=avail "${_DISK_MOUNTS[$i]}" 2>/dev/null | tail -1 | tr -d '[:space:]') || free_bytes=0
        if [[ ${free_bytes} -gt ${best_non_sys_free} ]]; then
          best_non_sys_free=${free_bytes}
          best_non_sys_idx=${i}
        fi
      fi
    done

    if [[ ${non_sys_count} -eq 0 ]]; then
      # Single-disk scenario: show warning and conscious choice
      echo "  persistent ${data_kind} data grows over time."
      echo "  single disk detected:"
      echo ""
      local bar
      bar=$(render_disk_bar "${_DISK_PCT[0]}")
      printf "    %-12s %s total, %s used  %s %s\n" "${_DISK_MOUNTS[0]}" "${_DISK_TOTAL[0]}" "${_DISK_USED[0]}" "${bar}" "${_DISK_PCT[0]}"
      echo ""
      printf "  ${YELLOW}we recommend deploying application persistent data on a separate disk.${NC}\n"
      echo "  as your database and uploaded files grow, they may fill up"
      echo "  the system disk and cause the OS to stop working."
      echo "  a separate data disk isolates this risk."
      echo ""
      echo "  [1]  continue with this disk"
      echo "  [2]  exit and add a data disk first"
      echo ""
      local step_data_choice=""
      while [[ -z "${step_data_choice}" ]]; do
        read -r -p "  your choice [1]: " step_data_choice
        step_data_choice="${step_data_choice:-1}"
        case "${step_data_choice}" in
          1) SELECTED_DATA_PATH="" ;;
          2) info "exiting. attach a data disk, mount it, then re-run ./install.sh"; exit 0 ;;
          *) warn "please select 1 or 2"; step_data_choice="" ;;
        esac
      done
    else
      # Multi-disk scenario: show list with recommendations
      echo "  persistent ${data_kind} data grows over time."
      echo "  storing it on a separate disk protects the OS if data fills up."
      echo ""
      echo "  available disks:"
      echo ""
      local default_choice=$((best_non_sys_idx + 1))
      for (( i=0; i<disk_count; i++ )); do
        local bar label=""
        bar=$(render_disk_bar "${_DISK_PCT[$i]}")
        if [[ "${_DISK_IS_SYS[$i]}" -eq 1 ]]; then
          label="  (system)"
        elif [[ ${i} -eq ${best_non_sys_idx} ]]; then
          label="  <- recommended"
        fi
        printf "    [%d]  %-12s %6s total, %6s used  %s %4s%s\n" \
          "$((i + 1))" "${_DISK_MOUNTS[$i]}" "${_DISK_TOTAL[$i]}" "${_DISK_USED[$i]}" "${bar}" "${_DISK_PCT[$i]}" "${label}"
      done
      echo ""
      local step_data_num=""
      while [[ -z "${step_data_num}" ]]; do
        read -r -p "  where to store ${data_kind} volume data? [${default_choice}]: " step_data_num
        step_data_num="${step_data_num:-${default_choice}}"
        if [[ "${step_data_num}" =~ ^[0-9]+$ ]] && [[ "${step_data_num}" -ge 1 ]] && [[ "${step_data_num}" -le "${disk_count}" ]]; then
          break
        fi
        warn "enter a number between 1 and ${disk_count}"
        step_data_num=""
      done
      local chosen_idx=$((step_data_num - 1))
      local chosen_mount="${_DISK_MOUNTS[$chosen_idx]}"

      if [[ "${_DISK_IS_SYS[$chosen_idx]}" -eq 1 ]]; then
        warn "${data_kind} data will share space with the OS. consider a separate disk for production."
        SELECTED_DATA_PATH=""
      else
        # Validate write access
        local test_file="${chosen_mount}/.app-write-test-$$"
        if touch "${test_file}" 2>/dev/null; then
          rm -f "${test_file}" 2>/dev/null || true
          SELECTED_DATA_PATH="${chosen_mount}/data"
          info "${data_kind} volume data will be stored at: ${SELECTED_DATA_PATH}"
        else
          err "cannot write to ${chosen_mount}. check permissions (chown or chmod for current user)."
          warn "falling back to default location (system disk)."
          SELECTED_DATA_PATH=""
        fi
      fi
    fi
  else
    warn "could not detect disks. ${data_kind} data will be stored on the default location."
    SELECTED_DATA_PATH=""
  fi
}

# Prompt for SeaweedFS file storage capacity ceiling (GB).
# Sets global FS_VOLUME_MAX_GB. Does not pre-allocate disk space — maps to -volume.max in fs.container.
prompt_fs_volume_capacity() {
  local fs_data_path="$1" db_data_path="$2"
  local default_gb=100 mount_for_df="/" avail_gb=0

  if [[ -n "${fs_data_path}" ]]; then
    mount_for_df="$(dirname "${fs_data_path}")"
  elif [[ -n "${db_data_path}" ]]; then
    mount_for_df="$(dirname "${db_data_path}")"
  fi

  avail_gb=$(df -BG --output=avail "${mount_for_df}" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
  [[ -z "${avail_gb}" ]] && avail_gb=0

  section "step 7 (continued)" "file storage capacity"
  echo ""
  echo "  this sets the maximum capacity for uploaded files (SeaweedFS limit)."
  echo "  disk space is NOT reserved upfront — files grow as users upload."
  echo "  enter a whole number of gigabytes (GB), minimum 10, no fixed upper limit."
  echo "  default: ${default_gb} GB."
  if [[ "${avail_gb}" -gt 0 ]]; then
    echo "  selected disk has ~${avail_gb} GB free."
  fi
  echo ""

  local input_gb=""
  while [[ -z "${input_gb}" ]]; do
    read -r -p "  max file storage capacity in GB, minimum 10 [${default_gb}]: " input_gb
    input_gb="${input_gb:-${default_gb}}"
    if ! [[ "${input_gb}" =~ ^[0-9]+$ ]] || [[ "${input_gb}" -lt 10 ]]; then
      warn "enter a whole number of GB, at least 10 (e.g. 10, 100, 5000)"
      input_gb=""
      continue
    fi
    if [[ "${avail_gb}" -gt 0 ]] && [[ "${input_gb}" -gt "${avail_gb}" ]]; then
      warn "capacity (${input_gb} GB) exceeds free space on disk (~${avail_gb} GB)."
      warn "uploads may fail when the disk fills up before the SeaweedFS limit."
      if ! confirm "use ${input_gb} GB anyway?"; then
        input_gb=""
      fi
    fi
  done
  FS_VOLUME_MAX_GB="${input_gb}"
}

validate_user_certificate() {
  local cert_file="$1"
  local key_file="$2"
  local domain="$3"
  local validation_errors=0
  local error_messages=()
  
  # Check certificate file format
  if ! openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1; then
    error_messages+=("certificate file is not a valid x509 certificate")
    validation_errors=$((validation_errors + 1))
  fi
  
  # Check key file format
  if ! openssl rsa -in "${key_file}" -noout >/dev/null 2>&1 && ! openssl ec -in "${key_file}" -noout >/dev/null 2>&1; then
    error_messages+=("key file is not a valid RSA or EC private key")
    validation_errors=$((validation_errors + 1))
  fi
  
  # If certificate format is valid, check key match
  if [[ $validation_errors -eq 0 ]] && openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1; then
    # Check if key matches certificate
    if openssl rsa -in "${key_file}" -noout >/dev/null 2>&1; then
      # RSA key - compare modulus
      local cert_modulus
      local key_modulus
      cert_modulus=$(openssl x509 -noout -modulus -in "${cert_file}" 2>/dev/null | openssl md5 2>/dev/null | cut -d' ' -f2)
      key_modulus=$(openssl rsa -noout -modulus -in "${key_file}" 2>/dev/null | openssl md5 2>/dev/null | cut -d' ' -f2)
      if [[ -z "${cert_modulus}" ]] || [[ -z "${key_modulus}" ]] || [[ "${cert_modulus}" != "${key_modulus}" ]]; then
        error_messages+=("private key does not match the certificate")
        validation_errors=$((validation_errors + 1))
      fi
    elif openssl ec -in "${key_file}" -noout >/dev/null 2>&1; then
      # EC key - compare public key
      local cert_pub
      local key_pub
      cert_pub=$(openssl x509 -pubkey -noout -in "${cert_file}" 2>/dev/null | openssl md5 2>/dev/null | cut -d' ' -f2)
      key_pub=$(openssl ec -pubout -in "${key_file}" 2>/dev/null | openssl md5 2>/dev/null | cut -d' ' -f2)
      if [[ -z "${cert_pub}" ]] || [[ -z "${key_pub}" ]] || [[ "${cert_pub}" != "${key_pub}" ]]; then
        error_messages+=("private key does not match the certificate")
        validation_errors=$((validation_errors + 1))
      fi
    fi
  fi
  
  # Check certificate expiry
  if [[ $validation_errors -eq 0 ]] && openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1; then
    local expiry
    expiry=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)
    if [[ -n "${expiry}" ]]; then
      local expiry_epoch
      local now_epoch
      expiry_epoch=$(date -d "${expiry}" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "${expiry}" +%s 2>/dev/null || echo "0")
      now_epoch=$(date +%s)
      if [[ "${expiry_epoch}" != "0" ]] && [[ ${expiry_epoch} -lt ${now_epoch} ]]; then
        error_messages+=("certificate has expired (expired on: ${expiry})")
        validation_errors=$((validation_errors + 1))
      fi
    fi
  fi
  
  # Check domain match (only for public domains, not IP addresses)
  if [[ -n "${domain}" ]] && ! validate_ip "${domain}" && [[ $validation_errors -eq 0 ]] && openssl x509 -in "${cert_file}" -noout >/dev/null 2>&1; then
    local cert_domains
    cert_domains=$(openssl x509 -in "${cert_file}" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | grep -oE "DNS:[^, ]+" | sed 's/DNS://' || echo "")
    local cert_cn
    cert_cn=$(openssl x509 -in "${cert_file}" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p' || echo "")
    
    local domain_match=false
    # Check SAN entries
    if echo "${cert_domains}" | grep -q "^${domain}$" || echo "${cert_domains}" | grep -q "^\*\.${domain#*.}$"; then
      domain_match=true
    # Check CN
    elif [[ "${cert_cn}" == "${domain}" ]] || [[ "${cert_cn}" == "*.${domain#*.}" ]]; then
      domain_match=true
    fi
    
    if [[ "${domain_match}" == "false" ]] && [[ -n "${cert_domains}" ]] && [[ -n "${cert_cn}" ]]; then
      error_messages+=("certificate does not match domain '${domain}' (certificate is for: ${cert_cn} or ${cert_domains})")
      validation_errors=$((validation_errors + 1))
    fi
  fi
  
  # Return results
  if [[ $validation_errors -gt 0 ]]; then
    printf "%s\n" "${error_messages[@]}"
    return 1
  fi
  
  return 0
}

# --- Configuration status helpers (manual config menu, deploy TLS guards) ---

check_env_status() {
  if [[ ! -f "${TARGET_ENV}" ]]; then
    echo "missing"
    return
  fi
  
  local domain
  domain=$(grep "^APP_DOMAIN=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
  
  if [[ -z "${domain}" ]] || [[ "${domain}" == "app.example.com" ]]; then
    echo "not_configured"
    return
  fi
  
  echo "ready:${domain}"
}

# Human-readable main app URL for main menu (from APP_DOMAIN in app.env).
get_app_main_url_for_menu() {
  if [[ ! -f "${TARGET_ENV}" ]]; then
    printf "%s" "unknown (app.env missing)"
    return
  fi
  local domain
  domain=$(grep "^APP_DOMAIN=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
  if [[ -z "${domain}" ]] || [[ "${domain}" == "app.example.com" ]]; then
    printf "%s" "unknown (set APP_DOMAIN in app.env)"
    return
  fi
  printf "https://%s" "${domain}"
}

check_secrets_status() {
  if [[ ! -f "${TARGET_SECRETS}" ]]; then
    echo "missing"
    return
  fi
  
  local required_keys=("APP_POSTGRES_PASSWORD" "APP_ADMIN_DB_PASSWORD" "APP_DB_PASSWORD")
  
  for key in "${required_keys[@]}"; do
    local val
    val=$(grep "^${key}=" "${TARGET_SECRETS}" 2>/dev/null | cut -d'=' -f2 || echo "")
    if [[ -z "${val}" ]]; then
      echo "incomplete"
      return
    fi
  done
  
  echo "ready"
}

check_tls_status() {
  local tls_mode
  tls_mode=$(grep "^APP_TLS_MODE=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "letsencrypt")
  
  if [[ "${tls_mode}" == "letsencrypt" ]]; then
    local email
    email=$(grep "^APP_ACME_EMAIL=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
    if [[ -n "${email}" ]] && [[ "${email}" != *"@example.com" ]]; then
      echo "ready:letsencrypt"
    else
      echo "needs_email"
    fi
  elif [[ "${tls_mode}" == "manual" ]]; then
    if [[ -f "${TLS_DIR}/cert.pem" ]] && [[ -f "${TLS_DIR}/key.pem" ]]; then
      echo "ready:manual"
    else
      echo "missing_certs"
    fi
  else
    echo "not_configured"
  fi
}

# --- Prerequisites ---

check_os() {
  printf "  checking os... "
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    local id_like=" ${ID_LIKE:-} "
    local compatible=false
    if [[ "${ID}" == "ubuntu" ]] || [[ "${ID}" == "debian" ]] || [[ "${ID}" == "linuxmint" ]] || \
       [[ "${ID}" == "pop" ]] || [[ "${ID}" == "neon" ]] || [[ "${ID}" == "elementary" ]] || \
       [[ "${ID}" == "kubuntu" ]] || [[ "${ID}" == "lubuntu" ]] || [[ "${ID}" == "xubuntu" ]]; then
      compatible=true
    elif [[ "${id_like}" =~ (^| )debian( |$) ]] || [[ "${id_like}" =~ (^| )ubuntu( |$) ]]; then
      compatible=true
    fi
    if [[ "${compatible}" == "true" ]]; then
      local label="${NAME:-${ID}}"
      [[ -n "${VERSION_ID:-}" ]] && label="${label} ${VERSION_ID}"
      printf "${GREEN}ok (${label})${NC}\n"
      return 0
    else
      printf "${YELLOW}warn (${NAME} ${VERSION_ID})${NC}\n"
      return 1
    fi
  else
    printf "${RED}unknown${NC}\n"
    return 1
  fi
}

check_resources() {
  printf "  checking resources... "
  local host_gib profile_text=""
  local rt="${SCRIPTS_DIR}/lib/render-templates.sh"
  local helpers=0
  if [[ -f "${rt}" ]]; then
    if ! declare -F deploy_pick_state_profile >/dev/null 2>&1; then
      # shellcheck disable=SC1090
      source "${rt}"
    fi
    helpers=1
  fi
  if [[ "${helpers}" -eq 1 ]]; then
    host_gib="$(deploy_host_mem_gib)"
  elif [[ -n "${APP_HOST_MEM_GIB:-}" ]]; then
    host_gib="${APP_HOST_MEM_GIB}"
  else
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
    host_gib=$((mem_kb / 1024 / 1024))
  fi
  if [[ "${helpers}" -eq 1 ]]; then
    if ! deploy_check_host_mem; then
      printf "${RED}fail (host ram < 2gb (minimum 2gb). deployment stopped.)${NC}\n"
      return 1
    fi
    local profile limit maxmem
    if [[ -n "${APP_LIMIT_MEM_STATE:-}" ]]; then
      limit="${APP_LIMIT_MEM_STATE:-}"
      profile="$(deploy_state_profile_name_for_limit "${limit}")"
    else
      profile="$(deploy_pick_state_profile)"
      limit="$(deploy_state_container_limit_for_profile "${profile}")"
    fi
    maxmem="$(deploy_state_maxmemory_for_limit "${limit}")"
    profile_text="${profile}, state ${limit} / valkey ${maxmem}"
  else
    if [[ "${host_gib}" -lt 2 ]]; then
      printf "${RED}fail (host ram < 2gb (minimum 2gb). deployment stopped.)${NC}\n"
      return 1
    fi
  fi
  if [[ "${host_gib}" -lt 4 ]]; then
    if [[ -n "${profile_text}" ]]; then
      printf "${YELLOW}warn (ram 2-4gb: suitable for testing, not recommended for production; %s)${NC}\n" "${profile_text}"
    else
      printf "${YELLOW}warn (ram 2-4gb: suitable for testing, not recommended for production)${NC}\n"
    fi
    return 0
  fi
  if [[ -n "${profile_text}" ]]; then
    printf "${GREEN}ok (%s)${NC}\n" "${profile_text}"
  else
    printf "${GREEN}ok${NC}\n"
  fi
  return 0
}

check_podman() {
  printf "  checking podman... "
  if require_cmd podman; then
    printf "${GREEN}ok ($(podman --version | head -1))${NC}\n"
    return 0
  else
    printf "${RED}missing${NC}\n"
    return 1
  fi
}

check_ports() {
  printf "  checking rootless ports... "
  local port_start
  port_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo "1024")
  if [[ "$port_start" -le 80 ]]; then
    printf "${GREEN}ok (start=${port_start})${NC}\n"
    return 0
  else
    printf "${RED}not configured (start=${port_start})${NC}\n"
    return 1
  fi
}

install_prerequisites_all() {
  log "installing prerequisites for container environment on this host server..."
  echo ""
  echo "this will install:"
  echo "  - podman: container runtime for running application services"
  echo "  - curl: command-line tool for HTTP requests"
  echo "  - openssl: TLS/SSL utilities"
  echo "  - cockpit: web-based tool for server and containers management (https://<server-ip>:9090)"
  echo "  - pgadmin: web-console for postgres database administration (http://<server-ip>:5445)"
  echo ""

  if ! confirm "proceed with installation?"; then
    return 0
  fi

  ensure_config_files
  echo ""

  # --- Core prerequisites ---
  log "installing core prerequisites (podman, uidmap, curl, openssl, ufw)..."
  app_apt_get update
  app_apt_get install -y podman uidmap curl openssl ufw

  log "configuring rootless ports (80/443)..."
  sudo rm -f /etc/sysctl.d/99-evi-rootless.conf 2>/dev/null || true
  echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-app-rootless.conf
  sudo sysctl -p /etc/sysctl.d/99-app-rootless.conf || true

  if ! loginctl show-user "$(whoami)" -p Linger 2>/dev/null | grep -q "yes"; then
    log "enabling systemd linger for $(whoami)..."
    sudo loginctl enable-linger "$(whoami)"
  fi

  if command -v ufw >/dev/null 2>&1; then
    ensure_executable
    if "${SCRIPTS_DIR}/host/ufw-ensure-active.sh"; then
      log "opening application ports 80, 443 in ufw..."
      sudo ufw allow 80/tcp
      sudo ufw allow 443/tcp
    else
      warn "ufw could not be enabled; skipping application firewall ports."
    fi
  fi

  # --- Cockpit ---
  log "installing cockpit..."
  app_apt_get update
  app_apt_get install -y cockpit cockpit-podman
  sudo systemctl enable --now cockpit.socket

  systemctl --user enable --now podman.socket
  info "cockpit installed. access at https://<server-ip>:9090"

  # --- Cockpit EVI Admin Tools panel ---
  install_cockpit_app_admin_panel \
    "cockpit sidebar: 'app admin tools' panel added (backup, admin functions)." \
    "cockpit-app-admin package not found; skipping admin tools panel." \
    "adding app admin tools panel to cockpit sidebar..."

  # --- Deploy update kit (update scripts + migrations) ---
  if [[ -d "${SCRIPT_DIR}/update/scripts" ]]; then
    info "update kit already deployed at ${SCRIPT_DIR}/update/"
  else
    local update_kit_src=""
    if [[ -d "${SCRIPT_DIR}/update-kit" ]]; then
      update_kit_src="${SCRIPT_DIR}/update-kit"
    elif [[ -d "${SCRIPT_DIR}/../update-kit" ]]; then
      update_kit_src="$(cd "${SCRIPT_DIR}/../update-kit" && pwd)"
    fi

    if [[ -n "${update_kit_src}" ]]; then
      log "deploying update kit from ${update_kit_src}..."
      mkdir -p "${SCRIPT_DIR}/update"
      cp -a "${update_kit_src}/." "${SCRIPT_DIR}/update/"
      if [[ -d "${SCRIPT_DIR}/update/scripts" ]]; then
        chmod +x "${SCRIPT_DIR}/update/scripts/"*.sh 2>/dev/null || true
      fi
      info "update kit deployed to ${SCRIPT_DIR}/update/"
    else
      warn "update kit source not found; Cockpit update panel will not work until update kit is deployed."
      warn "expected at ${SCRIPT_DIR}/update-kit/ or ${SCRIPT_DIR}/../update-kit/ (sparse-checkout: deploy-kit and update-kit at repo root)"
    fi
  fi

  # --- Configure pgAdmin ---
  log "configuring pgadmin..."
  if [[ -f "${TARGET_ENV}" ]]; then
    if grep -q "^APP_PGADMIN_ENABLED=" "${TARGET_ENV}"; then
      sed -i "s|^APP_PGADMIN_ENABLED=.*|APP_PGADMIN_ENABLED=true|" "${TARGET_ENV}"
    else
      echo "APP_PGADMIN_ENABLED=true" >> "${TARGET_ENV}"
    fi
    if grep -q "^APP_PGADMIN_EMAIL=" "${TARGET_ENV}"; then
      sed -i "s|^APP_PGADMIN_EMAIL=.*|APP_PGADMIN_EMAIL=${APP_PGADMIN_EMAIL_DEFAULT}|" "${TARGET_ENV}"
    else
      echo "APP_PGADMIN_EMAIL=${APP_PGADMIN_EMAIL_DEFAULT}" >> "${TARGET_ENV}"
    fi
    info "pgadmin enabled in app.env"
    info "pgadmin login: ${APP_PGADMIN_EMAIL_DEFAULT}"
  fi

  echo ""
  printf "${GREEN}=== prerequisites installation summary ===${NC}\n"
  echo ""
  echo "installed tools:"
  printf "  ${GREEN}✓${NC} podman\n"
  printf "  ${GREEN}✓${NC} curl\n"
  printf "  ${GREEN}✓${NC} openssl\n"
  printf "  ${GREEN}✓${NC} cockpit\n"
  printf "  ${GREEN}✓${NC} pgadmin\n"
  echo ""
  printf "${YELLOW}${BOLD}IMPORTANT:${NC}${YELLOW} access to cockpit (9090) and pgadmin (5445) is configured in step 2 of environment configuration (localhost, specific hosts, or subnet).${NC}\n"
  echo ""

  read -r -p "press enter to continue..."
}

# --- Guided Environment Configuration ---

generate_password() {
  if require_cmd openssl; then
    openssl rand -base64 32 | tr -d '/+=' | cut -c1-24
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}

# Returns human-readable "allowed" string for cockpit access (from APP_FIREWALL_ADMIN_ACCESS and APP_FIREWALL_ADMIN_ALLOWED).
# Call after load_deploy_env so these vars are set. Used in deployment summary.
get_cockpit_allowed_summary() {
  local access="${APP_FIREWALL_ADMIN_ACCESS:-skip}"
  local allowed="${APP_FIREWALL_ADMIN_ALLOWED:-}"
  case "${access}" in
    localhost) printf "%s" "this server only (127.0.0.1)" ;;
    allowed_ips) printf "%s" "${allowed:-no IPs configured}" ;;
    allowed_cidr) printf "%s" "${allowed:-no CIDR configured}" ;;
    any) printf "%s" "any computer" ;;
    skip|*) printf "%s" "please finish firewall configuration to define allowed ip addresses or subnets connections to port 9090 of your host server." ;;
  esac
}

# Apply UFW rules for cockpit (9090) and pgadmin (5445): delete existing rules then add from app.env. Same workflow for first run and reconfigure.
apply_firewall_admin_tools() {
  [[ -f "${TARGET_ENV}" ]] || return 0
  ensure_executable
  log "applying firewall rules for cockpit (ports 9090, 5445)..."
  "${SCRIPTS_DIR}/host/ufw-ensure-active.sh" || warn "ufw could not be enabled; admin tool firewall rules may be skipped."
  "${SCRIPTS_DIR}/host/ufw-delete-rules.sh"
  "${SCRIPTS_DIR}/host/ufw-add-rules.sh" "${TARGET_ENV}"
}

# GitHub Releases (APP_INSTALL_REPO): fetch tag list in API order (newest first). Sets APP_GH_FETCH_HTTP_CODE on HTTP failure.
APP_GH_FETCH_HTTP_CODE=""
fetch_github_release_tags() {
  local _varname="$1"
  APP_GH_FETCH_HTTP_CODE=""
  if ! require_cmd curl; then
    err "curl is required to list releases. install curl, then re-run configure."
    return 1
  fi
  local api_url="https://api.github.com/repos/${APP_INSTALL_REPO}/releases?per_page=100"
  local tmp_resp http_code _tags_result
  tmp_resp=$(mktemp)
  http_code=$(github_curl -sS --connect-timeout 15 --max-time 45 -w "%{http_code}" -o "${tmp_resp}" -H "Accept: application/vnd.github+json" "${api_url}" 2>/dev/null) || true
  if [[ "${http_code}" != "200" ]]; then
    APP_GH_FETCH_HTTP_CODE="${http_code}"
    rm -f "${tmp_resp}"
    return 1
  fi
  _tags_result=$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "${tmp_resp}" 2>/dev/null | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
  rm -f "${tmp_resp}"
  if [[ -z "${_tags_result}" ]]; then
    return 2
  fi
  printf -v "${_varname}" '%s' "${_tags_result}"
  return 0
}

# First tag in GitHub order with version strictly x.y.z (optional leading v/V); skips prerelease suffixes (e.g. 0.15.2-b1). Prints tag to stdout.
pick_first_stable_release_tag() {
  local tags_raw="$1"
  local tag ver
  while IFS= read -r tag; do
    [[ -z "${tag}" ]] && continue
    ver="${tag#[vV]}"
    if [[ "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "${tag}"
      return 0
    fi
  done <<< "${tags_raw}"
  return 1
}

# Read current kit version from SCRIPT_DIR/package.json. Prints version to stdout; returns 1 if unavailable.
get_current_kit_version() {
  local pkg="${SCRIPT_DIR}/package.json"
  [[ -f "${pkg}" ]] || return 1
  local ver=""
  ver=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "${pkg}" 2>/dev/null | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
  [[ -n "${ver}" ]] && printf '%s' "${ver}" && return 0
  return 1
}

# Download kit archive (evi-<version>.tar.gz) from GitHub Release file and replace deploy-kit files,
# update-kit/, and package.json on disk. Re-creates config/app.env and config/app.secrets.env from new templates.
# Tries the official kit asset first; on timeout/non-200 falls back to the GitHub API source tarball
# (codeload) and accepts one nested prefix (${top_dir}/deploy-kit). Avoids hanging on blocked
# githubusercontent CDN hosts.
# Args: $1=tag (e.g. v0.15.2), $2=version (e.g. 0.15.2). Returns 0 on success.
download_release_kit_archive() {
  local tag="$1" version="$2"
  local archive_url="https://github.com/${APP_INSTALL_REPO}/releases/download/${tag}/evi-${version}.tar.gz"
  local tarball_url="https://api.github.com/repos/${APP_INSTALL_REPO}/tarball/${tag}"

  log "downloading kit archive for version ${version}..."
  local tmp_archive
  tmp_archive=$(mktemp "${SCRIPT_DIR}/app-kit-XXXXXX.tar.gz")

  local http_code
  http_code=$(github_curl -sS -L --fail --connect-timeout 10 --max-time 90 -w "%{http_code}" -o "${tmp_archive}" "${archive_url}" 2>/dev/null) || true
  if [[ "${http_code}" != "200" ]]; then
    log "release asset unavailable (HTTP ${http_code:-000}); falling back to GitHub API tarball..."
    http_code=$(github_curl -sS -L --connect-timeout 15 --max-time 120 -w "%{http_code}" \
      -H "Accept: application/vnd.github+json" \
      -o "${tmp_archive}" "${tarball_url}" 2>/dev/null) || true
    if [[ "${http_code}" != "200" ]]; then
      local _app_gh_hint=""
      if [[ -z "${APP_GITHUB_TOKEN:-}" ]] && [[ "${http_code}" == "401" || "${http_code}" == "403" || "${http_code}" == "404" ]]; then
        _app_gh_hint=" (the repository may be private — set APP_GITHUB_TOKEN and retry)"
      fi
      err "failed to download kit archive (HTTP ${http_code})${_app_gh_hint}"
      rm -f "${tmp_archive}"
      return 1
    fi
  fi

  if ! tar -tzf "${tmp_archive}" >/dev/null 2>&1; then
    err "downloaded file is not a valid tar.gz archive"
    rm -f "${tmp_archive}"
    return 1
  fi

  local staging_dir staging_root
  staging_dir=$(mktemp -d "${SCRIPT_DIR}/app-staging-XXXXXX")
  staging_root="${staging_dir}"

  if ! tar -xzf "${tmp_archive}" -C "${staging_dir}" 2>/dev/null; then
    err "failed to extract kit archive"
    rm -rf "${staging_root}" "${tmp_archive}"
    return 1
  fi
  rm -f "${tmp_archive}"

  if [[ ! -d "${staging_dir}/deploy-kit" ]]; then
    for nested in "${staging_dir}"/*/deploy-kit; do
      [[ -d "${nested}" ]] || continue
      staging_dir="$(cd "$(dirname "${nested}")" && pwd)"
      break
    done
  fi

  if [[ ! -d "${staging_dir}/deploy-kit" ]]; then
    err "archive does not contain deploy-kit/"
    rm -rf "${staging_root}"
    return 1
  fi

  local src="${staging_dir}/deploy-kit"
  local dir
  for dir in scripts env quadlet-templates reverse-proxy state pgadmin systemd-templates; do
    if [[ -d "${src}/${dir}" ]]; then
      rm -rf "${SCRIPT_DIR}/${dir}"
      cp -a "${src}/${dir}" "${SCRIPT_DIR}/${dir}"
    fi
  done
  for dir in "${src}"/cockpit-*; do
    [[ -d "${dir}" ]] || continue
    local dname
    dname=$(basename "${dir}")
    rm -rf "${SCRIPT_DIR}/${dname}"
    cp -a "${dir}" "${SCRIPT_DIR}/${dname}"
  done

  if [[ -d "${staging_dir}/update-kit" ]]; then
    rm -rf "${SCRIPT_DIR}/update-kit"
    cp -a "${staging_dir}/update-kit" "${SCRIPT_DIR}/update-kit"
  fi

  if [[ -f "${staging_dir}/package.json" ]]; then
    cp -f "${staging_dir}/package.json" "${SCRIPT_DIR}/package.json"
  fi

  # Copy install.sh and prerequisites.conf from the kit (version-matched for future runs)
  if [[ -f "${src}/install.sh" ]]; then
    cp -f "${src}/install.sh" "${SCRIPT_DIR}/install.sh"
    chmod +x "${SCRIPT_DIR}/install.sh"
  fi
  if [[ -f "${src}/prerequisites.conf" ]]; then
    cp -f "${src}/prerequisites.conf" "${SCRIPT_DIR}/prerequisites.conf"
  fi

  if [[ -d "${SCRIPT_DIR}/scripts" ]]; then
    find "${SCRIPT_DIR}/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
  fi
  if [[ -d "${SCRIPT_DIR}/update-kit/scripts" ]]; then
    chmod +x "${SCRIPT_DIR}/update-kit/scripts/"*.sh 2>/dev/null || true
  fi

  mkdir -p "${CONFIG_DIR}"
  if [[ -f "${TEMPLATE_ENV}" ]]; then
    cp -f "${TEMPLATE_ENV}" "${TARGET_ENV}"
  fi
  if [[ -f "${TEMPLATE_SECRETS}" ]]; then
    cp -f "${TEMPLATE_SECRETS}" "${TARGET_SECRETS}"
  fi
  persist_github_token

  rm -rf "${staging_root}"
  info "kit archive for version ${version} extracted successfully."
  return 0
}

guided_setup() {
  local reconfigure_mode=0
  [[ "${1:-}" == "reconfigure" ]] && reconfigure_mode=1
  title_box "guided environment configuration"
  echo ""
  if [[ "${reconfigure_mode}" -eq 1 ]]; then
    echo "this wizard will help you change your application configuration. you can keep current settings or set new ones."
  else
    echo "this wizard will help you configure the application for deployment."
  fi
  echo ""
  
  ensure_config_files
  
  local current_domain="" current_tls_mode="" current_acme_email="" current_firewall_access="" current_firewall_allowed="" current_seed_demo_data=""
  if [[ "${reconfigure_mode}" -eq 1 ]]; then
    current_domain=$(grep "^APP_DOMAIN=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    current_tls_mode=$(grep "^APP_TLS_MODE=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "letsencrypt")
    current_acme_email=$(grep "^APP_ACME_EMAIL=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    current_firewall_access=$(grep "^APP_FIREWALL_ADMIN_ACCESS=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
    current_firewall_allowed=$(grep "^APP_FIREWALL_ADMIN_ALLOWED=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    current_seed_demo_data=$(grep "^APP_SEED_DEMO_DATA=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]' || echo "false")
    current_fe_image=$(grep "^APP_FE_IMAGE=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    current_be_image=$(grep "^APP_BE_IMAGE=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    current_db_image=$(grep "^APP_DB_IMAGE=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  fi
  
  # Step 1: Access type (option 0 = keep current when reconfigure)
  section "step 1" "how will users connect to your application?"
  echo ""
  if [[ "${reconfigure_mode}" -eq 1 ]]; then
    local step1_keep_label="not set"
    [[ -n "${current_domain}" ]] && step1_keep_label="${current_domain}"
    echo "  0) keep current setting (${step1_keep_label})"
  fi
  echo "  1) private ip or intranet dns name"
  echo "  2) public dns domain"
  echo "  3) public ip address"
  echo ""
  
  local access_type=""
  local domain=""
  local tls_mode=""
  local acme_email=""
  local cert_choice=""
  while [[ -z "${access_type}" ]]; do
    if [[ "${reconfigure_mode}" -eq 1 ]]; then
      read -r -p "select [0-3]: " step1_choice
    else
      read -r -p "select [1-3]: " step1_choice
    fi
    case "${step1_choice}" in
      0)
        if [[ "${reconfigure_mode}" -eq 1 ]] && [[ -n "${current_domain}" ]]; then
          domain="${current_domain}"
          if [[ "${current_tls_mode}" == "letsencrypt" ]]; then
            access_type="public_domain"
            tls_mode="letsencrypt"
            acme_email="${current_acme_email}"
            cert_choice="letsencrypt"
          elif validate_ip "${current_domain}"; then
            access_type="public_ip"
            tls_mode="manual"
          else
            access_type="internal"
            tls_mode="manual"
          fi
        elif [[ "${reconfigure_mode}" -eq 1 ]]; then
          warn "no current setting; please select 1, 2, or 3"
        fi
        ;;
      1) access_type="internal" ;;
      2) access_type="public_domain" ;;
      3) access_type="public_ip" ;;
      *) warn "please select $([[ "${reconfigure_mode}" -eq 1 ]] && echo "0, " )1, 2, or 3" ;;
    esac
  done
  
  if [[ -z "${domain}" ]]; then
  if [[ "${access_type}" == "public_domain" ]]; then
    while [[ -z "${domain}" ]]; do
      read -r -p "enter your public domain name (e.g., app.example.com): " domain
      if ! validate_domain "${domain}"; then
        warn "invalid domain format"
        domain=""
      fi
    done
  elif [[ "${access_type}" == "public_ip" ]]; then
    while [[ -z "${domain}" ]]; do
      read -r -p "enter your public ip address: " domain
      if ! validate_ip "${domain}"; then
        warn "invalid ip address format"
        domain=""
      fi
    done
    # public_ip always uses manual TLS
  else
    while [[ -z "${domain}" ]]; do
      read -r -p "enter ip address or domain name: " domain
      if ! validate_ip "${domain}" && ! validate_domain "${domain}"; then
        warn "invalid ip or domain format"
        domain=""
      fi
    done
    # internal always uses manual TLS
  fi
  fi
  
  # Step 2: TLS certificate (option 0 = keep current certificate when reconfigure)
  local generate_certs="yes"
  
  echo ""
  section "step 2" "tls certificate configuration"
  echo ""
  if [[ "${access_type}" == "public_domain" ]]; then
    if [[ "${reconfigure_mode}" -eq 1 ]] && [[ -n "${current_tls_mode}" ]]; then
      echo "  0) keep current certificate"
    fi
    echo "  1) let's encrypt (automatic)"
    echo "  2) use my own certificates"
    echo ""
    while [[ -z "${cert_choice}" ]]; do
      if [[ "${reconfigure_mode}" -eq 1 ]] && [[ -n "${current_tls_mode}" ]]; then
        read -r -p "select [0-2]: " step2_tls
      else
        read -r -p "select [1-2]: " step2_tls
      fi
      case "${step2_tls}" in
        0)
          if [[ "${reconfigure_mode}" -eq 1 ]] && [[ -n "${current_tls_mode}" ]]; then
            tls_mode="${current_tls_mode}"
            cert_choice="keep"
            [[ "${current_tls_mode}" == "letsencrypt" ]] && acme_email="${current_acme_email}"
          else
            warn "please select 1 or 2"
          fi
          ;;
        1) tls_mode="letsencrypt"; cert_choice="letsencrypt" ;;
        2) tls_mode="manual"; cert_choice="own"; generate_certs="no" ;;
        *) warn "please select $([[ "${reconfigure_mode}" -eq 1 ]] && [[ -n "${current_tls_mode}" ]] && echo "0, " )1 or 2" ;;
      esac
    done
    if [[ "${tls_mode}" == "letsencrypt" ]]; then
      while [[ -z "${acme_email}" ]]; do
        read -r -p "enter email for let's encrypt account operations: " acme_email
        if [[ ! "${acme_email}" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
          warn "invalid email format"
          acme_email=""
        fi
      done
    fi
  else
    # internal or public_ip: manual TLS only
    tls_mode="manual"
    if [[ "${reconfigure_mode}" -eq 1 ]]; then
      echo "  0) keep current certificate"
    fi
    echo "  1) auto-generate self-signed certificate (recommended)"
    echo "  2) use my own certificates"
    echo ""
    while [[ -z "${cert_choice}" ]]; do
      if [[ "${reconfigure_mode}" -eq 1 ]]; then
        read -r -p "select [0-2]: " step2_tls
      else
        read -r -p "select [1-2]: " step2_tls
      fi
      case "${step2_tls}" in
        0)
          if [[ "${reconfigure_mode}" -eq 1 ]]; then
            if [[ -f "${TLS_DIR}/cert.pem" ]] && [[ -f "${TLS_DIR}/key.pem" ]]; then
              generate_certs="no"
              cert_choice="keep"
            else
              generate_certs="yes"
              cert_choice="keep"
            fi
          else
            warn "please select 1 or 2"
          fi
          ;;
        1) generate_certs="yes"; cert_choice="auto" ;;
        2) generate_certs="no"; cert_choice="own" ;;
        *) warn "please select $([[ "${reconfigure_mode}" -eq 1 ]] && echo "0, " )1 or 2" ;;
      esac
    done
  fi
  
  # Handle own certificates (manual mode, user provides files; skip when keeping current cert)
  if [[ "${tls_mode}" == "manual" ]] && [[ "${generate_certs}" == "no" ]] && [[ "${cert_choice}" != "keep" ]]; then
    echo ""
    echo "please place your certificates in: ${TLS_DIR}/"
    echo "  - cert.pem (server certificate)"
    echo "  - key.pem (private key)"
    echo ""
    read -r -p "press enter when files are ready..."
    
    if [[ ! -f "${TLS_DIR}/cert.pem" ]] || [[ ! -f "${TLS_DIR}/key.pem" ]]; then
      err "certificates not found in ${TLS_DIR}/"
      warn "you can add them later and run deployment again."
    else
      echo ""
      log "validating certificates..."
      local validation_errors
      validation_errors=$(validate_user_certificate "${TLS_DIR}/cert.pem" "${TLS_DIR}/key.pem" "${domain}" 2>&1)
      local validation_result=$?
      if [[ $validation_result -ne 0 ]]; then
        echo ""
        err "certificate validation failed!"
        while IFS= read -r error_msg; do
          [[ -n "${error_msg}" ]] && info "  ${error_msg}"
        done <<< "${validation_errors}"
        echo ""
        warn "deployment may fail if certificates are invalid."
        warn "you can fix certificates later and run deployment again."
        if ! confirm "continue anyway?"; then
          warn "configuration cancelled."
          return
        fi
      else
        info "certificates validated successfully."
      fi
    fi
  fi
  
  # Step 3: Firewall — from where may admins connect to cockpit (ports 9090, 5445)
  echo ""
  section "step 3" "from which ip addresses or subnets may admins connect to cockpit?"
  echo ""
  echo "cockpit is the web interface for administration of host server and containers. you should connect to cockpit only from trusted locations. choose from where it can be opened in a browser."
  echo ""
  if [[ "${reconfigure_mode}" -eq 1 ]]; then
    local step3_keep_label="${current_firewall_access:-not set}"
    [[ -n "${current_firewall_allowed}" ]] && step3_keep_label="${current_firewall_access} (${current_firewall_allowed})"
    echo "  0) keep current setting (${step3_keep_label})"
  fi
  echo "  1) from specific computer(s) by address"
  echo "     (enter one or more IP addresses, e.g. 192.168.1.10 or 192.168.1.10, 192.168.1.11)"
  echo ""
  echo "  2) from all computers in a local network range"
  echo "     (enter range in the form address/mask, e.g. 192.168.1.0/24 or 172.31.0.0/16)"
  echo ""
  echo "  3) only from this server"
  echo "     (you open cockpit in a browser only when on the same machine; requires a graphical session on the server, e.g. desktop or remote desktop — not typical for headless servers)"
  echo ""
  echo "  4) from any computer (not recommended)"
  echo "     (anyone who knows the address can try to open cockpit; use only for testing)"
  echo ""
  echo "  5) do not change firewall now"
  echo "     (you will configure access yourself later)"
  echo ""
  local firewall_access=""
  local firewall_allowed=""
  while [[ -z "${firewall_access}" ]]; do
    if [[ "${reconfigure_mode}" -eq 1 ]]; then
      read -r -p "select [0-5]: " step3_c
    else
      read -r -p "select [1-5]: " step3_c
    fi
    case "${step3_c}" in
      0)
        if [[ "${reconfigure_mode}" -eq 1 ]] && [[ -n "${current_firewall_access}" ]]; then
          firewall_access="${current_firewall_access}"
          firewall_allowed="${current_firewall_allowed}"
        elif [[ "${reconfigure_mode}" -eq 1 ]]; then
          warn "no current setting; please select 1, 2, 3, 4, or 5"
        fi
        ;;
      1) firewall_access="allowed_ips" ;;
      2) firewall_access="allowed_cidr" ;;
      3) firewall_access="localhost" ;;
      4) firewall_access="any" ;;
      5) firewall_access="skip" ;;
      *) warn "please select $([[ "${reconfigure_mode}" -eq 1 ]] && echo "0, " )1, 2, 3, 4, or 5" ;;
    esac
  done
  if [[ "${firewall_access}" == "allowed_ips" ]]; then
    while true; do
      read -r -p "enter IP address(es), separated by commas (e.g. 192.168.1.10, 192.168.1.11): " firewall_allowed
      firewall_allowed=$(echo "${firewall_allowed}" | tr -d ' ')
      [[ -z "${firewall_allowed}" ]] && warn "invalid format, try again" && continue
      local ok=1
      while IFS=',' read -r ip; do
        ip=$(echo "${ip}" | tr -d ' ')
        [[ -z "${ip}" ]] && continue
        if ! validate_ip "${ip}"; then
          ok=0
          break
        fi
      done <<< "${firewall_allowed}"
      [[ "${ok}" -eq 1 ]] && break
      warn "invalid format, try again"
    done
  elif [[ "${firewall_access}" == "allowed_cidr" ]]; then
    while [[ -z "${firewall_allowed}" ]]; do
      read -r -p "enter network range as address/mask (e.g. 192.168.1.0/24 or 172.31.0.0/16): " firewall_allowed
      if ! validate_cidr "${firewall_allowed}"; then
        warn "invalid format, try again"
        firewall_allowed=""
      fi
    done
  fi
  
  # Step 4: Database passwords (option 0 = keep current when reconfigure)
  echo ""
  section "step 4" "database password configuration"
  echo ""
  if [[ "${reconfigure_mode}" -eq 1 ]]; then
    echo "  0) keep current setting"
  fi
  echo "  1) auto-generate secure passwords (recommended)"
  echo "  2) set passwords manually"
  echo ""
  
  local pass_choice=""
  while [[ -z "${pass_choice}" ]]; do
    if [[ "${reconfigure_mode}" -eq 1 ]]; then
      read -r -p "select [0-2]: " step4_c
    else
      read -r -p "select [1-2]: " step4_c
    fi
    case "${step4_c}" in
      0)
        if [[ "${reconfigure_mode}" -eq 1 ]]; then
          pass_choice="keep"
        fi
        ;;
      1) pass_choice="auto" ;;
      2) pass_choice="manual" ;;
      *) warn "please select $([[ "${reconfigure_mode}" -eq 1 ]] && echo "0, " )1 or 2" ;;
    esac
  done
  
  local pg_password="" app_password="" admin_password=""
  
  if [[ "${pass_choice}" == "manual" ]]; then
    echo ""
    local pg_password_confirm=""
    while [[ -z "${pg_password}" ]]; do
      read -r -s -p "enter postgres superuser password (min ${MIN_PASSWORD_LENGTH} chars): " pg_password
      echo ""
      if ! validate_password "${pg_password}"; then
        warn "password must be at least ${MIN_PASSWORD_LENGTH} characters"
        pg_password=""
        continue
      fi
      pg_password_confirm=""
      read -r -s -p "confirm postgres superuser password: " pg_password_confirm
      echo ""
      if [[ "${pg_password}" != "${pg_password_confirm}" ]]; then
        warn "passwords do not match, try again"
        pg_password=""
      fi
    done
    
    local app_password_confirm=""
    while [[ -z "${app_password}" ]]; do
      read -r -s -p "enter app service password (min ${MIN_PASSWORD_LENGTH} chars): " app_password
      echo ""
      if ! validate_password "${app_password}"; then
        warn "password must be at least ${MIN_PASSWORD_LENGTH} characters"
        app_password=""
        continue
      fi
      app_password_confirm=""
      read -r -s -p "confirm app service password: " app_password_confirm
      echo ""
      if [[ "${app_password}" != "${app_password_confirm}" ]]; then
        warn "passwords do not match, try again"
        app_password=""
      fi
    done
    
    local admin_password_confirm=""
    while [[ -z "${admin_password}" ]]; do
      read -r -s -p "enter admin user password (min ${MIN_PASSWORD_LENGTH} chars): " admin_password
      echo ""
      if ! validate_password "${admin_password}"; then
        warn "password must be at least ${MIN_PASSWORD_LENGTH} characters"
        admin_password=""
        continue
      fi
      admin_password_confirm=""
      read -r -s -p "confirm admin user password: " admin_password_confirm
      echo ""
      if [[ "${admin_password}" != "${admin_password_confirm}" ]]; then
        warn "passwords do not match, try again"
        admin_password=""
      fi
    done
  else
    pg_password=$(generate_password)
    app_password=$(generate_password)
    admin_password=$(generate_password)
    info "passwords will be auto-generated."
  fi
  
  # Step 5: Demo data (only during initial setup; skipped in reconfigure — demo data can be deployed only during initial setup)
  local demo_data_choice=""
  local seed_demo_data="false"
  if [[ "${reconfigure_mode}" -ne 1 ]]; then
    section "step 5" "deploy demo data?"
    echo ""
    echo "  1) yes, deploy demo data"
    echo "  2) no demo data, just clean install"
    echo ""
    while [[ -z "${demo_data_choice}" ]]; do
      read -r -p "select [1-2]: " step5_c
      case "${step5_c}" in
        1) demo_data_choice="yes" ;;
        2) demo_data_choice="no" ;;
        *) warn "please select 1 or 2" ;;
      esac
    done
    if [[ "${demo_data_choice}" == "yes" ]]; then
      seed_demo_data="true"
    fi
  else
    seed_demo_data="${current_seed_demo_data:-false}"
    demo_data_choice="unchanged"
    info "demo data can be deployed only during initial setup; current setting unchanged."
  fi
  
  # Step 6: EVI version — download kit archive from GitHub Release file for the selected version.
  # Both options (latest / choose) use the same archive-based mechanism. When the selected version matches
  # the current kit version, no download is needed — bundled files are used as-is.
  local version_choice="" chosen_release_version="" release_template_file=""
  if [[ "${reconfigure_mode}" -eq 1 ]]; then
    version_choice="keep"
  else
    echo ""
    section "step 6" "which release version do you want to deploy?"
    echo ""
    echo "  1) latest"
    echo "  2) choose release version"
    echo ""
    while [[ -z "${version_choice}" ]]; do
      read -r -p "select [1-2]: " step6_c
      case "${step6_c}" in
        1) version_choice="latest" ;;
        2) version_choice="manual" ;;
        *) warn "please select 1 or 2" ;;
      esac
    done
  fi

  if [[ "${version_choice}" == "latest" ]]; then
    ensure_executable
    local tags_raw="" selected_tag=""
    fetch_github_release_tags tags_raw
    local fr=$?
    if [[ "${fr}" -ne 0 ]]; then
      if [[ "${fr}" -eq 1 ]]; then
        local _app_gh_hint=""
        if [[ -z "${APP_GITHUB_TOKEN:-}" ]] && [[ "${APP_GH_FETCH_HTTP_CODE}" == "401" || "${APP_GH_FETCH_HTTP_CODE}" == "403" || "${APP_GH_FETCH_HTTP_CODE}" == "404" ]]; then
          _app_gh_hint=" (the repository may be private — set APP_GITHUB_TOKEN and retry)"
        fi
        warn "could not fetch releases from GitHub (HTTP ${APP_GH_FETCH_HTTP_CODE:-error})${_app_gh_hint}; using bundled kit version."
      else
        warn "no releases found on GitHub; using bundled kit version."
      fi
    else
      selected_tag="$(pick_first_stable_release_tag "${tags_raw}")" || selected_tag=""
      if [[ -z "${selected_tag}" ]]; then
        warn "no stable release (x.y.z) in the GitHub list; using bundled kit version."
      else
        chosen_release_version="${selected_tag#v}"
        local current_kit_ver=""
        current_kit_ver=$(get_current_kit_version) || current_kit_ver=""
        if [[ "${chosen_release_version}" == "${current_kit_ver}" ]]; then
          info "bundled kit version ${current_kit_ver} is already the latest stable."
        else
          log "latest stable release: ${chosen_release_version} (current kit: ${current_kit_ver:-unknown})"
          if ! download_release_kit_archive "${selected_tag}" "${chosen_release_version}"; then
            warn "could not download kit archive for ${chosen_release_version}. Using bundled kit version."
            chosen_release_version="${current_kit_ver}"
          fi
        fi
        release_template_file="${TEMPLATE_ENV}"
      fi
    fi
  elif [[ "${version_choice}" == "manual" ]]; then
    ensure_executable
    local tags_raw=""
    fetch_github_release_tags tags_raw
    local fr=$?
    if [[ "${fr}" -ne 0 ]]; then
      if [[ "${fr}" -eq 1 ]]; then
        local _app_gh_hint=""
        if [[ -z "${APP_GITHUB_TOKEN:-}" ]] && [[ "${APP_GH_FETCH_HTTP_CODE}" == "401" || "${APP_GH_FETCH_HTTP_CODE}" == "403" || "${APP_GH_FETCH_HTTP_CODE}" == "404" ]]; then
          _app_gh_hint=" (the repository may be private — set APP_GITHUB_TOKEN and retry)"
        fi
        err "could not fetch releases from GitHub (HTTP ${APP_GH_FETCH_HTTP_CODE:-error})${_app_gh_hint}. Try again later."
      else
        err "no releases found. Try again later."
      fi
      return 1
    fi
    echo ""
    printf "  available releases:\n"
    local idx=1
    while IFS= read -r tag; do
      [[ -z "${tag}" ]] && continue
      local ver_display="${tag#v}"
      printf "    %d) %s\n" "${idx}" "${ver_display}"
      idx=$((idx + 1))
    done <<< "${tags_raw}"
    local release_count=$((idx - 1))
    local step6_num=""
    while [[ -z "${step6_num}" ]]; do
      read -r -p "  enter release number (1 = latest, or press enter for latest): " step6_num
      step6_num=$(echo "${step6_num}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [[ -z "${step6_num}" ]]; then
        step6_num=1
      fi
      if [[ "${step6_num}" =~ ^[0-9]+$ ]] && [[ "${step6_num}" -ge 1 ]] && [[ "${step6_num}" -le "${release_count}" ]]; then
        break
      fi
      warn "enter a number between 1 and ${release_count}"
      step6_num=""
    done
    idx=1
    local selected_tag=""
    while IFS= read -r tag; do
      [[ -z "${tag}" ]] && continue
      if [[ "${idx}" -eq "${step6_num}" ]]; then
        selected_tag="${tag}"
        break
      fi
      idx=$((idx + 1))
    done <<< "${tags_raw}"
    chosen_release_version="${selected_tag#v}"
    local current_kit_ver=""
    current_kit_ver=$(get_current_kit_version) || current_kit_ver=""
    if [[ "${chosen_release_version}" == "${current_kit_ver}" ]]; then
      info "selected version ${chosen_release_version} matches bundled kit — no download needed."
    else
      log "selected release: ${chosen_release_version} (current kit: ${current_kit_ver:-unknown})"
      if ! download_release_kit_archive "${selected_tag}" "${chosen_release_version}"; then
        warn "could not download kit archive for ${chosen_release_version}. Images will not be updated."
        chosen_release_version=""
      fi
    fi
    release_template_file="${TEMPLATE_ENV}"
  fi
  
  # Summary
  echo ""
  log "=== configuration summary ==="
  echo ""
  printf "  domain/ip:     %s\n" "${domain}"
  printf "  tls mode:      %s\n" "${tls_mode}"
  if [[ "${tls_mode}" == "manual" ]]; then
    if [[ "${generate_certs}" == "yes" ]]; then
      printf "  certificates:  auto-generate\n"
    else
      printf "  certificates:  use my own\n"
    fi
  elif [[ "${tls_mode}" == "letsencrypt" ]]; then
    printf "  certificates:  let's encrypt (automatic)\n"
  fi
  printf "  db passwords:  %s\n" "${pass_choice}"
  printf "  demo data:     %s\n" "${demo_data_choice}"
  local firewall_summary="${firewall_access}"
  [[ -n "${firewall_allowed}" ]] && firewall_summary="${firewall_access} (${firewall_allowed})"
  printf "  cockpit access: %s\n" "${firewall_summary}"
  if [[ "${version_choice}" == "latest" || "${version_choice}" == "manual" ]]; then
    local tpl_src="${TEMPLATE_ENV}"
    [[ -n "${release_template_file}" ]] && [[ -f "${release_template_file}" ]] && tpl_src="${release_template_file}"
    local latest_fe latest_be latest_db
    latest_fe=$(grep "^APP_FE_IMAGE=" "${tpl_src}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    latest_be=$(grep "^APP_BE_IMAGE=" "${tpl_src}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    latest_db=$(grep "^APP_DB_IMAGE=" "${tpl_src}" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    if [[ -n "${chosen_release_version}" ]] && [[ -n "${latest_fe}" ]]; then
      printf "  release version:   %s — %s, %s, %s\n" "${chosen_release_version}" "${latest_fe}" "${latest_be}" "${latest_db}"
    elif [[ -n "${latest_fe}" ]]; then
      printf "  release version:   %s, %s, %s\n" "${latest_fe}" "${latest_be}" "${latest_db}"
    else
      printf "  release version:   (from template)\n"
    fi
  elif [[ "${version_choice}" == "keep" ]]; then
    printf "  release version:   keep current\n"
  fi
  echo ""
  
  if ! confirm "save and apply this configuration?"; then
    warn "configuration cancelled."
    return
  fi
  
  # Apply configuration
  log "saving configuration..."
  
  # Update app.env
  sed -i "s|^APP_DOMAIN=.*|APP_DOMAIN=${domain}|" "${TARGET_ENV}"
  sed -i "s|^APP_TLS_MODE=.*|APP_TLS_MODE=${tls_mode}|" "${TARGET_ENV}"
  
  # Handle ACME email based on TLS mode
  if [[ "${tls_mode}" == "letsencrypt" ]]; then
    sed -i "s|^APP_ACME_EMAIL=.*|APP_ACME_EMAIL=${acme_email}|" "${TARGET_ENV}"
  else
    # Clear ACME email for manual mode
    sed -i "s|^APP_ACME_EMAIL=.*|APP_ACME_EMAIL=|" "${TARGET_ENV}"
  fi
  
  # Update app.secrets.env (skip when user chose keep current passwords)
  if [[ "${pass_choice}" != "keep" ]]; then
    sed -i "s|^APP_POSTGRES_PASSWORD=.*|APP_POSTGRES_PASSWORD=${pg_password}|" "${TARGET_SECRETS}"
    sed -i "s|^APP_DB_PASSWORD=.*|APP_DB_PASSWORD=${app_password}|" "${TARGET_SECRETS}"
    sed -i "s|^APP_ADMIN_DB_PASSWORD=.*|APP_ADMIN_DB_PASSWORD=${admin_password}|" "${TARGET_SECRETS}"
  fi
  
  # Update APP_SEED_DEMO_DATA (only on initial setup; reconfigure leaves it unchanged)
  if [[ "${reconfigure_mode}" -ne 1 ]]; then
    if grep -q "^APP_SEED_DEMO_DATA=" "${TARGET_ENV}"; then
      sed -i "s|^APP_SEED_DEMO_DATA=.*|APP_SEED_DEMO_DATA=${seed_demo_data}|" "${TARGET_ENV}"
    else
      echo "APP_SEED_DEMO_DATA=${seed_demo_data}" >> "${TARGET_ENV}"
    fi
  fi

  # Update APP_FIREWALL_ADMIN_ACCESS and APP_FIREWALL_ADMIN_ALLOWED
  if grep -q "^APP_FIREWALL_ADMIN_ACCESS=" "${TARGET_ENV}"; then
    sed -i "s|^APP_FIREWALL_ADMIN_ACCESS=.*|APP_FIREWALL_ADMIN_ACCESS=${firewall_access}|" "${TARGET_ENV}"
  else
    echo "APP_FIREWALL_ADMIN_ACCESS=${firewall_access}" >> "${TARGET_ENV}"
  fi
  if grep -q "^APP_FIREWALL_ADMIN_ALLOWED=" "${TARGET_ENV}"; then
    sed -i "s|^APP_FIREWALL_ADMIN_ALLOWED=.*|APP_FIREWALL_ADMIN_ALLOWED=${firewall_allowed}|" "${TARGET_ENV}"
  else
    echo "APP_FIREWALL_ADMIN_ALLOWED=${firewall_allowed}" >> "${TARGET_ENV}"
  fi
  
  # Update APP_*_IMAGE from the kit's app.template.env (archive-based: template already matches the selected version)
  if [[ "${version_choice}" == "manual" || "${version_choice}" == "latest" ]] && [[ -n "${release_template_file}" ]] && [[ -f "${release_template_file}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      [[ "${line}" =~ ^APP_.*_IMAGE= ]] || continue
      local img_key img_val
      img_key="${line%%=*}"
      img_val="${line#*=}"
      img_val=$(echo "${img_val}" | tr -d '"' | tr -d "'")
      if grep -q "^${img_key}=" "${TARGET_ENV}" 2>/dev/null; then
        sed -i "s|^${img_key}=.*|${img_key}=${img_val}|" "${TARGET_ENV}"
      else
        echo "${img_key}=${img_val}" >> "${TARGET_ENV}"
      fi
    done < "${release_template_file}"
  fi

  # Keep APP_INSTALL_REPO aligned with the kit template on every save.
  local _guided_install_repo="${APP_INSTALL_REPO:-vk74/ready-room}"
  if [[ -f "${TEMPLATE_ENV}" ]]; then
    local _guided_tpl_repo=""
    _guided_tpl_repo=$(grep "^APP_INSTALL_REPO=" "${TEMPLATE_ENV}" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    _guided_tpl_repo="${_guided_tpl_repo%$'\r'}"
    if [[ -n "${_guided_tpl_repo}" ]]; then
      _guided_install_repo="${_guided_tpl_repo}"
    fi
  fi
  if grep -q "^APP_INSTALL_REPO=" "${TARGET_ENV}" 2>/dev/null; then
    sed -i "s|^APP_INSTALL_REPO=.*|APP_INSTALL_REPO=${_guided_install_repo}|" "${TARGET_ENV}"
  else
    echo "APP_INSTALL_REPO=${_guided_install_repo}" >> "${TARGET_ENV}"
  fi
  export APP_INSTALL_REPO="${_guided_install_repo}"

  info "configuration saved to app.env and app.secrets.env"

  # Apply UFW rules: delete existing 9090/5445 rules then add from app.env (same workflow for first run and reconfigure)
  apply_firewall_admin_tools

  # Generate certificates if needed
  if [[ "${tls_mode}" == "manual" ]] && [[ "${generate_certs}" == "yes" ]]; then
    log "generating tls certificates..."
    ensure_executable
    mkdir -p "${TLS_DIR}"
    if "${SCRIPTS_DIR}/tls/gen-self-signed-tls.sh" "${domain}" "${TLS_DIR}" --force; then
      info "tls certificates generated successfully."
    else
      err "certificate generation failed!"
    fi
  fi
  
  echo ""
  info "guided setup complete!"
  if [[ "${reconfigure_mode}" -eq 1 ]]; then
    info "configuration updated. run option 3 to apply changes and restart containers."
  else
    info "you can now proceed to 'deploy' to pull containers and start the application."
  fi
  read -r -p "press enter to continue..."
}

# --- 2-Step Fresh Install: collect_config + deploy_full ---

collect_config() {
  title_box "guided environment configuration"
  echo ""
  echo "this wizard will collect your application configuration. after completing all steps,"
  echo "use the 'deploy' option to install prerequisites and start the application."
  echo ""

  # Step 1: Access type
  section "step 1" "how will users connect to your application?"
  echo ""
  echo "  1) private ip or intranet dns name"
  echo "  2) public dns domain"
  echo "  3) public ip address"
  echo ""

  local access_type="" domain="" tls_mode="" acme_email="" cert_choice="" generate_certs="yes"

  while [[ -z "${access_type}" ]]; do
    read -r -p "select [1-3]: " step1_choice
    case "${step1_choice}" in
      1) access_type="internal" ;;
      2) access_type="public_domain" ;;
      3) access_type="public_ip" ;;
      *) warn "please select 1, 2, or 3" ;;
    esac
  done

  if [[ "${access_type}" == "public_domain" ]]; then
    while [[ -z "${domain}" ]]; do
      read -r -p "enter your public domain name (e.g., app.example.com): " domain
      if ! validate_domain "${domain}"; then
        warn "invalid domain format"
        domain=""
      fi
    done
  elif [[ "${access_type}" == "public_ip" ]]; then
    while [[ -z "${domain}" ]]; do
      read -r -p "enter your public ip address: " domain
      if ! validate_ip "${domain}"; then
        warn "invalid ip address format"
        domain=""
      fi
    done
  else
    while [[ -z "${domain}" ]]; do
      read -r -p "enter ip address or domain name: " domain
      if ! validate_ip "${domain}" && ! validate_domain "${domain}"; then
        warn "invalid ip or domain format"
        domain=""
      fi
    done
  fi

  # Step 2: TLS certificate
  echo ""
  section "step 2" "tls certificate configuration"
  echo ""

  if [[ "${access_type}" == "public_domain" ]]; then
    echo "  1) let's encrypt (automatic)"
    echo "  2) use my own certificates"
    echo ""
    while [[ -z "${cert_choice}" ]]; do
      read -r -p "select [1-2]: " step2_tls
      case "${step2_tls}" in
        1) tls_mode="letsencrypt"; cert_choice="letsencrypt" ;;
        2) tls_mode="manual"; cert_choice="own"; generate_certs="no" ;;
        *) warn "please select 1 or 2" ;;
      esac
    done
    if [[ "${tls_mode}" == "letsencrypt" ]]; then
      while [[ -z "${acme_email}" ]]; do
        read -r -p "enter email for let's encrypt account operations: " acme_email
        if [[ ! "${acme_email}" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
          warn "invalid email format"
          acme_email=""
        fi
      done
    fi
  else
    tls_mode="manual"
    echo "  1) auto-generate self-signed certificate (recommended)"
    echo "  2) use my own certificates"
    echo ""
    while [[ -z "${cert_choice}" ]]; do
      read -r -p "select [1-2]: " step2_tls
      case "${step2_tls}" in
        1) generate_certs="yes"; cert_choice="auto" ;;
        2) generate_certs="no"; cert_choice="own" ;;
        *) warn "please select 1 or 2" ;;
      esac
    done
  fi

  # Step 3: Firewall — cockpit access
  echo ""
  section "step 3" "from which ip addresses or subnets may admins connect to cockpit?"
  echo ""
  echo "cockpit is the web interface for administration of host server and containers."
  echo "choose from where it can be opened in a browser."
  echo ""
  echo "  1) from specific computer(s) by address"
  echo "     (enter one or more IP addresses, e.g. 192.168.1.10 or 192.168.1.10, 192.168.1.11)"
  echo ""
  echo "  2) from all computers in a local network range"
  echo "     (enter range in the form address/mask, e.g. 192.168.1.0/24 or 172.31.0.0/16)"
  echo ""
  echo "  3) only from this server"
  echo "     (requires a graphical session on the server — not typical for headless servers)"
  echo ""
  echo "  4) from any computer (not recommended)"
  echo "     (anyone who knows the address can try to open cockpit; use only for testing)"
  echo ""
  echo "  5) do not change firewall now"
  echo "     (you will configure access yourself later)"
  echo ""

  local firewall_access="" firewall_allowed=""
  while [[ -z "${firewall_access}" ]]; do
    read -r -p "select [1-5]: " step3_c
    case "${step3_c}" in
      1) firewall_access="allowed_ips" ;;
      2) firewall_access="allowed_cidr" ;;
      3) firewall_access="localhost" ;;
      4) firewall_access="any" ;;
      5) firewall_access="skip" ;;
      *) warn "please select 1, 2, 3, 4, or 5" ;;
    esac
  done

  if [[ "${firewall_access}" == "allowed_ips" ]]; then
    while true; do
      read -r -p "enter IP address(es), separated by commas (e.g. 192.168.1.10, 192.168.1.11): " firewall_allowed
      firewall_allowed=$(echo "${firewall_allowed}" | tr -d ' ')
      [[ -z "${firewall_allowed}" ]] && warn "invalid format, try again" && continue
      local ok=1
      while IFS=',' read -r ip; do
        ip=$(echo "${ip}" | tr -d ' ')
        [[ -z "${ip}" ]] && continue
        if ! validate_ip "${ip}"; then
          ok=0
          break
        fi
      done <<< "${firewall_allowed}"
      [[ "${ok}" -eq 1 ]] && break
      warn "invalid format, try again"
    done
  elif [[ "${firewall_access}" == "allowed_cidr" ]]; then
    while [[ -z "${firewall_allowed}" ]]; do
      read -r -p "enter network range as address/mask (e.g. 192.168.1.0/24 or 172.31.0.0/16): " firewall_allowed
      if ! validate_cidr "${firewall_allowed}"; then
        warn "invalid format, try again"
        firewall_allowed=""
      fi
    done
  fi

  # Step 4: Database passwords
  echo ""
  section "step 4" "database password configuration"
  echo ""
  echo "  1) auto-generate secure passwords (recommended)"
  echo "  2) set passwords manually"
  echo ""

  local pass_choice="" pg_password="" app_password="" admin_password=""
  while [[ -z "${pass_choice}" ]]; do
    read -r -p "select [1-2]: " step4_c
    case "${step4_c}" in
      1) pass_choice="auto" ;;
      2) pass_choice="manual" ;;
      *) warn "please select 1 or 2" ;;
    esac
  done

  if [[ "${pass_choice}" == "manual" ]]; then
    echo ""
    local pg_password_confirm=""
    while [[ -z "${pg_password}" ]]; do
      read -r -s -p "enter postgres superuser password (min ${MIN_PASSWORD_LENGTH} chars): " pg_password
      echo ""
      if ! validate_password "${pg_password}"; then
        warn "password must be at least ${MIN_PASSWORD_LENGTH} characters"
        pg_password=""
        continue
      fi
      pg_password_confirm=""
      read -r -s -p "confirm postgres superuser password: " pg_password_confirm
      echo ""
      if [[ "${pg_password}" != "${pg_password_confirm}" ]]; then
        warn "passwords do not match, try again"
        pg_password=""
      fi
    done
    local app_password_confirm=""
    while [[ -z "${app_password}" ]]; do
      read -r -s -p "enter app service password (min ${MIN_PASSWORD_LENGTH} chars): " app_password
      echo ""
      if ! validate_password "${app_password}"; then
        warn "password must be at least ${MIN_PASSWORD_LENGTH} characters"
        app_password=""
        continue
      fi
      app_password_confirm=""
      read -r -s -p "confirm app service password: " app_password_confirm
      echo ""
      if [[ "${app_password}" != "${app_password_confirm}" ]]; then
        warn "passwords do not match, try again"
        app_password=""
      fi
    done
    local admin_password_confirm=""
    while [[ -z "${admin_password}" ]]; do
      read -r -s -p "enter admin user password (min ${MIN_PASSWORD_LENGTH} chars): " admin_password
      echo ""
      if ! validate_password "${admin_password}"; then
        warn "password must be at least ${MIN_PASSWORD_LENGTH} characters"
        admin_password=""
        continue
      fi
      admin_password_confirm=""
      read -r -s -p "confirm admin user password: " admin_password_confirm
      echo ""
      if [[ "${admin_password}" != "${admin_password_confirm}" ]]; then
        warn "passwords do not match, try again"
        admin_password=""
      fi
    done
  else
    pg_password=$(generate_password)
    app_password=$(generate_password)
    admin_password=$(generate_password)
    info "passwords will be auto-generated."
  fi

  # Step 5: Demo data
  section "step 5" "deploy demo data?"
  echo ""
  echo "  1) yes, deploy demo data"
  echo "  2) no demo data, just clean install"
  echo ""

  local seed_demo_data="false"
  while true; do
    read -r -p "select [1-2]: " step5_c
    case "${step5_c}" in
      1) seed_demo_data="true"; break ;;
      2) seed_demo_data="false"; break ;;
      *) warn "please select 1 or 2" ;;
    esac
  done

  # Step 6: Data storage (DB volume)
  local data_path=""
  prompt_data_storage_path "step 6" "database volume storage" "database"
  data_path="${SELECTED_DATA_PATH}"

  # Step 7: Data storage (FS volume)
  local fs_data_path=""
  prompt_data_storage_path "step 7" "file storage (FS) volume storage" "file storage"
  fs_data_path="${SELECTED_DATA_PATH}"

  local fs_volume_max_gb=""
  prompt_fs_volume_capacity "${fs_data_path}" "${data_path}"
  fs_volume_max_gb="${FS_VOLUME_MAX_GB}"

  # Step 8: EVI version
  section "step 8" "which release version do you want to deploy?"
  echo ""
  echo "  1) latest stable"
  echo "  2) choose release version"
  echo ""

  local version_choice="" chosen_release_version="" chosen_version_tag=""
  while [[ -z "${version_choice}" ]]; do
    read -r -p "select [1-2]: " step8_c
    case "${step8_c}" in
      1) version_choice="latest" ;;
      2) version_choice="manual" ;;
      *) warn "please select 1 or 2" ;;
    esac
  done

  if [[ "${version_choice}" == "latest" ]]; then
    local tags_raw="" selected_tag=""
    if fetch_github_release_tags tags_raw; then
      selected_tag="$(pick_first_stable_release_tag "${tags_raw}")" || selected_tag=""
    fi
    if [[ -n "${selected_tag}" ]]; then
      chosen_release_version="${selected_tag#v}"
      chosen_version_tag="${selected_tag}"
      info "latest stable release: ${chosen_release_version}"
    else
      warn "could not determine latest stable release from GitHub."
      warn "please try option 2 (choose release version) or check your internet connection."
      return 1
    fi
  elif [[ "${version_choice}" == "manual" ]]; then
    local tags_raw=""
    if ! fetch_github_release_tags tags_raw; then
      err "could not fetch releases from GitHub. check your internet connection."
      return 1
    fi
    echo ""
    printf "  available releases:\n"
    local idx=1
    while IFS= read -r tag; do
      [[ -z "${tag}" ]] && continue
      local ver_display="${tag#v}"
      printf "    %d) %s\n" "${idx}" "${ver_display}"
      idx=$((idx + 1))
    done <<< "${tags_raw}"
    local release_count=$((idx - 1))
    local step8_num=""
    while [[ -z "${step8_num}" ]]; do
      read -r -p "  enter release number (1 = latest, or press enter for latest): " step8_num
      step8_num=$(echo "${step8_num}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "${step8_num}" ]] && step8_num=1
      if [[ "${step8_num}" =~ ^[0-9]+$ ]] && [[ "${step8_num}" -ge 1 ]] && [[ "${step8_num}" -le "${release_count}" ]]; then
        break
      fi
      warn "enter a number between 1 and ${release_count}"
      step8_num=""
    done
    idx=1
    while IFS= read -r tag; do
      [[ -z "${tag}" ]] && continue
      if [[ "${idx}" -eq "${step8_num}" ]]; then
        chosen_version_tag="${tag}"
        chosen_release_version="${tag#v}"
        break
      fi
      idx=$((idx + 1))
    done <<< "${tags_raw}"
    info "selected version: ${chosen_release_version}"
  fi

  # Summary
  echo ""
  log "=== configuration summary ==="
  echo ""
  printf "  domain/ip:      %s\n" "${domain}"
  printf "  tls mode:       %s\n" "${tls_mode}"
  if [[ "${tls_mode}" == "manual" ]]; then
    if [[ "${generate_certs}" == "yes" ]]; then
      printf "  certificates:   auto-generate self-signed\n"
    else
      printf "  certificates:   use my own\n"
    fi
  elif [[ "${tls_mode}" == "letsencrypt" ]]; then
    printf "  certificates:   let's encrypt (automatic)\n"
  fi
  printf "  db passwords:   %s\n" "${pass_choice}"
  printf "  demo data:      %s\n" "${seed_demo_data}"
  if [[ -n "${data_path}" ]]; then
    printf "  db volume:      %s (separate disk)\n" "${data_path}"
  else
    printf "  db volume:      system disk (default)\n"
  fi
  if [[ -n "${fs_data_path}" ]]; then
    printf "  fs volume:      %s (separate disk)\n" "${fs_data_path}"
  elif [[ -n "${data_path}" ]]; then
    printf "  fs volume:      %s (same as db volume)\n" "${data_path}"
  else
    printf "  fs volume:      system disk (default)\n"
  fi
  printf "  fs capacity:    %s GB max (SeaweedFS limit)\n" "${fs_volume_max_gb}"
  local firewall_summary="${firewall_access}"
  [[ -n "${firewall_allowed}" ]] && firewall_summary="${firewall_access} (${firewall_allowed})"
  printf "  cockpit access: %s\n" "${firewall_summary}"
  printf "  release version:    %s\n" "${chosen_release_version}"
  echo ""

  if ! confirm "save this configuration?"; then
    warn "configuration cancelled."
    return 1
  fi

  # Save to install config (restricted permissions — contains passwords)
  # Uses printf %q for safe shell escaping of values that may contain special characters
  {
    printf 'INSTALL_DOMAIN=%q\n' "${domain}"
    printf 'INSTALL_ACCESS_TYPE=%q\n' "${access_type}"
    printf 'INSTALL_TLS_MODE=%q\n' "${tls_mode}"
    printf 'INSTALL_ACME_EMAIL=%q\n' "${acme_email}"
    printf 'INSTALL_CERT_CHOICE=%q\n' "${cert_choice}"
    printf 'INSTALL_GENERATE_CERTS=%q\n' "${generate_certs}"
    printf 'INSTALL_FIREWALL_ACCESS=%q\n' "${firewall_access}"
    printf 'INSTALL_FIREWALL_ALLOWED=%q\n' "${firewall_allowed}"
    printf 'INSTALL_PASS_CHOICE=%q\n' "${pass_choice}"
    printf 'INSTALL_PG_PASSWORD=%q\n' "${pg_password}"
    printf 'INSTALL_APP_PASSWORD=%q\n' "${app_password}"
    printf 'INSTALL_ADMIN_PASSWORD=%q\n' "${admin_password}"
    printf 'INSTALL_SEED_DEMO_DATA=%q\n' "${seed_demo_data}"
    printf 'INSTALL_DATA_PATH=%q\n' "${data_path}"
    printf 'INSTALL_FS_DATA_PATH=%q\n' "${fs_data_path}"
    printf 'INSTALL_FS_VOLUME_MAX_GB=%q\n' "${fs_volume_max_gb}"
    printf 'INSTALL_VERSION=%q\n' "${chosen_release_version}"
    printf 'INSTALL_VERSION_TAG=%q\n' "${chosen_version_tag}"
  } > "${INSTALL_CONFIG}"
  chmod 600 "${INSTALL_CONFIG}"
  INSTALL_CONFIG_EXISTS=1

  echo ""
  info "configuration saved."
  info "proceed to option 2 (deploy) to install the application ${chosen_release_version}."
  read -r -p "press enter to continue..."
}

deploy_full() {
  # Save running installer version before local INSTALL_VERSION (product) shadows the global (script version).
  local _running_installer_ver="${INSTALL_VERSION}"

  if [[ ! -f "${INSTALL_CONFIG}" ]]; then
    err "no saved configuration found. please run 'configure' first (option 1)."
    return 1
  fi

  # Read saved configuration
  local INSTALL_DOMAIN="" INSTALL_ACCESS_TYPE="" INSTALL_TLS_MODE="" INSTALL_ACME_EMAIL=""
  local INSTALL_CERT_CHOICE="" INSTALL_GENERATE_CERTS="" INSTALL_FIREWALL_ACCESS="" INSTALL_FIREWALL_ALLOWED=""
  local INSTALL_PASS_CHOICE="" INSTALL_PG_PASSWORD="" INSTALL_APP_PASSWORD="" INSTALL_ADMIN_PASSWORD=""
  local INSTALL_SEED_DEMO_DATA="" INSTALL_DATA_PATH="" INSTALL_FS_DATA_PATH="" INSTALL_FS_VOLUME_MAX_GB=""
  local INSTALL_VERSION="" INSTALL_VERSION_TAG=""
  source "${INSTALL_CONFIG}"
  INSTALL_FS_VOLUME_MAX_GB="${INSTALL_FS_VOLUME_MAX_GB:-100}"

  title_box "deploying application ${INSTALL_VERSION}"
  echo ""
  echo "this will:"
  echo "  1. download the application ${INSTALL_VERSION} kit from GitHub"
  echo "  2. install system prerequisites (requires sudo)"
  echo "  3. install cockpit panels"
  echo "  4. apply your configuration"
  echo "  5. pull and start all containers"
  echo ""

  if [[ "${_APP_CONTINUE_DEPLOY:-0}" -ne 1 ]]; then
    if ! confirm "proceed with deployment?"; then
      return 0
    fi
  fi

  # --- Phase 1: Download kit archive ---
  phase "1/5" "downloading the application kit ${INSTALL_VERSION}"
  mkdir -p "${CONFIG_DIR}"

  local current_kit_ver=""
  current_kit_ver=$(get_current_kit_version) || current_kit_ver=""
  if [[ "${INSTALL_VERSION}" == "${current_kit_ver}" ]]; then
    info "kit version ${current_kit_ver} already matches — skipping download."
    ensure_config_files
  else
    if ! download_release_kit_archive "${INSTALL_VERSION_TAG}" "${INSTALL_VERSION}"; then
      err "failed to download kit archive for ${INSTALL_VERSION}."
      err "check your internet connection and try again."
      return 1
    fi
    # --- Re-exec if on-disk install.sh version changed after download ---
    # download_release_kit_archive() replaces install.sh on disk with the version from the kit archive.
    # If the on-disk version now differs from the running script, exec the version-matched installer
    # so all remaining deployment phases run with the correct version's code.
    local _disk_installer_ver=""
    _disk_installer_ver=$(sed -n '1,20p' "${SCRIPT_DIR}/install.sh" 2>/dev/null \
      | grep -m1 '^# Version: ' | sed 's/^# Version:[[:space:]]*//' || echo "")
    if [[ -n "${_disk_installer_ver}" ]] && [[ "${_disk_installer_ver}" != "${_running_installer_ver}" ]]; then
      if grep -q '__continue_deploy' "${SCRIPT_DIR}/install.sh" 2>/dev/null; then
        info "re-launching version-matched installer (${INSTALL_VERSION})..."
        exec "${SCRIPT_DIR}/install.sh" __continue_deploy
      else
        warn "selected version (${INSTALL_VERSION}) uses an older installer format."
        warn "re-launching version-matched installer. complete setup from its menu."
        rm -f "${TARGET_ENV}" "${TARGET_SECRETS}" 2>/dev/null || true
        exec "${SCRIPT_DIR}/install.sh"
      fi
    fi
  fi

  # Source prerequisites manifest from the downloaded kit (required; no silent fallback)
  local prereq_conf="${SCRIPT_DIR}/prerequisites.conf"
  if [[ ! -f "${prereq_conf}" ]]; then
    err "prerequisites.conf missing: ${prereq_conf}"
    err "restore the file from your application kit archive or re-run deploy after a full kit download."
    return 1
  fi
  # shellcheck source=/dev/null
  source "${prereq_conf}"
  APP_PREREQ_APT_PACKAGES="${APP_PREREQ_APT_PACKAGES:-}"
  APP_PREREQ_COCKPIT_PACKAGES="${APP_PREREQ_COCKPIT_PACKAGES:-}"
  APP_PREREQ_COCKPIT_FILES_PACKAGE="${APP_PREREQ_COCKPIT_FILES_PACKAGE:-}"
  APP_PREREQ_COCKPIT_FILES_RELEASE="${APP_PREREQ_COCKPIT_FILES_RELEASE:-}"
  APP_PREREQ_COCKPIT_FILES_DEB_URL="${APP_PREREQ_COCKPIT_FILES_DEB_URL:-}"
  APP_PREREQ_UNPRIVILEGED_PORT_START="${APP_PREREQ_UNPRIVILEGED_PORT_START:-}"
  APP_PREREQ_UFW_PORTS="${APP_PREREQ_UFW_PORTS:-}"
  if [[ -z "${APP_PREREQ_APT_PACKAGES// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_APT_PACKAGES is empty (${prereq_conf})"
    return 1
  fi
  if [[ -z "${APP_PREREQ_COCKPIT_PACKAGES// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_COCKPIT_PACKAGES is empty (${prereq_conf})"
    return 1
  fi
  if [[ -z "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" ]] || ! [[ "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" =~ ^[0-9]+$ ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_UNPRIVILEGED_PORT_START must be a non-negative integer (${prereq_conf})"
    return 1
  fi
  if [[ -z "${APP_PREREQ_UFW_PORTS// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_UFW_PORTS is empty (${prereq_conf})"
    return 1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_USE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_USE is empty (${prereq_conf})"
    return 1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_FILE_SIZE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_FILE_SIZE is empty (${prereq_conf})"
    return 1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_RETENTION// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_RETENTION is empty (${prereq_conf})"
    return 1
  fi

  # --- Phase 2: Install system prerequisites ---
  phase "2/5" "installing system prerequisites"

  log "installing packages: ${APP_PREREQ_APT_PACKAGES:-}..."
  app_apt_get update
  app_apt_get install -y ${APP_PREREQ_APT_PACKAGES:-}

  log "configuring rootless ports (unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-})..."
  sudo rm -f /etc/sysctl.d/99-evi-rootless.conf 2>/dev/null || true
  echo "net.ipv4.ip_unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" | sudo tee /etc/sysctl.d/99-app-rootless.conf
  sudo sysctl -p /etc/sysctl.d/99-app-rootless.conf || true

  if ! install_journald_limits; then
    err "failed to configure journald limits"
    return 1
  fi

  if ! loginctl show-user "$(whoami)" -p Linger 2>/dev/null | grep -q "yes"; then
    log "enabling systemd linger for $(whoami)..."
    sudo loginctl enable-linger "$(whoami)"
  fi

  if command -v ufw >/dev/null 2>&1; then
    ensure_executable
    if "${SCRIPTS_DIR}/host/ufw-ensure-active.sh"; then
      log "opening application ports in ufw..."
      local port
      for port in ${APP_PREREQ_UFW_PORTS:-}; do
        sudo ufw allow "${port}"
      done
    else
      warn "ufw could not be enabled; skipping application firewall ports."
    fi
  fi

  if ! install_sshd_jail; then
    err "failed to configure sshd jail (fail2ban)"
    return 1
  fi

  log "installing cockpit: ${APP_PREREQ_COCKPIT_PACKAGES:-}..."
  app_apt_get update
  app_apt_get install -y ${APP_PREREQ_COCKPIT_PACKAGES:-}
  install_cockpit_files_best_effort
  sudo systemctl enable --now cockpit.socket

  systemctl --user enable --now podman.socket
  info "system prerequisites installed."

  if ! pause_deploy_if_reboot_required; then
    return 1
  fi

  # --- Phase 3: Install cockpit panels ---
  phase "3/5" "installing cockpit panels"

  install_cockpit_app_admin_panel \
    "cockpit: app admin tools panel installed." \
    "cockpit-app-admin not found; skipping."

  # Deploy update kit
  if [[ -d "${SCRIPT_DIR}/update-kit" ]] && [[ ! -d "${SCRIPT_DIR}/update/scripts" ]]; then
    mkdir -p "${SCRIPT_DIR}/update"
    cp -a "${SCRIPT_DIR}/update-kit/." "${SCRIPT_DIR}/update/"
    if [[ -d "${SCRIPT_DIR}/update/scripts" ]]; then
      chmod +x "${SCRIPT_DIR}/update/scripts/"*.sh 2>/dev/null || true
    fi
    info "update kit deployed."
  fi

  info "cockpit panels installed."

  # --- Phase 4: Apply configuration ---
  phase "4/5" "applying configuration"

  ensure_config_files

  # Domain and TLS
  sed -i "s|^APP_DOMAIN=.*|APP_DOMAIN=${INSTALL_DOMAIN}|" "${TARGET_ENV}"
  sed -i "s|^APP_TLS_MODE=.*|APP_TLS_MODE=${INSTALL_TLS_MODE}|" "${TARGET_ENV}"
  if [[ "${INSTALL_TLS_MODE}" == "letsencrypt" ]]; then
    sed -i "s|^APP_ACME_EMAIL=.*|APP_ACME_EMAIL=${INSTALL_ACME_EMAIL}|" "${TARGET_ENV}"
  else
    sed -i "s|^APP_ACME_EMAIL=.*|APP_ACME_EMAIL=|" "${TARGET_ENV}"
  fi

  # Database passwords
  if [[ "${INSTALL_PASS_CHOICE}" != "keep" ]]; then
    sed -i "s|^APP_POSTGRES_PASSWORD=.*|APP_POSTGRES_PASSWORD=${INSTALL_PG_PASSWORD}|" "${TARGET_SECRETS}"
    sed -i "s|^APP_DB_PASSWORD=.*|APP_DB_PASSWORD=${INSTALL_APP_PASSWORD}|" "${TARGET_SECRETS}"
    sed -i "s|^APP_ADMIN_DB_PASSWORD=.*|APP_ADMIN_DB_PASSWORD=${INSTALL_ADMIN_PASSWORD}|" "${TARGET_SECRETS}"
  fi

  # Demo data
  if grep -q "^APP_SEED_DEMO_DATA=" "${TARGET_ENV}"; then
    sed -i "s|^APP_SEED_DEMO_DATA=.*|APP_SEED_DEMO_DATA=${INSTALL_SEED_DEMO_DATA}|" "${TARGET_ENV}"
  else
    echo "APP_SEED_DEMO_DATA=${INSTALL_SEED_DEMO_DATA}" >> "${TARGET_ENV}"
  fi

  # Data paths (separate disk for DB and FS volumes)
  if grep -q "^APP_DATA_PATH=" "${TARGET_ENV}"; then
    sed -i "s|^APP_DATA_PATH=.*|APP_DATA_PATH=${INSTALL_DATA_PATH}|" "${TARGET_ENV}"
  else
    echo "APP_DATA_PATH=${INSTALL_DATA_PATH}" >> "${TARGET_ENV}"
  fi
  if grep -q "^APP_FS_DATA_PATH=" "${TARGET_ENV}"; then
    sed -i "s|^APP_FS_DATA_PATH=.*|APP_FS_DATA_PATH=${INSTALL_FS_DATA_PATH}|" "${TARGET_ENV}"
  else
    echo "APP_FS_DATA_PATH=${INSTALL_FS_DATA_PATH}" >> "${TARGET_ENV}"
  fi
  if grep -q "^APP_FS_VOLUME_MAX_GB=" "${TARGET_ENV}"; then
    sed -i "s|^APP_FS_VOLUME_MAX_GB=.*|APP_FS_VOLUME_MAX_GB=${INSTALL_FS_VOLUME_MAX_GB}|" "${TARGET_ENV}"
  else
    echo "APP_FS_VOLUME_MAX_GB=${INSTALL_FS_VOLUME_MAX_GB}" >> "${TARGET_ENV}"
  fi

  local fs_effective_data_path="${INSTALL_FS_DATA_PATH:-${INSTALL_DATA_PATH}}"
  if [[ -n "${INSTALL_DATA_PATH}" ]]; then
    mkdir -p "${INSTALL_DATA_PATH}/db"
  fi
  if [[ -n "${fs_effective_data_path}" ]]; then
    mkdir -p "${fs_effective_data_path}/fs"
  fi
  if [[ -n "${INSTALL_DATA_PATH}" ]] || [[ -n "${fs_effective_data_path}" ]]; then
    info "data directories created (db: ${INSTALL_DATA_PATH:-default}, fs: ${fs_effective_data_path:-default})"
  fi

  # Firewall settings
  if grep -q "^APP_FIREWALL_ADMIN_ACCESS=" "${TARGET_ENV}"; then
    sed -i "s|^APP_FIREWALL_ADMIN_ACCESS=.*|APP_FIREWALL_ADMIN_ACCESS=${INSTALL_FIREWALL_ACCESS}|" "${TARGET_ENV}"
  else
    echo "APP_FIREWALL_ADMIN_ACCESS=${INSTALL_FIREWALL_ACCESS}" >> "${TARGET_ENV}"
  fi
  if grep -q "^APP_FIREWALL_ADMIN_ALLOWED=" "${TARGET_ENV}"; then
    sed -i "s|^APP_FIREWALL_ADMIN_ALLOWED=.*|APP_FIREWALL_ADMIN_ALLOWED=${INSTALL_FIREWALL_ALLOWED}|" "${TARGET_ENV}"
  else
    echo "APP_FIREWALL_ADMIN_ALLOWED=${INSTALL_FIREWALL_ALLOWED}" >> "${TARGET_ENV}"
  fi

  # Image tags (already correct version from kit template)
  if [[ -f "${TEMPLATE_ENV}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      [[ "${line}" =~ ^APP_.*_IMAGE= ]] || continue
      local img_key img_val
      img_key="${line%%=*}"
      img_val="${line#*=}"
      img_val=$(echo "${img_val}" | tr -d '"' | tr -d "'")
      if grep -q "^${img_key}=" "${TARGET_ENV}" 2>/dev/null; then
        sed -i "s|^${img_key}=.*|${img_key}=${img_val}|" "${TARGET_ENV}"
      else
        echo "${img_key}=${img_val}" >> "${TARGET_ENV}"
      fi
    done < "${TEMPLATE_ENV}"
  fi

  # pgAdmin
  if grep -q "^APP_PGADMIN_ENABLED=" "${TARGET_ENV}"; then
    sed -i "s|^APP_PGADMIN_ENABLED=.*|APP_PGADMIN_ENABLED=true|" "${TARGET_ENV}"
  else
    echo "APP_PGADMIN_ENABLED=true" >> "${TARGET_ENV}"
  fi
  if grep -q "^APP_PGADMIN_EMAIL=" "${TARGET_ENV}"; then
    sed -i "s|^APP_PGADMIN_EMAIL=.*|APP_PGADMIN_EMAIL=${APP_PGADMIN_EMAIL_DEFAULT}|" "${TARGET_ENV}"
  else
    echo "APP_PGADMIN_EMAIL=${APP_PGADMIN_EMAIL_DEFAULT}" >> "${TARGET_ENV}"
  fi

  # Apply firewall rules for cockpit
  ensure_executable
  apply_firewall_admin_tools

  # TLS certificates
  if [[ "${INSTALL_TLS_MODE}" == "manual" ]] && [[ "${INSTALL_GENERATE_CERTS}" == "yes" ]]; then
    log "generating tls certificates..."
    mkdir -p "${TLS_DIR}"
    if "${SCRIPTS_DIR}/tls/gen-self-signed-tls.sh" "${INSTALL_DOMAIN}" "${TLS_DIR}" --force; then
      info "tls certificates generated."
    else
      err "certificate generation failed!"
    fi
  fi

  if [[ "${INSTALL_TLS_MODE}" == "manual" ]] && [[ "${INSTALL_GENERATE_CERTS}" == "no" ]] && [[ "${INSTALL_CERT_CHOICE}" == "own" ]]; then
    mkdir -p "${TLS_DIR}"
    echo ""
    echo "please place your TLS certificates in: ${TLS_DIR}/"
    echo "  - cert.pem (server certificate)"
    echo "  - key.pem (private key)"
    echo ""
    read -r -p "press enter when files are ready..."
    if [[ -f "${TLS_DIR}/cert.pem" ]] && [[ -f "${TLS_DIR}/key.pem" ]]; then
      local validation_errors
      validation_errors=$(validate_user_certificate "${TLS_DIR}/cert.pem" "${TLS_DIR}/key.pem" "${INSTALL_DOMAIN}" 2>&1)
      if [[ $? -ne 0 ]]; then
        err "certificate validation failed!"
        while IFS= read -r error_msg; do
          [[ -n "${error_msg}" ]] && info "  ${error_msg}"
        done <<< "${validation_errors}"
        warn "deployment may fail if certificates are invalid."
      else
        info "certificates validated."
      fi
    else
      warn "certificates not found in ${TLS_DIR}/. you can add them later."
    fi
  fi

  info "configuration applied."
  CONFIG_EXISTS=1

  # --- Phase 5: Deploy containers ---
  phase "5/5" "deploying containers"
  deploy_up

  # Clean up install config (contains passwords)
  rm -f "${INSTALL_CONFIG}"
  INSTALL_CONFIG_EXISTS=0
}

# --- Manual Environment Configuration (Advanced) ---

edit_file() {
  local file="$1"
  ensure_config_files
  if command -v nano >/dev/null 2>&1; then
    nano "${file}"
  else
    vi "${file}"
  fi
}

apply_auto_secrets() {
  log "auto-generating missing secrets..."
  ensure_config_files
  
  local keys=("APP_POSTGRES_PASSWORD" "APP_ADMIN_DB_PASSWORD" "APP_DB_PASSWORD" "APP_VALKEY_PASSWORD" "APP_FS_ACCESS_KEY" "APP_FS_SECRET_KEY")
  local updated=0
  
  for key in "${keys[@]}"; do
    local val
    val=$(grep "^${key}=" "${TARGET_SECRETS}" 2>/dev/null | cut -d'=' -f2 || echo "")
    if [[ -z "${val}" ]]; then
      local new_val
      new_val=$(generate_password)
      sed -i "s|^${key}=.*|${key}=${new_val}|" "${TARGET_SECRETS}"
      info "generated ${key}"
      updated=1
    fi
  done
  
  if [[ $updated -eq 0 ]]; then
    info "all secrets already configured."
  fi
  
  read -r -p "press enter to continue..."
}

tls_generate() {
  ensure_config_files
  ensure_executable
  
  local domain
  domain=$(grep "^APP_DOMAIN=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
  
  if [[ -z "${domain}" ]] || [[ "${domain}" == "app.example.com" ]]; then
    warn "APP_DOMAIN is not set or still default."
    read -r -p "enter domain or ip address: " domain
    if [[ -z "${domain}" ]]; then
      err "domain cannot be empty."
      return
    fi
    sed -i "s|^APP_DOMAIN=.*|APP_DOMAIN=${domain}|" "${TARGET_ENV}"
  fi
  
  if [[ -f "${TLS_DIR}/cert.pem" ]]; then
    if ! confirm "certificates already exist. regenerate?"; then
      return
    fi
  fi
  
  mkdir -p "${TLS_DIR}"
  
  if "${SCRIPTS_DIR}/tls/gen-self-signed-tls.sh" "${domain}" "${TLS_DIR}" --force; then
    info "certificates generated successfully!"
    
    # Update TLS mode
    sed -i "s|^APP_TLS_MODE=.*|APP_TLS_MODE=manual|" "${TARGET_ENV}"
    info "APP_TLS_MODE set to 'manual'"
  else
    err "certificate generation failed!"
  fi
  
  read -r -p "press enter to continue..."
}

tls_show_info() {
  if [[ ! -f "${TLS_DIR}/cert.pem" ]]; then
    warn "no certificates found."
    read -r -p "press enter to continue..."
    return
  fi
  
  echo ""
  log "=== certificate information ==="
  openssl x509 -in "${TLS_DIR}/cert.pem" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || true
  echo ""
  
  read -r -p "press enter to continue..."
}

tls_client_instructions() {
  echo ""
  log "=== client certificate installation ==="
  echo ""
  
  if [[ ! -f "${TLS_DIR}/app-tls.crt" ]]; then
    warn "ca certificate not found. generate certificates first."
    read -r -p "press enter to continue..."
    return
  fi
  
  echo "to eliminate browser warnings, install the ca certificate on client devices."
  echo ""
  echo "certificate file: ${TLS_DIR}/app-tls.crt"
  echo ""
  printf "${CYAN}windows:${NC} double-click file > install certificate > local machine > trusted root ca\n"
  printf "${CYAN}macos:${NC} double-click file > add to keychain > set 'always trust'\n"
  printf "${CYAN}linux:${NC} sudo cp app-tls.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates\n"
  printf "${CYAN}firefox:${NC} settings > privacy > certificates > import > trust for websites\n"
  echo ""
  
  read -r -p "press enter to continue..."
}

menu_manual_config() {
  while true; do
    echo ""
    log "=== manual configuration (advanced) ==="
    echo ""
    printf "  environment: %s\n" "$(check_env_status)"
    printf "  secrets:     %s\n" "$(check_secrets_status)"
    printf "  tls:         %s\n" "$(check_tls_status)"
    echo ""
    echo "0) back"
    echo "1) edit environment (app.env)"
    echo "2) edit secrets (app.secrets.env)"
    echo "3) auto-generate missing secrets"
    echo "4) generate tls certificates"
    echo "5) view certificate info"
    echo "6) client certificate instructions"
    read -r -p "select [0-6]: " opt
    case $opt in
      0) break ;;
      1) edit_file "${TARGET_ENV}" ;;
      2) edit_file "${TARGET_SECRETS}" ;;
      3) apply_auto_secrets ;;
      4) tls_generate ;;
      5) tls_show_info ;;
      6) tls_client_instructions ;;
      *) warn "invalid option" ;;
    esac
  done
}

menu_env_config() {
  while true; do
    echo ""
    log "=== containers environment configuration ==="
    echo ""
    echo "0) back to main menu"
    echo "1) guided configuration"
    echo "2) manual configuration (advanced, can be adjusted after guided config)"
    echo ""
    read -r -p "select [0-2]: " opt
    case $opt in
      0) break ;;
      1) if [[ "${CONFIG_EXISTS}" -eq 1 ]]; then guided_setup reconfigure; else guided_setup; fi; break ;;
      2) menu_manual_config ;;
      *) warn "invalid option" ;;
    esac
  done
}

# --- Deployment Summary Helper Functions ---

get_project_containers() {
  local containers=("db" "state" "fs" "be" "fe" "reverse-proxy" "worker")
  
  # Check if pgAdmin is enabled
  if [[ -f "${TARGET_ENV}" ]]; then
    local pgadmin_enabled
    pgadmin_enabled=$(grep "^APP_PGADMIN_ENABLED=" "${TARGET_ENV}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]' || echo "false")
    if [[ "${pgadmin_enabled}" == "true" ]]; then
      containers+=("pgadmin")
    fi
  fi
  
  printf "%s\n" "${containers[@]}"
}

get_container_status() {
  local container_name="$1"
  local state
  
  # Use inspect for authoritative status
  if ! state=$(podman inspect --format "{{.State.Status}}" "${container_name}" 2>/dev/null); then
    echo "not_found"
    return
  fi
  
  if [[ "${state}" == "running" ]]; then
    # Check if restarting
    if podman inspect --format "{{.State.Restarting}}" "${container_name}" 2>/dev/null | grep -q "true"; then
      echo "restarting"
    else
      echo "running"
    fi
  elif [[ "${state}" == "created" ]] || [[ "${state}" == "initialized" ]]; then
    echo "starting"
  else
    echo "stopped"
  fi
}

get_container_health() {
  local container_name="$1"
  local health
  health=$(podman inspect --format "{{.State.Health.Status}}" "${container_name}" 2>/dev/null || echo "none")
  
  if [[ -z "${health}" ]] || [[ "${health}" == "<no value>" ]]; then
    echo "none"
  else
    echo "${health}"
  fi
}

get_container_uptime() {
  local container_name="$1"
  local uptime
  uptime=$(podman inspect --format "{{.State.StartedAt}}" "${container_name}" 2>/dev/null || echo "")
  
  if [[ -z "${uptime}" ]] || [[ "${uptime}" == "<no value>" ]]; then
    echo ""
    return
  fi
  
  # Calculate uptime from started time
  local started_epoch
  started_epoch=$(date -d "${uptime}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${uptime}" +%s 2>/dev/null || echo "0")
  local now_epoch
  now_epoch=$(date +%s)
  
  if [[ "${started_epoch}" == "0" ]] || [[ "${started_epoch}" -eq 0 ]]; then
    echo ""
    return
  fi
  
  local diff=$((now_epoch - started_epoch))
  local minutes=$((diff / 60))
  local hours=$((minutes / 60))
  local days=$((hours / 24))
  
  if [[ ${days} -gt 0 ]]; then
    echo "${days}d ${hours}h"
  elif [[ ${hours} -gt 0 ]]; then
    echo "${hours}h ${minutes}m"
  else
    echo "${minutes}m"
  fi
}

get_container_ports() {
  local container_name="$1"
  podman ps --filter "name=^${container_name}$" --format "{{.Ports}}" 2>/dev/null | head -1 || echo ""
}

display_deployment_summary() {
  local init_status="$1"
  local init_time="$2"
  local init_errors="$3"
  local up_status="$4"
  local up_time="$5"
  local up_errors="$6"
  local total_time="$7"
  
  # Compute container status first for overall result
  local containers
  containers=$(get_project_containers)
  local container_running=0
  local container_total=0
  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    container_total=$((container_total + 1))
    if [[ "$(get_container_status "${c}")" == "running" ]]; then
      container_running=$((container_running + 1))
    fi
  done <<< "${containers}"
  
  title_box "deployment summary"
  echo ""
  
  # 1. Overall result (steps + actual container status)
  printf "  ${NEON_CYAN}overall result:${NC}\n"
  local step_ok=false
  [[ "${init_status}" == "success" ]] && [[ "${up_status}" == "success" ]] && step_ok=true
  local all_containers_ok=false
  [[ ${container_total} -gt 0 ]] && [[ ${container_running} -eq ${container_total} ]] && all_containers_ok=true
  
  if [[ "${step_ok}" == "true" ]] && [[ "${all_containers_ok}" == "true" ]]; then
    printf "    ${SYM_OK} ${GREEN}SUCCESS${NC} - all steps completed successfully, %d/%d containers running\n" "${container_running}" "${container_total}"
  elif [[ "${step_ok}" == "true" ]] && [[ ${container_running} -lt ${container_total} ]]; then
    printf "    ${SYM_WARN} ${YELLOW}PARTIAL${NC} - steps completed but only %d/%d containers running\n" "${container_running}" "${container_total}"
  elif [[ "${init_status}" != "success" ]] && [[ "${up_status}" != "success" ]]; then
    printf "    ${SYM_FAIL} ${RED}FAILED${NC} - all steps failed\n"
  elif [[ "${init_status}" != "success" ]] || [[ "${up_status}" != "success" ]]; then
    printf "    ${SYM_FAIL} ${RED}FAILED${NC} - one or more steps failed\n"
  else
    printf "    ${SYM_WARN} ${YELLOW}PARTIAL${NC} - some steps completed, some failed\n"
  fi
  
  printf "    total time: ${CYAN}%s${NC} seconds\n" "${total_time}"
  echo ""
  
  # 2. Step statistics
  printf "  ${CYAN}step statistics:${NC}\n"
  
  # Init step
  if [[ "${init_status}" == "success" ]]; then
    printf "    ${SYM_OK} init: ${GREEN}success${NC} (${init_time}s)\n"
  else
    printf "    ${SYM_FAIL} init: ${RED}failed${NC} (${init_time}s)\n"
  fi
  
  # Up step
  if [[ "${up_status}" == "success" ]]; then
    printf "    ${SYM_OK} up: ${GREEN}success${NC} (${up_time}s)\n"
  else
    printf "    ${SYM_FAIL} up: ${RED}failed${NC} (${up_time}s)\n"
  fi
  
  echo ""
  
  # 3. Critical errors
  printf "  ${CYAN}critical errors:${NC}\n"
  local has_errors=false
  
  if [[ -n "${init_errors}" ]]; then
    has_errors=true
    printf "    ${SYM_FAIL} ${RED}init${NC}: %s\n" "${init_errors}"
  fi
  
  if [[ -n "${up_errors}" ]]; then
    has_errors=true
    printf "    ${SYM_FAIL} ${RED}up${NC}: %s\n" "${up_errors}"
  fi
  
  if [[ ${container_total} -gt 0 ]] && [[ ${container_running} -lt ${container_total} ]] && [[ "${has_errors}" == "false" ]]; then
    has_errors=true
    printf "    ${SYM_WARN} not all containers running (see container status below)\n"
  fi
  
  if [[ "${has_errors}" == "false" ]]; then
    printf "    ${SYM_OK} no critical errors\n"
  fi
  
  echo ""
  
  # 4. Container status
  printf "  ${CYAN}container status:${NC}\n"
  
  local containers
  containers=$(get_project_containers)
  local running_count=0
  local total_count=0
  
  while IFS= read -r container; do
    [[ -z "${container}" ]] && continue
    total_count=$((total_count + 1))
    
    local status
    status=$(get_container_status "${container}")
    local health
    health=$(get_container_health "${container}")
    local uptime
    uptime=$(get_container_uptime "${container}")
    local ports
    ports=$(get_container_ports "${container}")
    
    # Status display
    case "${status}" in
      running)
        printf "    ${SYM_OK} ${GREEN}%-15s${NC}" "${container}:"
        running_count=$((running_count + 1))
        ;;
      restarting|starting)
        printf "    ${SYM_WARN} ${YELLOW}%-15s${NC}" "${container}:"
        ;;
      stopped|not_found)
        printf "    ${SYM_FAIL} ${RED}%-15s${NC}" "${container}:"
        ;;
      *)
        printf "    ${SYM_PENDING} %-15s" "${container}:"
        ;;
    esac
    
    # Status text
    case "${status}" in
      running)
        printf " ${GREEN}running${NC}"
        ;;
      restarting)
        printf " ${YELLOW}restarting${NC}"
        ;;
      starting)
        printf " ${YELLOW}starting${NC}"
        ;;
      stopped)
        printf " ${RED}stopped${NC}"
        ;;
      not_found)
        printf " ${RED}not found${NC}"
        ;;
      *)
        printf " ${GRAY}unknown${NC}"
        ;;
    esac
    
    # Health status
    if [[ "${status}" == "running" ]]; then
      case "${health}" in
        healthy)
          printf " ${GREEN}(healthy)${NC}"
          ;;
        unhealthy)
          printf " ${YELLOW}(unhealthy)${NC}"
          ;;
        starting)
          printf " ${YELLOW}(healthcheck starting)${NC}"
          ;;
        *)
          printf " ${GRAY}(no healthcheck)${NC}"
          ;;
      esac
      
      # Uptime
      if [[ -n "${uptime}" ]]; then
        printf " uptime: ${CYAN}%s${NC}" "${uptime}"
      fi
    fi
    
    echo ""
  done <<< "${containers}"
  
  # Summary stats
  printf "    ${CYAN}summary:${NC} ${running_count}/${total_count} containers running\n"
  echo ""
}

# Print final deployment summary: evi app, optional demo accounts, and admin tools (cockpit, pgadmin).
# Uses APP_* from load_deploy_env. Each block: header, address/account/password in green, notes.
# The demo-accounts block is printed only when this deploy seeded demo data.
display_final_summary() {
  local up_status="${1:-}"
  local seeded_demo="${2:-false}"
  if [[ "${up_status}" != "success" ]]; then
    title_box "deployment did not finish"
    echo ""
    printf "  containers are not up. fix the errors above, then run deploy again.\n"
    echo ""
    read -r -p "press enter to continue..."
    return
  fi
  local cockpit_allowed
  cockpit_allowed=$(get_cockpit_allowed_summary)
  local domain="${APP_DOMAIN:-}"
  [[ -z "${domain}" ]] && domain="<server>"

  title_box "application is online"
  echo ""
  printf "  ${NEON_MAGENTA}${BOLD}%s${NC} %s%s%s\n" "${SECT_CH}${SECT_CH}" "${NEON_CYAN}${BOLD}" "web application" "${NC}"
  printf "  address:  ${NEON_GREEN}https://%s${NC}\n" "${domain}"
  printf "  account:  ${NEON_GREEN}admin${NC}\n"
  printf "  password:  ${NEON_GREEN}lock${NC}\n"
  printf "  ${DIM}notes: don't forget to change password.${NC}\n"
  echo ""
  if [[ "${seeded_demo}" == "true" ]]; then
    printf "  ${NEON_MAGENTA}${BOLD}%s${NC} %s%s%s\n" "${SECT_CH}${SECT_CH}" "${NEON_CYAN}${BOLD}" "demo accounts" "${NC}"
    printf "  status:  ${NEON_GREEN}active${NC}\n"
    printf "  password:  ${NEON_GREEN}lock${NC}\n"
    printf "${NEON_AMBER}${BOLD}IMPORTANT:${NC}${NEON_AMBER} every demo account is active and its password is ${NC}${NEON_GREEN}lock${NC}${NEON_AMBER}. Should you use this installation for production purpose, we recommend you to change all demo accounts passwords.${NC}\n"
    echo ""
  fi
  printf "  ${NEON_MAGENTA}${BOLD}%s${NC} %s%s%s\n" "${SECT_CH}${SECT_CH}" "${NEON_CYAN}${BOLD}" "cockpit (admin tool)" "${NC}"
  printf "  address:  ${NEON_GREEN}https://%s:9090${NC}\n" "${domain}"
  printf "  connections allowed from:  ${NEON_GREEN}%s${NC}\n" "${cockpit_allowed}"
  printf "  account:  ${NEON_GREEN}your host OS user account${NC}\n"
  printf "  password:  ${NEON_GREEN}password of your host OS user account${NC}\n"
  printf "  ${DIM}notes: used for management of host OS and containers, performance monitoring, backups creation etc.${NC}\n"
  echo ""

  if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
    printf "  ${NEON_MAGENTA}${BOLD}%s${NC} %s%s%s\n" "${SECT_CH}${SECT_CH}" "${NEON_CYAN}${BOLD}" "pgadmin (database management)" "${NC}"
    printf "  address:  ${NEON_GREEN}http://%s:5445${NC}\n" "${domain}"
    printf "  connections allowed from:  ${NEON_GREEN}%s${NC}\n" "${cockpit_allowed}"
    printf "  account:  ${NEON_GREEN}%s${NC}\n" "${APP_PGADMIN_EMAIL:-${APP_PGADMIN_EMAIL_DEFAULT}}"
    printf "  password:  ${NEON_GREEN}APP_ADMIN_DB_PASSWORD in %s${NC}\n" "${TARGET_SECRETS}"
    printf "  ${DIM}notes: used for postgres DB administration${NC}\n"
    echo ""
  fi

  if [[ "${APP_TLS_MODE:-}" == "manual" ]]; then
    printf "${NEON_AMBER}${BOLD}IMPORTANT:${NC}${NEON_AMBER} if you used self-signed certificates, the browser will show a security warning — this is expected.${NC}\n"
    echo ""
  fi

  local ssh_autoban="off" ssh_bt="" ssh_mr=""
  if command -v fail2ban-client >/dev/null 2>&1; then
    if sudo -n fail2ban-client status sshd >/dev/null 2>&1 || fail2ban-client status sshd >/dev/null 2>&1; then
      ssh_autoban="on"
      ssh_bt="$(sudo -n fail2ban-client get sshd bantime 2>/dev/null || fail2ban-client get sshd bantime 2>/dev/null || true)"
      ssh_mr="$(sudo -n fail2ban-client get sshd maxretry 2>/dev/null || fail2ban-client get sshd maxretry 2>/dev/null || true)"
      if [[ -n "${ssh_bt}" || -n "${ssh_mr}" ]]; then
        ssh_autoban="on (bantime ${ssh_bt}, maxretry ${ssh_mr})"
      fi
    fi
  fi
  printf "  SSH autoban:  ${NEON_GREEN}%s${NC}\n" "${ssh_autoban}"
  echo ""

  read -r -p "press enter to continue..."
}

# --- Deployment ---

# Load app.env and app.secrets.env for deploy (init and pull/start). Exports all APP_* needed.
load_deploy_env() {
  # shellcheck disable=SC1090
  source "${TARGET_ENV}"
  # shellcheck disable=SC1090
  source "${TARGET_SECRETS}"
  local _canonical_install_repo="vk74/ready-room"
  if [[ -f "${TEMPLATE_ENV}" ]]; then
    local _tpl_repo=""
    _tpl_repo=$(grep "^APP_INSTALL_REPO=" "${TEMPLATE_ENV}" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    _tpl_repo="${_tpl_repo%$'\r'}"
    if [[ -n "${_tpl_repo}" ]]; then
      _canonical_install_repo="${_tpl_repo}"
    fi
  fi
  local _legacy_install_repo="vk74"
  _legacy_install_repo="${_legacy_install_repo}/evi"
  if [[ -z "${APP_INSTALL_REPO:-}" || "${APP_INSTALL_REPO}" == "${_legacy_install_repo}" ]]; then
    APP_INSTALL_REPO="${_canonical_install_repo}"
    if [[ -f "${TARGET_ENV}" ]]; then
      if grep -q "^APP_INSTALL_REPO=" "${TARGET_ENV}"; then
        sed -i "s|^APP_INSTALL_REPO=.*|APP_INSTALL_REPO=${APP_INSTALL_REPO}|" "${TARGET_ENV}"
      else
        printf 'APP_INSTALL_REPO=%s\n' "${APP_INSTALL_REPO}" >> "${TARGET_ENV}"
      fi
    fi
  fi
  export APP_INSTALL_REPO
  export APP_STATE_DIR="${APP_STATE_DIR:-${APP_STATE_DIR_DEFAULT}}"
  export APP_QUADLET_DIR="${APP_QUADLET_DIR:-${APP_QUADLET_DIR_DEFAULT}}"
  export APP_DATA_PATH="${APP_DATA_PATH:-}"
  export APP_FS_DATA_PATH="${APP_FS_DATA_PATH:-${APP_DATA_PATH:-}}"
  export APP_JWT_SECRET_NAME="${APP_JWT_SECRET_NAME:-jwt_private_key}"
  export APP_ADMIN_DB_USERNAME="${APP_ADMIN_DB_USERNAME:-evidba}"
  export APP_PGADMIN_ENABLED="${APP_PGADMIN_ENABLED:-false}"
  export APP_PGADMIN_IMAGE="${APP_PGADMIN_IMAGE:-docker.io/dpage/pgadmin4:9.15}"
  export APP_PGADMIN_HOST="${APP_PGADMIN_HOST:-0.0.0.0}"
  export APP_PGADMIN_PORT="${APP_PGADMIN_PORT:-5445}"
  export APP_PGADMIN_EMAIL="${APP_PGADMIN_EMAIL:-${APP_PGADMIN_EMAIL_DEFAULT}}"
  export APP_FS_IMAGE="${APP_FS_IMAGE:-docker.io/chrislusf/seaweedfs:4.17}"
  export APP_FS_S3_PORT="${APP_FS_S3_PORT:-8333}"
  export APP_FS_BUCKET="${APP_FS_BUCKET:-evi-fs}"
  export APP_FS_SECRET_NAME="${APP_FS_SECRET_NAME:-fs_credentials}"
  export APP_FS_VOLUME_MAX_GB="${APP_FS_VOLUME_MAX_GB:-100}"
  export APP_FS_VOLUME_MAX="${APP_FS_VOLUME_MAX_GB:-}"
}

# Install/update evi-disk-monitor systemd user timer+service from templates.
# Replaces {{DEPLOYMENT_DIR}} and enables the timer.
deploy_install_disk_monitor() {
  local systemd_user_dir="${HOME}/.config/systemd/user"
  local tpl_dir="${SCRIPT_DIR}/systemd-templates"
  if [[ ! -d "${tpl_dir}" ]]; then
    return 0
  fi
  mkdir -p "${systemd_user_dir}"
  for unit_name in disk-monitor.service disk-monitor.timer; do
    local tpl="${tpl_dir}/${unit_name}"
    [[ -f "${tpl}" ]] || continue
    local content
    content="$(cat "${tpl}")"
    content="${content//\{\{DEPLOYMENT_DIR\}\}/${SCRIPT_DIR}}"
    printf "%s\n" "${content}" > "${systemd_user_dir}/${unit_name}"
  done
  chmod +x "${SCRIPTS_DIR}/admin/check-disk-space.sh" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now disk-monitor.timer 2>/dev/null || true
}

# Deploy init: ensure dirs, JWT secret, TLS, Caddyfile, Quadlets. All logic in install.sh.
# Creates config/ directory structure: tls, state (reverse-proxy, secrets, pgadmin), backup, updates.
deploy_ensure_dirs() {
  mkdir -p "${CONFIG_DIR}" "${TLS_DIR}"
  mkdir -p "${CONFIG_DIR}/backup" "${CONFIG_DIR}/updates"
  mkdir -p "${APP_STATE_DIR:-}/reverse-proxy" "${APP_STATE_DIR:-}/secrets"
  mkdir -p "${APP_STATE_DIR:-}/pgadmin" "${APP_STATE_DIR:-}/pgadmin/data"
  mkdir -p "${APP_STATE_DIR:-}/valkey"
  mkdir -p "${APP_QUADLET_DIR:-}"
  if [[ -d "${APP_STATE_DIR:-}/pgadmin/data" ]]; then
    podman unshare chown -R 5050:5050 "${APP_STATE_DIR:-}/pgadmin/data" 2>/dev/null || true
  fi
  # Ensure data directories exist when using separate disks for DB, FS, and/or state volumes
  local fs_data_path="${APP_FS_DATA_PATH:-${APP_DATA_PATH:-}}"
  if [[ -n "${APP_DATA_PATH:-}" ]]; then
    mkdir -p "${APP_DATA_PATH:-}/db" 2>/dev/null || true
    mkdir -p "${APP_DATA_PATH:-}/state" 2>/dev/null || true
  fi
  if [[ -n "${fs_data_path}" ]]; then
    mkdir -p "${fs_data_path}/fs" 2>/dev/null || true
  fi
}

# --- Render functions (shared with apply-update.sh via render-templates.sh) ---
_RENDER_TEMPLATES_LOADED=0
ensure_render_templates_sourced() {
  [[ "${_RENDER_TEMPLATES_LOADED}" -eq 1 ]] && return 0
  local rt="${SCRIPTS_DIR}/lib/render-templates.sh"
  [[ -f "${rt}" ]] || die "missing ${rt}. extract the full deploy kit here, or complete option 2 (deploy) so the release archive installs scripts/."
  # shellcheck source=scripts/lib/render-templates.sh
  source "${rt}"
  _RENDER_TEMPLATES_LOADED=1
}

# Shared by run_deploy_init and restore: fill/persist state RAM profile, then render valkey.conf.
deploy_apply_and_render_state_memory() {
  ensure_render_templates_sourced
  deploy_apply_state_memory_profile || true
  deploy_persist_limit_mem_state "${TARGET_ENV}"
  deploy_warn_state_disk_if_needed
  local src="${SCRIPT_DIR}/state/valkey.conf"
  [[ -f "${src}" ]] || die "valkey.conf not found at ${src} (required for state). When using sparse-checkout, ensure deploy/state/ is checked out."
  deploy_render_valkey_conf "${src}" "${APP_STATE_DIR:-}/valkey/valkey.conf"
  local limit="${APP_LIMIT_MEM_STATE:-}"
  local maxmem profile
  maxmem="$(deploy_state_maxmemory_for_limit "${limit}")"
  profile="$(deploy_state_profile_name_for_limit "${limit}")"
  log "state memory profile ${profile} → APP_LIMIT_MEM_STATE=${limit} maxmemory ${maxmem}"
}

deploy_create_or_update_secret_from_file() {
  local secret_name="$1" file_path="$2"
  [[ -f "${file_path}" ]] || die "Secret source file not found: ${file_path}"
  podman secret inspect "${secret_name}" >/dev/null 2>&1 && podman secret rm "${secret_name}" >/dev/null || true
  podman secret create "${secret_name}" "${file_path}" >/dev/null
}

deploy_prepare_jwt_secret() {
  require_cmd podman || die "Missing command: podman"
  local target="${APP_STATE_DIR:-}/secrets/jwt_private_key.pem"
  if [[ "${APP_JWT_GENERATE_KEY:-}" == "true" ]]; then
    log "Generating new JWT key pair..."
    require_cmd openssl || die "Missing command: openssl"
    chmod +x "${SCRIPTS_DIR}/tls/gen-jwt-rs256-keypair.sh"
    "${SCRIPTS_DIR}/tls/gen-jwt-rs256-keypair.sh" "${APP_STATE_DIR:-}/secrets" "jwt_private_key.pem" >/dev/null
    log "OK: JWT key pair generated."
  elif [[ -n "${APP_JWT_PRIVATE_KEY_PEM_PATH:-}" ]]; then
    log "Using provided JWT key from file..."
    cp -f "${APP_JWT_PRIVATE_KEY_PEM_PATH:-}" "${target}"
    chmod 600 "${target}"
  elif [[ -n "${APP_JWT_PRIVATE_KEY_PEM_INLINE:-}" ]]; then
    log "Using provided JWT key from inline config..."
    printf "%s\n" "${APP_JWT_PRIVATE_KEY_PEM_INLINE:-}" > "${target}"
    chmod 600 "${target}"
  else
    die "JWT key not provided. Set APP_JWT_GENERATE_KEY=true or provide APP_JWT_PRIVATE_KEY_PEM_PATH or APP_JWT_PRIVATE_KEY_PEM_INLINE."
  fi
  deploy_create_or_update_secret_from_file "${APP_JWT_SECRET_NAME:-}" "${target}"
  log "OK: created/updated podman secret ${APP_JWT_SECRET_NAME:-}"
}

deploy_prepare_valkey_secret() {
  require_cmd podman || die "Missing command: podman"
  if [[ -z "${APP_VALKEY_PASSWORD:-}" ]]; then
    ensure_config_files
    local new_val
    new_val=$(generate_password)
    sed -i "s|^APP_VALKEY_PASSWORD=.*|APP_VALKEY_PASSWORD=${new_val}|" "${TARGET_SECRETS}"
    APP_VALKEY_PASSWORD="${new_val}"
    log "Auto-generated APP_VALKEY_PASSWORD and saved to ${TARGET_SECRETS}"
  fi
  local secret_name="${APP_VALKEY_SECRET_NAME:-valkey_password}"
  podman secret inspect "${secret_name}" >/dev/null 2>&1 && podman secret rm "${secret_name}" >/dev/null || true
  printf '%s' "${APP_VALKEY_PASSWORD:-}" | podman secret create "${secret_name}" - >/dev/null
  log "OK: created/updated podman secret ${secret_name}"
}

deploy_prepare_fs_credentials() {
  require_cmd podman || die "Missing command: podman"
  if [[ -z "${APP_FS_ACCESS_KEY:-}" ]]; then
    ensure_config_files
    local new_key
    new_key=$(generate_password)
    sed -i "s|^APP_FS_ACCESS_KEY=.*|APP_FS_ACCESS_KEY=${new_key}|" "${TARGET_SECRETS}"
    APP_FS_ACCESS_KEY="${new_key}"
    log "Auto-generated APP_FS_ACCESS_KEY and saved to ${TARGET_SECRETS}"
  fi
  if [[ -z "${APP_FS_SECRET_KEY:-}" ]]; then
    ensure_config_files
    local new_key
    new_key=$(generate_password)
    sed -i "s|^APP_FS_SECRET_KEY=.*|APP_FS_SECRET_KEY=${new_key}|" "${TARGET_SECRETS}"
    APP_FS_SECRET_KEY="${new_key}"
    log "Auto-generated APP_FS_SECRET_KEY and saved to ${TARGET_SECRETS}"
  fi
  local secret_name="${APP_FS_SECRET_NAME:-fs_credentials}"
  local creds_file
  creds_file=$(mktemp)
  cat > "${creds_file}" <<EOF
{
  "identities": [
    {
      "name": "app",
      "credentials": [
        {
          "accessKey": "${APP_FS_ACCESS_KEY:-}",
          "secretKey": "${APP_FS_SECRET_KEY:-}"
        }
      ],
      "actions": ["Read", "Write", "List", "Tagging", "Admin"]
    }
  ]
}
EOF
  podman secret inspect "${secret_name}" >/dev/null 2>&1 && podman secret rm "${secret_name}" >/dev/null || true
  podman secret create "${secret_name}" "${creds_file}" >/dev/null
  rm -f "${creds_file}"
  log "OK: created/updated podman secret ${secret_name}"
}

deploy_resolve_tls_path() {
  local path="$1"
  [[ -z "${path}" ]] && { echo ""; return; }
  [[ "${path}" == /* ]] && { echo "${path}"; return; }
  [[ -f "${TLS_DIR}/${path}" ]] && { echo "${TLS_DIR}/${path}"; return; }
  [[ -f "${SCRIPT_DIR}/${path}" ]] && { echo "${SCRIPT_DIR}/${path}"; return; }
  echo "${path}"
}

deploy_prepare_manual_tls_files() {
  [[ "${APP_TLS_MODE:-}" != "manual" ]] && return 0
  local cert_path="${APP_TLS_CERT_PATH:-}" key_path="${APP_TLS_KEY_PATH:-}"
  [[ -z "${cert_path}" ]] && [[ -f "${TLS_DIR}/cert.pem" ]] && cert_path="${TLS_DIR}/cert.pem" && log "Auto-detected certificate: ${cert_path}"
  [[ -z "${key_path}" ]] && [[ -f "${TLS_DIR}/key.pem" ]] && key_path="${TLS_DIR}/key.pem" && log "Auto-detected private key: ${key_path}"
  cert_path=$(deploy_resolve_tls_path "${cert_path}")
  key_path=$(deploy_resolve_tls_path "${key_path}")
  if [[ -n "${cert_path}" && -n "${key_path}" ]]; then
    [[ -f "${cert_path}" ]] || die "TLS certificate not found: ${cert_path}"
    [[ -f "${key_path}" ]] || die "TLS private key not found: ${key_path}"
    log "Importing manual TLS certificates..."
    chmod +x "${SCRIPTS_DIR}/tls/import-tls.sh"
    "${SCRIPTS_DIR}/tls/import-tls.sh" "${cert_path}" "${key_path}" "${TLS_DIR}" >/dev/null
    log "OK: imported manual TLS cert/key to ${TLS_DIR}"
    return 0
  fi
  die "Manual TLS selected but certificates not found. Set APP_TLS_CERT_PATH and APP_TLS_KEY_PATH or place cert.pem and key.pem in ${TLS_DIR}/"
}


run_deploy_init() {
  require_cmd podman || die "Missing command: podman"
  require_cmd systemctl || die "Missing command: systemctl"
  ensure_render_templates_sourced
  load_deploy_env
  [[ -n "${APP_DOMAIN:-}" ]] || die "APP_DOMAIN is not set in app.env"
  APP_TLS_MODE="${APP_TLS_MODE:-letsencrypt}"
  [[ "${APP_TLS_MODE:-}" == "letsencrypt" || "${APP_TLS_MODE:-}" == "manual" ]] || die "Invalid APP_TLS_MODE: '${APP_TLS_MODE:-}'. Must be one of: letsencrypt, manual."
  if [[ "${APP_PGADMIN_ENABLED:-}" == "true" ]]; then
    [[ -n "${APP_PGADMIN_EMAIL:-}" ]] || die "APP_PGADMIN_EMAIL is required when APP_PGADMIN_ENABLED=true."
  fi
  [[ -n "${APP_PROXY_IMAGE:-}" ]] || die "APP_PROXY_IMAGE is required"
  [[ -n "${APP_FE_IMAGE:-}" ]] || die "APP_FE_IMAGE is required"
  [[ -n "${APP_BE_IMAGE:-}" ]] || die "APP_BE_IMAGE is required"
  [[ -n "${APP_DB_IMAGE:-}" ]] || die "APP_DB_IMAGE is required"
  deploy_ensure_dirs
  check_resources || die "host ram < 2gb (minimum 2gb). deployment stopped."
  deploy_apply_and_render_state_memory
  deploy_prepare_jwt_secret
  deploy_prepare_valkey_secret
  deploy_prepare_fs_credentials
  deploy_prepare_manual_tls_files
  deploy_render_caddyfile
  deploy_render_quadlets
  systemctl --user daemon-reload
  log "OK: init completed."
}

# Rootless Podman preflight (TUN, uidmap, LXC subuid). Fail before pull; no rootful fallback.
app_ensure_rootless_userns() {
  local checker="${SCRIPTS_DIR}/host/check-rootless-host.sh"
  if [[ ! -x "${checker}" ]]; then
    chmod +x "${checker}" 2>/dev/null || true
  fi
  if [[ -f "${checker}" ]]; then
    bash "${checker}"
    return $?
  fi
  err "cannot find the rootless host check script (${checker}). application cannot continue."
  return 1
}

# Pull container images (platform from host arch). Requires load_deploy_env. Returns 0 on success.
deploy_pull_images() {
  APP_ROOTLESS_HOST_FAILED=""
  if ! app_ensure_rootless_userns; then
    APP_ROOTLESS_HOST_FAILED=1
    return 1
  fi
  local pull_stderr
  pull_stderr=$(mktemp)
  local podman_platform=""
  case "$(uname -m)" in
    x86_64)   podman_platform="linux/amd64" ;;
    aarch64)  podman_platform="linux/arm64" ;;
    arm64)    podman_platform="linux/arm64" ;;
    armv7l)   podman_platform="linux/arm/v7" ;;
    *)        podman_platform="" ;;
  esac
  local pull_args=()
  [[ -n "${podman_platform}" ]] && pull_args=(--platform "${podman_platform}")
  local img
  for img in "${APP_PROXY_IMAGE:-}" "${APP_DB_IMAGE:-}" "${APP_STATE_IMAGE:-}" "${APP_FS_IMAGE:-}" "${APP_BE_IMAGE:-}" "${APP_FE_IMAGE:-}" "${APP_WORKER_IMAGE:-}"; do
    if ! podman_pull_ghcr "${pull_args[@]}" "${img}" 2>"${pull_stderr}"; then
      err "Failed to pull ${img}:"
      cat "${pull_stderr}" 1>&2
      rm -f "${pull_stderr}"
      return 1
    fi
    local id_size
    id_size=$(podman images --format "{{.ID}} {{.Size}}" --filter "reference=${img}" --noheading 2>/dev/null | head -1)
    printf "  ${GREEN}%-50s${NC} %s\n" "${img}" "${id_size:-}"
  done
  if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
    if ! podman_pull_ghcr "${pull_args[@]}" "${APP_PGADMIN_IMAGE:-}" 2>"${pull_stderr}"; then
      err "Failed to pull pgAdmin image ${APP_PGADMIN_IMAGE:-}:"
      cat "${pull_stderr}" 1>&2
      rm -f "${pull_stderr}"
      return 1
    fi
    local id_size
    id_size=$(podman images --format "{{.ID}} {{.Size}}" --filter "reference=${APP_PGADMIN_IMAGE:-}" --noheading 2>/dev/null | head -1)
    printf "  ${GREEN}%-50s${NC} %s\n" "${APP_PGADMIN_IMAGE:-}" "${id_size:-}"
  fi
  rm -f "${pull_stderr}"
  return 0
}

# Apply configuration and restart: init and restart services using existing images (no pull). Applies new env/secrets to current containers.
# Does not remove evi-db volume. For upgrading to new image versions use Cockpit or re-run install with updated images.
do_apply_restart() {
  # Safety guard: if on-disk install.sh was replaced (e.g., by a kit download), re-exec to main menu
  # so the user continues with the version-matched installer instead of mismatched in-memory code.
  local _disk_ver=""
  _disk_ver=$(sed -n '1,20p' "${SCRIPT_DIR}/install.sh" 2>/dev/null \
    | grep -m1 '^# Version: ' | sed 's/^# Version:[[:space:]]*//' || echo "")
  if [[ -n "${_disk_ver}" ]] && [[ "${_disk_ver}" != "${INSTALL_VERSION}" ]]; then
    info "on-disk installer version changed (${_disk_ver} vs running ${INSTALL_VERSION}). re-launching..."
    exec "${SCRIPT_DIR}/install.sh"
  fi
  log "applying configuration and restarting containers..."
  ensure_executable
  if [[ ! -f "${TARGET_ENV}" || ! -f "${TARGET_SECRETS}" ]]; then
    err "configuration files missing."
    read -r -p "press enter to continue..."
    return
  fi
  local tls_status
  tls_status=$(check_tls_status)
  if [[ "${tls_status}" == "missing_certs" ]]; then
    err "tls certificates missing. generate them in environment configuration."
    read -r -p "press enter to continue..."
    return
  fi
  log "initializing services..."
  if ! run_deploy_init; then
    err "init failed."
    read -r -p "press enter to continue..."
    return
  fi
  load_deploy_env
  log "restarting services..."
  systemctl --user daemon-reload
  systemctl --user restart db state fs be fe reverse-proxy worker 2>/dev/null || true
  if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
    systemctl --user restart pgadmin 2>/dev/null || true
  fi
  local db_name="${APP_POSTGRES_DB:-maindb}"
  local wait_attempts=8
  local wait_i=0
  while [[ ${wait_i} -lt ${wait_attempts} ]]; do
    if podman exec db pg_isready -U postgres -d "${db_name}" 2>/dev/null; then
      break
    fi
    sleep 0.5
    wait_i=$((wait_i + 1))
  done
  log "Service status:"
  local units="db state fs be fe reverse-proxy worker"
  [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]] && units="${units} pgadmin"
  for u in ${units}; do
    local state
    state=$(systemctl --user is-active "${u}" 2>/dev/null || true)
    if [[ "${state}" == "active" ]]; then
      printf "  ${GREEN}%-20s${NC} active\n" "${u}:"
    else
      printf "  ${RED}%-20s${NC} %s\n" "${u}:" "${state}"
    fi
  done
  # Refresh disk space monitor (non-fatal)
  deploy_install_disk_monitor

  echo ""
  info "configuration applied, containers restarted. for daily operations use Cockpit (app admin panel at :9090)."
  read -r -p "press enter to continue..."
}

deploy_up() {
  log "starting deployment..."
  ensure_executable
  
  if [[ ! -f "${TARGET_ENV}" || ! -f "${TARGET_SECRETS}" ]]; then
    err "configuration files missing. run guided setup first."
    read -r -p "press enter to continue..."
    return
  fi
  
  # Check TLS readiness
  local tls_status
  tls_status=$(check_tls_status)
  if [[ "${tls_status}" == "missing_certs" ]]; then
    err "tls certificates missing. generate them in environment configuration."
    read -r -p "press enter to continue..."
    return
  fi
  
  local init_status=""
  local init_time=0
  local init_errors=""
  local up_status=""
  local up_time=0
  local up_errors=""
  local seeded_demo="false"
  local deployment_start
  deployment_start=$(date +%s)
  
  # Init step: run deploy init (all logic in install.sh)
  local init_start
  init_start=$(date +%s)
  log "initializing services..."
  local init_stderr
  init_stderr=$(mktemp)
  if run_deploy_init 2>"${init_stderr}"; then
    init_status="success"
    init_time=$(($(date +%s) - init_start))
  else
    init_status="failed"
    init_time=$(($(date +%s) - init_start))
    init_errors=$(tail -5 "${init_stderr}" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -1 || echo "init failed")
    [[ -z "${init_errors}" ]] && init_errors="init failed (see errors above)"
  fi
  rm -f "${init_stderr}"
  
  # Up step: load env, pull images (with detailed log), start units, show unit status
  load_deploy_env
  local up_start
  up_start=$(date +%s)
  log "starting services..."
  
  if [[ "${init_status}" != "success" ]]; then
    up_status="failed"
    up_errors="init did not succeed; skipping pull and start"
    up_time=$(($(date +%s) - up_start))
  else
    if ! deploy_pull_images; then
      up_status="failed"
      if [[ "${APP_ROOTLESS_HOST_FAILED:-}" == "1" ]]; then
        up_errors="this machine cannot run application as a rootless application (see the error above)"
      else
        up_errors="one or more image pulls failed (see above)"
      fi
      up_time=$(($(date +%s) - up_start))
    else
      log "OK: images pulled."
      systemctl --user daemon-reload
      systemctl --user start network-network.service db-volume.service fs-volume.service state-volume.service 2>/dev/null || true
      systemctl --user start db 2>/dev/null || true
      sleep 2
      systemctl --user start state 2>/dev/null || true
      sleep 2
      systemctl --user start fs 2>/dev/null || true
      sleep 3
      # Wait for PostgreSQL to accept connections (up to 2s) before starting be
      local db_name="${APP_POSTGRES_DB:-maindb}"
      local wait_attempts=4
      local wait_i=0
      while [[ ${wait_i} -lt ${wait_attempts} ]]; do
        if podman exec db pg_isready -U postgres -d "${db_name}" 2>/dev/null; then
          break
        fi
        sleep 0.5
        wait_i=$((wait_i + 1))
      done
      if ! systemctl --user start be fe reverse-proxy 2>/dev/null; then
        up_errors="systemctl start be fe reverse-proxy failed"
      fi
      systemctl --user start worker 2>/dev/null || true
      if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
        systemctl --user start pgadmin 2>/dev/null || true
      fi
      # Per-unit start status
      log "Service start status:"
      local units="db state fs be fe reverse-proxy worker"
      [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]] && units="${units} pgadmin"
      local active_count=0
      local unit_count=0
      local failed_units=""
      for u in ${units}; do
        unit_count=$((unit_count + 1))
        local state
        state=$(systemctl --user is-active "${u}" 2>/dev/null || true)
        if [[ "${state}" == "active" ]]; then
          active_count=$((active_count + 1))
          printf "  ${GREEN}%-20s${NC} active\n" "${u}:"
        else
          printf "  ${RED}%-20s${NC} %s\n" "${u}:" "${state}"
          failed_units="${failed_units} ${u}"
        fi
      done
      printf "  ${CYAN}summary:${NC} %d/%d services active\n" "${active_count}" "${unit_count}"
      up_time=$(($(date +%s) - up_start))
      if [[ ${active_count} -lt ${unit_count} ]]; then
        warn "failed units:${failed_units}. check: journalctl --user -u <unit>"
        up_status="failed"
        up_errors="${active_count}/${unit_count} services active; not all containers are up"
      else
        log "OK: started services."
        up_status="success"
        # Capture seed flag from already-loaded env before resetting the file
        local seed_flag="${APP_SEED_DEMO_DATA:-false}"
        seed_flag=$(printf '%s' "${seed_flag}" | tr '[:upper:]' '[:lower:]')
        if [[ "${seed_flag}" == "true" ]]; then
          seeded_demo="true"
        fi
        # Demo data seeding is a one-time action; disable after successful deployment
        if grep -q "^APP_SEED_DEMO_DATA=" "${TARGET_ENV}" 2>/dev/null; then
          sed -i "s|^APP_SEED_DEMO_DATA=.*|APP_SEED_DEMO_DATA=false|" "${TARGET_ENV}"
        fi
        # Allow time for containers to fully register in Podman
        sleep 5
      fi
    fi
  fi
  
  # Install disk space monitor (non-fatal)
  deploy_install_disk_monitor

  local total_time=$(($(date +%s) - deployment_start))
  display_deployment_summary "${init_status}" "${init_time}" "${init_errors}" \
                            "${up_status}" "${up_time}" "${up_errors}" \
                            "${total_time}"
  display_final_summary "${up_status}" "${seeded_demo}"
}

# --- Backup Restore ---

# Set while a restore temp dir exists so EXIT/INT/TERM/HUP can remove it.
_APP_RESTORE_TEMP_DIR=""

_app_restore_trap_cleanup() {
  if [[ -n "${_APP_RESTORE_TEMP_DIR:-}" ]] && [[ -d "${_APP_RESTORE_TEMP_DIR}" ]]; then
    rm -rf "${_APP_RESTORE_TEMP_DIR}" 2>/dev/null || true
  fi
  _APP_RESTORE_TEMP_DIR=""
  rm -rf "${SCRIPT_DIR}"/app-kit-*.tar.gz "${SCRIPT_DIR}"/app-staging-* 2>/dev/null || true
}

# Format bytes to human-readable size string
format_size_bytes() {
  local bytes="$1"
  if [[ ${bytes} -ge 1073741824 ]]; then
    echo "$(echo "scale=1; ${bytes}/1073741824" | bc 2>/dev/null || echo "?") GB"
  elif [[ ${bytes} -ge 1048576 ]]; then
    echo "$(echo "scale=1; ${bytes}/1048576" | bc 2>/dev/null || echo "?") MB"
  elif [[ ${bytes} -ge 1024 ]]; then
    echo "$(echo "scale=1; ${bytes}/1024" | bc 2>/dev/null || echo "?") KB"
  else
    echo "${bytes} B"
  fi
}

# Scan a directory for valid EVI backup files.
# Sets global variables: SCAN_* for use by caller.
# Returns 0 if valid backup found, 1 otherwise.
scan_backup_directory() {
  local scan_dir="$1"

  # Reset scan results
  SCAN_VALID=false
  SCAN_DATA_ARCHIVE=""
  SCAN_REPO_ARCHIVE=""
  SCAN_VERSION=""
  SCAN_ENCRYPTED=false
  SCAN_CREATED=""
  SCAN_HOSTNAME=""
  SCAN_OS=""
  SCAN_ARCH=""
  SCAN_PLATFORM=""

  if [[ ! -d "${scan_dir}" ]]; then
    return 1
  fi

  # Newest data archive by modification time (any supported extension).
  local data_file=""
  data_file=$(ls -1t \
    "${scan_dir}"/app-data-v*.tar.gz.gpg \
    "${scan_dir}"/app-data-v*.tar.zst.gpg \
    "${scan_dir}"/app-data-v*.tar.gz \
    "${scan_dir}"/app-data-v*.tar.zst \
    2>/dev/null | head -1 || true)

  if [[ -z "${data_file}" || ! -f "${data_file}" ]]; then
    return 1
  fi

  SCAN_DATA_ARCHIVE="${data_file}"

  # Detect encryption from extension
  if [[ "${data_file}" == *.gpg ]]; then
    SCAN_ENCRYPTED=true
  fi

  # Extract version from filename: evi-data-v{version}.tar.(gz|zst)[.gpg]
  # Pure parameter expansion avoids GNU-only sed alternation (\|) differences.
  local basename_data="${data_file##*/}"
  local _ver_tmp="${basename_data#app-data-v}"
  _ver_tmp="${_ver_tmp%.gpg}"
  _ver_tmp="${_ver_tmp%.tar.gz}"
  _ver_tmp="${_ver_tmp%.tar.zst}"
  if [[ "${_ver_tmp}" != "${basename_data}" ]]; then
    SCAN_VERSION="${_ver_tmp}"
  fi

  # Parse README for metadata
  local readme="${scan_dir}/README-RESTORE-STEP-BY-STEP.md"
  if [[ -f "${readme}" ]]; then
    SCAN_CREATED=$(grep -m1 '^Created: ' "${readme}" 2>/dev/null | sed 's/^Created:[[:space:]]*//' || echo "")
    SCAN_HOSTNAME=$(grep -m1 '^Hostname: ' "${readme}" 2>/dev/null | sed 's/^Hostname:[[:space:]]*//' || echo "")
    SCAN_OS=$(grep -m1 '^OS: ' "${readme}" 2>/dev/null | sed 's/^OS:[[:space:]]*//' || echo "")
    SCAN_ARCH=$(grep -m1 '^Architecture: ' "${readme}" 2>/dev/null | sed 's/^Architecture:[[:space:]]*//' || echo "")
    # Extract platform from arch field: "x86_64 (linux/amd64)" -> "linux/amd64"
    if [[ -n "${SCAN_ARCH}" ]]; then
      SCAN_PLATFORM=$(echo "${SCAN_ARCH}" | sed -n 's/.*(\([^)]*\)).*/\1/p')
    fi
    if [[ -z "${SCAN_VERSION}" ]]; then
      SCAN_VERSION=$(grep -m1 '^App Version: ' "${readme}" 2>/dev/null | sed 's/^App Version:[[:space:]]*//' || true)
    fi
  fi

  # Kit archive for the same version, else the newest evi-v*.tar.gz in the directory.
  local repo_file=""
  if [[ -n "${SCAN_VERSION}" && -f "${scan_dir}/app-v${SCAN_VERSION}.tar.gz" ]]; then
    repo_file="${scan_dir}/app-v${SCAN_VERSION}.tar.gz"
  else
    repo_file=$(ls -1t "${scan_dir}"/app-v*.tar.gz 2>/dev/null | head -1 || true)
  fi
  SCAN_REPO_ARCHIVE="${repo_file}"

  # Fallback: get creation date from file modification time
  if [[ -z "${SCAN_CREATED}" ]]; then
    SCAN_CREATED=$(stat -c '%y' "${data_file}" 2>/dev/null | cut -d. -f1 || \
                   stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "${data_file}" 2>/dev/null || echo "unknown")
  fi

  SCAN_VALID=true
  return 0
}

# Display scan results for a backup directory
display_scan_results() {
  local scan_dir="$1"
  local data_size=""

  if [[ -n "${SCAN_DATA_ARCHIVE}" ]] && [[ -f "${SCAN_DATA_ARCHIVE}" ]]; then
    local bytes
    bytes=$(stat -c%s "${SCAN_DATA_ARCHIVE}" 2>/dev/null || stat -f%z "${SCAN_DATA_ARCHIVE}" 2>/dev/null || echo "0")
    data_size=$(format_size_bytes "${bytes}")
  fi

  printf "    ${CYAN}backup found in:${NC} %s\n" "${scan_dir}"
  [[ -n "${SCAN_VERSION}" ]] && printf "    ${CYAN}version:${NC}    %s\n" "${SCAN_VERSION}"
  [[ -n "${SCAN_CREATED}" ]] && printf "    ${CYAN}created:${NC}    %s\n" "${SCAN_CREATED}"
  if [[ "${SCAN_ENCRYPTED}" == "true" ]]; then
    printf "    ${CYAN}encrypted:${NC}  ${YELLOW}yes (password required)${NC}\n"
  else
    printf "    ${CYAN}encrypted:${NC}  no\n"
  fi
  [[ -n "${SCAN_PLATFORM}" ]] && printf "    ${CYAN}platform:${NC}   %s\n" "${SCAN_PLATFORM}"
  [[ -n "${SCAN_ARCH}" ]] && [[ -z "${SCAN_PLATFORM}" ]] && printf "    ${CYAN}arch:${NC}       %s\n" "${SCAN_ARCH}"
  [[ -n "${SCAN_OS}" ]] && printf "    ${CYAN}os:${NC}         %s\n" "${SCAN_OS}"
  [[ -n "${SCAN_HOSTNAME}" ]] && printf "    ${CYAN}source:${NC}     %s\n" "${SCAN_HOSTNAME}"
  printf "    ${CYAN}data file:${NC}  %s" "$(basename "${SCAN_DATA_ARCHIVE}")"
  [[ -n "${data_size}" ]] && printf " (%s)" "${data_size}"
  echo ""
  if [[ -n "${SCAN_REPO_ARCHIVE}" ]]; then
    local repo_size=""
    local repo_bytes
    repo_bytes=$(stat -c%s "${SCAN_REPO_ARCHIVE}" 2>/dev/null || stat -f%z "${SCAN_REPO_ARCHIVE}" 2>/dev/null || echo "0")
    repo_size=$(format_size_bytes "${repo_bytes}")
    printf "    ${CYAN}repo file:${NC}  %s (%s)\n" "$(basename "${SCAN_REPO_ARCHIVE}")" "${repo_size}"
  fi
}

# Read KEY=value from an env file. Quotes and a trailing CR are stripped.
_restore_read_env_value() {
  local file="$1" key="$2" line=""
  [[ -f "${file}" ]] || return 0
  line=$(grep "^${key}=" "${file}" 2>/dev/null | head -1 || true)
  line="${line#*=}"
  line="${line%$'\r'}"
  line="${line#\"}"; line="${line%\"}"
  line="${line#\'}"; line="${line%\'}"
  printf '%s' "${line}"
}

# Upsert KEY=value in an env file.
_restore_set_env_key() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

# 0 when this machine already has an evi installation, 1 otherwise.
detect_existing_installation_for_restore() {
  if [[ "${CONFIG_EXISTS}" -eq 1 ]] || [[ -f "${TARGET_ENV}" ]] || [[ -f "${TARGET_SECRETS}" ]]; then
    return 0
  fi
  if command -v podman >/dev/null 2>&1; then
    local c
    for c in db state fs be fe reverse-proxy worker pgadmin; do
      if podman container exists "${c}" 2>/dev/null; then
        return 0
      fi
    done
    local v
    for v in db_data fs_data state_data; do
      if podman volume inspect "${v}" >/dev/null 2>&1; then
        return 0
      fi
    done
  fi
  return 1
}

# Remove one bind-mounted volume directory (db, fs, or state) under a data path.
wipe_bind_volume_dir_for_restore() {
  local base_path="$1" leaf="$2"
  [[ -z "${base_path}" ]] && return 0
  case "${leaf}" in
    db|fs|state) ;;
    *) return 0 ;;
  esac
  local target="${base_path%/}/${leaf}"
  if [[ "${target}" == "/db" || "${target}" == "/fs" || "${target}" == "/state" || "${target}" == "/" ]]; then
    warn "skipping unsafe bind directory cleanup: ${target}"
    return 0
  fi
  if [[ -d "${target}" ]]; then
    podman unshare rm -rf "${target}" 2>/dev/null || rm -rf "${target}" 2>/dev/null || sudo rm -rf "${target}" 2>/dev/null || true
  fi
}

# Stop and remove a previous installation. config/backup is left in place.
wipe_existing_installation_for_restore() {
  local old_db_path="" old_fs_path=""
  local old_jwt_secret="" old_fs_secret="" old_valkey_secret=""
  if [[ -f "${TARGET_ENV}" ]]; then
    old_db_path=$(_restore_read_env_value "${TARGET_ENV}" "APP_DATA_PATH")
    old_fs_path=$(_restore_read_env_value "${TARGET_ENV}" "APP_FS_DATA_PATH")
    old_jwt_secret=$(_restore_read_env_value "${TARGET_ENV}" "APP_JWT_SECRET_NAME")
    old_fs_secret=$(_restore_read_env_value "${TARGET_ENV}" "APP_FS_SECRET_NAME")
    old_valkey_secret=$(_restore_read_env_value "${TARGET_ENV}" "APP_VALKEY_SECRET_NAME")
  fi

  systemctl --user stop reverse-proxy fe be worker fs state db pgadmin db-volume.service fs-volume.service state-volume.service network-network.service network.service 2>/dev/null || true

  if systemctl --user is-active disk-monitor.timer >/dev/null 2>&1 || \
     systemctl --user is-enabled disk-monitor.timer >/dev/null 2>&1; then
    systemctl --user disable --now disk-monitor.timer 2>/dev/null || true
  fi
  if systemctl --user is-active disk-monitor.service >/dev/null 2>&1 || \
     systemctl --user is-enabled disk-monitor.service >/dev/null 2>&1; then
    systemctl --user disable --now disk-monitor.service 2>/dev/null || true
  fi

  local c
  for c in reverse-proxy fe be worker fs state db pgadmin; do
    podman rm -f "${c}" 2>/dev/null || true
  done

  local v
  for v in db_data fs_data state_data caddy_data caddy_config; do
    podman volume rm -f "${v}" 2>/dev/null || true
  done

  if [[ -n "${old_db_path}" ]]; then
    wipe_bind_volume_dir_for_restore "${old_db_path}" "db"
    wipe_bind_volume_dir_for_restore "${old_db_path}" "state"
  fi
  if [[ -n "${old_fs_path}" ]]; then
    wipe_bind_volume_dir_for_restore "${old_fs_path}" "fs"
  fi

  local _secrets="jwt_private_key fs_credentials valkey_password"
  [[ -n "${old_jwt_secret}" ]] && _secrets="${_secrets} ${old_jwt_secret}"
  [[ -n "${old_fs_secret}" ]] && _secrets="${_secrets} ${old_fs_secret}"
  [[ -n "${old_valkey_secret}" ]] && _secrets="${_secrets} ${old_valkey_secret}"
  local _seen=" " _s
  for _s in ${_secrets}; do
    [[ "${_seen}" == *" ${_s} "* ]] && continue
    _seen="${_seen}${_s} "
    podman secret rm "${_s}" >/dev/null 2>&1 || true
  done

  rm -f "${APP_QUADLET_DIR_DEFAULT}"/{db,be,fe,state,worker,fs,reverse-proxy,pgadmin}.container \
        "${APP_QUADLET_DIR_DEFAULT}"/{db,fs,state}.volume \
        "${APP_QUADLET_DIR_DEFAULT}"/network.network \
        "${APP_QUADLET_DIR_DEFAULT}"/network \
        "${APP_QUADLET_DIR_DEFAULT}"/evi-* 2>/dev/null || true

  rm -rf "${CONFIG_DIR}/tls" 2>/dev/null || true
  if [[ -d "${CONFIG_DIR}/state" ]]; then
    podman unshare rm -rf "${CONFIG_DIR}/state" 2>/dev/null || rm -rf "${CONFIG_DIR}/state" 2>/dev/null || sudo rm -rf "${CONFIG_DIR}/state" 2>/dev/null || true
  fi
  rm -rf "${CONFIG_DIR}/updates" 2>/dev/null || true
  rm -f "${TARGET_ENV}" "${TARGET_SECRETS}" "${INSTALL_CONFIG}" 2>/dev/null || true
  CONFIG_EXISTS=0
  INSTALL_CONFIG_EXISTS=0
}

# Copy kit files from an extracted backup archive into SCRIPT_DIR. config/ is not touched.
# Returns 0 on success. Called from `if`, so failures use explicit returns.
_restore_sync_kit_from_archive() {
  local repo_archive="${1:-}"
  [[ -n "${repo_archive}" && -f "${repo_archive}" ]] || return 1
  tar -tzf "${repo_archive}" >/dev/null 2>&1 || return 1
  [[ -n "${_APP_RESTORE_TEMP_DIR:-}" && -d "${_APP_RESTORE_TEMP_DIR}" ]] || return 1

  local stage="${_APP_RESTORE_TEMP_DIR}/repo_kit"
  rm -rf "${stage}" || return 1
  mkdir -p "${stage}" || return 1
  if ! tar -xzf "${repo_archive}" -C "${stage}"; then
    rm -rf "${stage}" 2>/dev/null || true
    return 1
  fi

  local kit_src=""
  if [[ -d "${stage}/app" ]]; then
    kit_src="${stage}/app"
  elif [[ -d "${stage}/deploy-kit" ]]; then
    kit_src="${stage}/deploy-kit"
  else
    kit_src="${stage}"
  fi
  if [[ ! -f "${kit_src}/install.sh" && ! -d "${kit_src}/scripts" && -d "${kit_src}/deploy-kit" ]]; then
    kit_src="${kit_src}/deploy-kit"
  fi
  if [[ ! -f "${kit_src}/install.sh" && ! -d "${kit_src}/scripts" ]]; then
    rm -rf "${stage}" 2>/dev/null || true
    return 1
  fi

  local dir dname f
  for dir in scripts env quadlet-templates reverse-proxy state pgadmin systemd-templates update update-kit; do
    if [[ -d "${kit_src}/${dir}" ]]; then
      rm -rf "${SCRIPT_DIR}/${dir}" || return 1
      cp -a "${kit_src}/${dir}" "${SCRIPT_DIR}/${dir}" || return 1
    fi
  done
  for dir in "${kit_src}"/cockpit-*; do
    [[ -d "${dir}" ]] || continue
    dname=$(basename "${dir}")
    rm -rf "${SCRIPT_DIR}/${dname}" || return 1
    cp -a "${dir}" "${SCRIPT_DIR}/${dname}" || return 1
  done
  for f in package.json prerequisites.conf MANIFEST install.sh; do
    if [[ -f "${kit_src}/${f}" ]]; then
      cp -f "${kit_src}/${f}" "${SCRIPT_DIR}/${f}" || return 1
    fi
  done

  # Release archives keep update-kit and package.json beside deploy-kit/, not inside it.
  local kit_parent=""
  kit_parent="$(dirname "${kit_src}")"
  if [[ "${kit_src}" != "${stage}" ]]; then
    if [[ ! -d "${kit_src}/update-kit" && -d "${kit_parent}/update-kit" ]]; then
      rm -rf "${SCRIPT_DIR}/update-kit" || return 1
      cp -a "${kit_parent}/update-kit" "${SCRIPT_DIR}/update-kit" || return 1
    fi
    if [[ ! -f "${kit_src}/package.json" && -f "${kit_parent}/package.json" ]]; then
      cp -f "${kit_parent}/package.json" "${SCRIPT_DIR}/package.json" || return 1
    fi
  fi

  chmod +x "${SCRIPT_DIR}/install.sh" 2>/dev/null || true
  find "${SCRIPT_DIR}/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
  chmod +x "${SCRIPT_DIR}/update/scripts/"*.sh 2>/dev/null || true
  chmod +x "${SCRIPT_DIR}/update-kit/scripts/"*.sh 2>/dev/null || true

  if [[ -d "${SCRIPT_DIR}/update-kit" ]]; then
    mkdir -p "${SCRIPT_DIR}/update" || return 1
    cp -a "${SCRIPT_DIR}/update-kit/." "${SCRIPT_DIR}/update/" || return 1
    chmod +x "${SCRIPT_DIR}/update/scripts/"*.sh 2>/dev/null || true
  fi

  if [[ ! -f "${SCRIPT_DIR}/prerequisites.conf" || ! -f "${SCRIPTS_DIR}/lib/render-templates.sh" ]]; then
    rm -rf "${stage}" 2>/dev/null || true
    return 1
  fi

  rm -rf "${stage}" 2>/dev/null || true
  _RENDER_TEMPLATES_LOADED=0
  printf "  ${SYM_OK} synchronized deploy kit from backup archive ($(basename "${repo_archive}"))\n"
  return 0
}

# Make SCRIPT_DIR match the backup release. Local repo archive first, GitHub Releases second.
restore_sync_deploy_kit() {
  local backup_version="$1"
  local repo_archive="${2:-}"

  if _restore_sync_kit_from_archive "${repo_archive}"; then
    return 0
  fi
  rm -rf "${_APP_RESTORE_TEMP_DIR:-}/repo_kit" 2>/dev/null || true

  local current_kit_ver=""
  current_kit_ver=$(get_current_kit_version || echo "")
  if [[ -z "${backup_version}" || "${backup_version}" == "unknown" ]]; then
    warn "backup version is unknown; deploy kit files already on disk will be used"
    return 0
  fi
  if [[ "${current_kit_ver}" != "${backup_version}" || ! -f "${SCRIPT_DIR}/prerequisites.conf" || ! -f "${SCRIPTS_DIR}/lib/render-templates.sh" ]]; then
    log "downloading deploy kit for backup version ${backup_version} from GitHub..."
    if download_release_kit_archive "v${backup_version}" "${backup_version}"; then
      if [[ -d "${SCRIPT_DIR}/update-kit" ]]; then
        mkdir -p "${SCRIPT_DIR}/update"
        cp -a "${SCRIPT_DIR}/update-kit/." "${SCRIPT_DIR}/update/"
        chmod +x "${SCRIPT_DIR}/update/scripts/"*.sh 2>/dev/null || true
      fi
      _RENDER_TEMPLATES_LOADED=0
      printf "  ${SYM_OK} synchronized deploy kit v${backup_version} from GitHub\n"
    else
      if [[ ! -f "${SCRIPT_DIR}/prerequisites.conf" || ! -f "${SCRIPTS_DIR}/lib/render-templates.sh" ]]; then
        # A pre-ready-room backup tag (for example 0.27.1) is not in APP_INSTALL_REPO.
        # Fetch a complete kit from that repo so prerequisites and render scripts exist.
        local _fallback_tags="" _fallback_tag="" _fallback_ver="" _fallback_ok=0
        if fetch_github_release_tags _fallback_tags; then
          _fallback_tag=$(pick_first_stable_release_tag "${_fallback_tags}" || true)
          if [[ -z "${_fallback_tag}" ]]; then
            _fallback_tag=$(printf '%s\n' "${_fallback_tags}" | head -n 1)
          fi
          if [[ -n "${_fallback_tag}" ]]; then
            _fallback_ver="${_fallback_tag#[vV]}"
            log "backup version ${backup_version} is not available from ${APP_INSTALL_REPO}; downloading kit ${_fallback_tag}..."
            if download_release_kit_archive "${_fallback_tag}" "${_fallback_ver}"; then
              if [[ -d "${SCRIPT_DIR}/update-kit" ]]; then
                mkdir -p "${SCRIPT_DIR}/update"
                cp -a "${SCRIPT_DIR}/update-kit/." "${SCRIPT_DIR}/update/"
                chmod +x "${SCRIPT_DIR}/update/scripts/"*.sh 2>/dev/null || true
              fi
              _RENDER_TEMPLATES_LOADED=0
              printf "  ${SYM_OK} synchronized deploy kit ${_fallback_tag} from ${APP_INSTALL_REPO}\n"
              _fallback_ok=1
            fi
          fi
        fi
        if [[ "${_fallback_ok}" -ne 1 ]]; then
          err "failed to download deploy kit v${backup_version}"
          err "prerequisites.conf or scripts/lib/render-templates.sh is missing; cannot continue restore"
          return 1
        fi
      else
        warn "could not download deploy kit v${backup_version}; existing kit files on disk will be used"
      fi
    fi
  fi
  return 0
}

# If a restored data path cannot be created on this machine, ask for another disk.
restore_validate_or_pick_data_paths() {
  _restore_path_writable() {
    local base="$1" sub="$2"
    mkdir -p "${base}/${sub}" 2>/dev/null || return 1
    local tf="${base}/${sub}/.app-restore-write-test-$$"
    if touch "${tf}" 2>/dev/null; then
      rm -f "${tf}" 2>/dev/null || true
      return 0
    fi
    return 1
  }

  local raw_db_path="" raw_fs_path=""
  raw_db_path=$(_restore_read_env_value "${TARGET_ENV}" "APP_DATA_PATH")
  raw_fs_path=$(_restore_read_env_value "${TARGET_ENV}" "APP_FS_DATA_PATH")

  if [[ -n "${raw_db_path}" ]] && ! _restore_path_writable "${raw_db_path}" "db"; then
    warn "database data path from backup (${raw_db_path}) is not available or not writable on this server."
    prompt_data_storage_path "restore" "database and state volume storage" "database"
    _restore_set_env_key "${TARGET_ENV}" "APP_DATA_PATH" "${SELECTED_DATA_PATH}"
    export APP_DATA_PATH="${SELECTED_DATA_PATH}"
  fi

  if [[ -n "${raw_fs_path}" ]] && ! _restore_path_writable "${raw_fs_path}" "fs"; then
    warn "file storage (FS) data path from backup (${raw_fs_path}) is not available or not writable on this server."
    prompt_data_storage_path "restore" "file storage (FS) volume storage" "file storage"
    _restore_set_env_key "${TARGET_ENV}" "APP_FS_DATA_PATH" "${SELECTED_DATA_PATH}"
    export APP_FS_DATA_PATH="${SELECTED_DATA_PATH}"
  fi

  export APP_FS_DATA_PATH="${APP_FS_DATA_PATH:-${APP_DATA_PATH:-}}"
}

# Drop dangling images and old tags that are not the ones this restore configured.
# podman rmi is without --force, so an image still used by a container is kept.
restore_prune_unused_images() {
  podman image prune -f >/dev/null 2>&1 || true

  local -a configured=()
  local img
  for img in \
      "${APP_FE_IMAGE:-}" "${APP_BE_IMAGE:-}" "${APP_DB_IMAGE:-}" "${APP_WORKER_IMAGE:-}" \
      "${APP_PROXY_IMAGE:-}" "${APP_STATE_IMAGE:-}" "${APP_FS_IMAGE:-}" "${APP_PGADMIN_IMAGE:-}"; do
    [[ -z "${img}" ]] && continue
    configured+=("${img}")
  done
  if [[ ${#configured[@]} -eq 0 ]]; then
    return 0
  fi

  local listed="" line="" repo="" tag_part="" keep matched
  listed=$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == "<none>:<none>" ]] && continue
    keep=false
    for img in "${configured[@]}"; do
      if [[ "${line}" == "${img}" ]]; then
        keep=true
        break
      fi
    done
    [[ "${keep}" == "true" ]] && continue
    matched=false
    for img in "${configured[@]}"; do
      tag_part="${img##*:}"
      if [[ "${img}" == *:* && "${tag_part}" != */* ]]; then
        repo="${img%:*}"
      else
        repo="${img}"
      fi
      if [[ "${line}" == "${repo}:"* ]]; then
        matched=true
        break
      fi
    done
    [[ "${matched}" == "true" ]] || continue
    podman rmi "${line}" >/dev/null 2>&1 || true
  done <<< "${listed}"
  return 0
}

# Point restored config and kit files at the install repository.
# Older app-v*.tar.gz archives and backups can still name the legacy install repository.
_restore_bind_to_install_repo() {
  local target_repo="${1:-vk74/ready-room}"
  export APP_INSTALL_REPO="${target_repo}"

  local _env_file
  for _env_file in "${TARGET_ENV}" "${TEMPLATE_ENV}"; do
    [[ -f "${_env_file}" ]] || continue
    if grep -q "^APP_INSTALL_REPO=" "${_env_file}"; then
      sed -i "s|^APP_INSTALL_REPO=.*|APP_INSTALL_REPO=${target_repo}|" "${_env_file}"
    else
      printf 'APP_INSTALL_REPO=%s\n' "${target_repo}" >> "${_env_file}"
    fi
  done

  local _script
  for _script in \
    "${SCRIPT_DIR}/install.sh" \
    "${SCRIPT_DIR}/scripts/lib/github-auth.sh" \
    "${SCRIPT_DIR}/update/scripts/lib/github-auth.sh" \
    "${SCRIPT_DIR}/update-kit/scripts/lib/github-auth.sh"
  do
    [[ -f "${_script}" ]] || continue
    sed -i -E "s|APP_INSTALL_REPO=\"\\\$\{APP_INSTALL_REPO:-[^\"]*\}\"|APP_INSTALL_REPO=\"\${APP_INSTALL_REPO:-${target_repo}}\"|g" "${_script}"
  done

  local _pkg="${SCRIPT_DIR}/package.json"
  if [[ -f "${_pkg}" ]] && grep -q '"installRepo"' "${_pkg}"; then
    if command -v jq >/dev/null 2>&1; then
      local _tmp
      _tmp=$(mktemp)
      if jq --arg repo "${target_repo}" '.installRepo = $repo' "${_pkg}" > "${_tmp}"; then
        mv -f "${_tmp}" "${_pkg}"
      else
        rm -f "${_tmp}"
        sed -i -E "s|\"installRepo\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"installRepo\": \"${target_repo}\"|" "${_pkg}"
      fi
    else
      sed -i -E "s|\"installRepo\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"installRepo\": \"${target_repo}\"|" "${_pkg}"
    fi
  fi
}

# Execute the restore from a validated backup.
# Args: data archive, decryption password, optional kit archive, optional scanned version.
execute_restore() {
  local data_archive="$1"
  local password="$2"
  local repo_archive="${3:-}"
  local scan_version="${4:-}"
  local _restore_target_repo="${APP_INSTALL_REPO:-vk74/ready-room}"

  local encrypted=false
  [[ "${data_archive}" == *.gpg ]] && encrypted=true

  local compression="gzip"
  if [[ "${data_archive}" == *.zst* ]]; then
    compression="zstd"
  fi

  local restore_temp
  restore_temp=$(mktemp -d)
  _APP_RESTORE_TEMP_DIR="${restore_temp}"
  trap _app_restore_trap_cleanup EXIT INT TERM HUP

  restore_cleanup() {
    _app_restore_trap_cleanup
    trap - EXIT INT TERM HUP
  }

  local start_time
  start_time=$(date +%s)

  log "starting restore..."
  echo ""

  # Step 1: tools, decrypt, extract. Heavy intermediates are removed as soon as they are consumed.
  local _archive_pkgs=""
  if [[ "${encrypted}" == "true" ]] && ! command -v gpg >/dev/null 2>&1; then
    _archive_pkgs="gnupg"
  fi
  if [[ "${compression}" == "zstd" ]] && ! command -v zstd >/dev/null 2>&1; then
    _archive_pkgs="${_archive_pkgs} zstd"
  fi
  _archive_pkgs="${_archive_pkgs# }"
  if [[ -n "${_archive_pkgs}" ]]; then
    log "installing archive tools: ${_archive_pkgs}..."
    if ! app_apt_get update || ! app_apt_get install -y ${_archive_pkgs}; then
      err "failed to install required archive tools (${_archive_pkgs})"
      restore_cleanup
      return 1
    fi
  fi
  if [[ "${encrypted}" == "true" ]] && ! command -v gpg >/dev/null 2>&1; then
    err "gpg not found (required for encrypted backup)"
    restore_cleanup
    return 1
  fi
  if [[ "${compression}" == "zstd" ]] && ! command -v zstd >/dev/null 2>&1; then
    err "zstd not found (required for this backup archive)"
    restore_cleanup
    return 1
  fi

  local archive_to_extract="${data_archive}"
  local decrypted_file=""
  if [[ "${encrypted}" == "true" ]]; then
    log "decrypting archive..."
    decrypted_file="${restore_temp}/data.tar.gz"
    [[ "${compression}" == "zstd" ]] && decrypted_file="${restore_temp}/data.tar.zst"
    if ! gpg --decrypt --batch --passphrase "${password}" \
         --output "${decrypted_file}" "${data_archive}" 2>/dev/null; then
      err "decryption failed (wrong password?)"
      restore_cleanup
      return 1
    fi
    printf "  ${SYM_OK} decrypted archive\n"
    archive_to_extract="${decrypted_file}"
  fi

  # Step 2: extract
  log "extracting archive..."
  local extract_dir="${restore_temp}/extracted"
  mkdir -p "${extract_dir}"

  local decompress_cmd="gzip -d -c"
  [[ "${compression}" == "zstd" ]] && decompress_cmd="zstd -d -c"

  if ! ${decompress_cmd} "${archive_to_extract}" | tar -xf - -C "${extract_dir}"; then
    err "extraction failed"
    restore_cleanup
    return 2
  fi
  if [[ "${encrypted}" == "true" && -f "${decrypted_file:-}" ]]; then
    rm -f "${decrypted_file}"
  fi
  printf "  ${SYM_OK} extracted archive\n"

  local data_dir="${extract_dir}/app-data"
  if [[ ! -d "${data_dir}" ]]; then
    err "invalid archive structure: app-data directory not found"
    restore_cleanup
    return 2
  fi
  if [[ ! -f "${data_dir}/manifest.json" ]]; then
    err "invalid archive structure: manifest.json not found"
    restore_cleanup
    return 2
  fi

  # Step 3: manifest
  local m_version="" m_created="" m_hostname=""
  m_version=$(grep -o '"app_version"[[:space:]]*:[[:space:]]*"[^"]*"' "${data_dir}/manifest.json" | head -1 | cut -d'"' -f4 || true)
  m_created=$(grep -o '"created_at"[[:space:]]*:[[:space:]]*"[^"]*"' "${data_dir}/manifest.json" | head -1 | cut -d'"' -f4 || true)
  m_hostname=$(grep -o '"hostname"[[:space:]]*:[[:space:]]*"[^"]*"' "${data_dir}/manifest.json" | head -1 | cut -d'"' -f4 || true)
  if [[ -z "${m_version}" ]]; then
    m_version="${scan_version}"
  fi
  if [[ -z "${m_version}" ]]; then
    m_version="unknown"
  fi
  log "backup: application ${m_version}, created ${m_created:-unknown} on ${m_hostname:-unknown}"
  echo ""

  # Step 3b: wipe whatever is already on this machine (before kit sync can overwrite TARGET_ENV). config/backup is kept.
  log "wiping existing installation (if any) before restore..."
  wipe_existing_installation_for_restore
  printf "  ${SYM_OK} cleaned previous installation state\n"
  echo ""

  # Step 4: kit matches the backup, then host prerequisites.
  if ! restore_sync_deploy_kit "${m_version}" "${repo_archive}"; then
    restore_cleanup
    return 1
  fi
  _restore_bind_to_install_repo "${_restore_target_repo}"
  if ! restore_install_prerequisites; then
    err "prerequisite installation failed. cannot proceed with restore."
    restore_cleanup
    return 1
  fi
  if ! require_cmd systemctl; then
    err "systemctl is not available."
    restore_cleanup
    return 1
  fi
  if ! app_ensure_rootless_userns; then
    restore_cleanup
    return 1
  fi
  echo ""

  # Step 5: load images, then delete each tar so /tmp does not hold a second copy.
  log "loading container images..."
  if [[ -d "${data_dir}/images" ]]; then
    local image_count=0
    local image_errors=0
    local image_tar="" img_name=""
    for image_tar in "${data_dir}/images"/*.tar; do
      [[ -f "${image_tar}" ]] || continue
      img_name=$(basename "${image_tar}" .tar)
      if podman load -i "${image_tar}" >/dev/null 2>&1; then
        image_count=$((image_count + 1))
        printf "  ${SYM_OK} loaded ${img_name}\n"
      else
        image_errors=$((image_errors + 1))
        printf "  ${SYM_FAIL} failed to load ${img_name}\n"
      fi
      rm -f "${image_tar}"
    done
    if [[ ${image_errors} -gt 0 ]]; then
      warn "${image_errors} image(s) failed to load"
    fi
    log "loaded ${image_count} container image(s)"
  else
    warn "no container images in backup"
  fi
  echo ""

  # Steps 6-9: env, tls, jwt files, pgadmin. Demo seed stays off so initdb does not
  # load demo rows into the empty database before pg_restore.
  log "restoring environment files..."
  if [[ -d "${data_dir}/env" ]]; then
    mkdir -p "${CONFIG_DIR}"
    cp -f "${data_dir}/env"/*.env "${CONFIG_DIR}/" 2>/dev/null || true
    chmod 600 "${CONFIG_DIR}"/*.env 2>/dev/null || true
    _restore_bind_to_install_repo "${_restore_target_repo}"
    if [[ -f "${TARGET_ENV}" ]] && grep -q "^APP_SEED_DEMO_DATA=" "${TARGET_ENV}"; then
      sed -i 's|^APP_SEED_DEMO_DATA=.*|APP_SEED_DEMO_DATA=false|' "${TARGET_ENV}"
    fi
    load_github_token
    persist_github_token
    if [[ -f "${TARGET_ENV}" && -f "${TARGET_SECRETS}" ]]; then
      CONFIG_EXISTS=1
    fi
    printf "  ${SYM_OK} restored app.env and app.secrets.env\n"
  else
    warn "no environment files in backup"
  fi

  log "restoring tls certificates..."
  if [[ -d "${data_dir}/tls" ]] && [[ -n "$(ls -A "${data_dir}/tls" 2>/dev/null)" ]]; then
    mkdir -p "${TLS_DIR}"
    cp -f "${data_dir}/tls"/* "${TLS_DIR}/" 2>/dev/null || true
    chmod 600 "${TLS_DIR}"/*.pem 2>/dev/null || true
    printf "  ${SYM_OK} restored tls certificates\n"
  else
    printf "  ${SYM_PENDING} no tls certificates in backup\n"
  fi

  log "restoring jwt secrets..."
  local jwt_state_dir="${APP_STATE_DIR_DEFAULT}/secrets"
  mkdir -p "${APP_STATE_DIR_DEFAULT}"
  if [[ -d "${data_dir}/secrets" ]]; then
    mkdir -p "${jwt_state_dir}"
    cp -f "${data_dir}/secrets"/* "${jwt_state_dir}/" 2>/dev/null || true
    chmod 600 "${jwt_state_dir}"/*.pem 2>/dev/null || true
    printf "  ${SYM_OK} restored jwt secrets\n"
  else
    warn "no jwt secrets in backup"
  fi

  if [[ -d "${data_dir}/pgadmin" ]]; then
    log "restoring pgadmin data..."
    local pgadmin_state_dir="${APP_STATE_DIR_DEFAULT}/pgadmin"
    mkdir -p "${pgadmin_state_dir}/data"
    cp -f "${data_dir}/pgadmin"/* "${pgadmin_state_dir}/" 2>/dev/null || true
    if [[ -f "${data_dir}/pgadmin/pgadmin4.db" ]]; then
      cp -f "${data_dir}/pgadmin/pgadmin4.db" "${pgadmin_state_dir}/data/" 2>/dev/null || true
    fi
    printf "  ${SYM_OK} restored pgadmin data\n"
  fi
  echo ""

  # Step 10: load restored env and re-pick data disks that do not exist here.
  log "initializing deployment from restored configuration..."
  if [[ ! -f "${TARGET_ENV}" || ! -f "${TARGET_SECRETS}" ]]; then
    err "restored environment files not found, cannot proceed with deployment"
    restore_cleanup
    return 1
  fi
  load_deploy_env
  restore_validate_or_pick_data_paths

  # Steps 11-13: secrets, templates, firewall, daemon-reload.
  local jwt_key_file="${APP_STATE_DIR:-}/secrets/jwt_private_key.pem"
  if [[ -f "${jwt_key_file}" ]]; then
    deploy_create_or_update_secret_from_file "${APP_JWT_SECRET_NAME:-}" "${jwt_key_file}"
    printf "  ${SYM_OK} registered jwt podman secret\n"
  else
    warn "jwt key not found in backup; preparing it from configuration"
    deploy_prepare_jwt_secret
  fi

  deploy_prepare_valkey_secret
  printf "  ${SYM_OK} registered valkey podman secret\n"

  deploy_prepare_fs_credentials
  printf "  ${SYM_OK} registered fs podman secret\n"

  deploy_ensure_dirs
  deploy_prepare_manual_tls_files 2>/dev/null || true
  check_resources || die "host ram < 2gb (minimum 2gb). deployment stopped."
  deploy_apply_and_render_state_memory
  deploy_render_caddyfile
  deploy_render_quadlets
  printf "  ${SYM_OK} rendered caddyfile and quadlet files\n"

  if command -v ufw >/dev/null 2>&1; then
    ensure_executable
    if "${SCRIPTS_DIR}/host/ufw-ensure-active.sh"; then
      log "restoring firewall rules..."
      sudo ufw allow 80/tcp 2>/dev/null || true
      sudo ufw allow 443/tcp 2>/dev/null || true
      apply_firewall_admin_tools
      printf "  ${SYM_OK} firewall rules restored\n"
    else
      printf "  ${SYM_PENDING} ufw could not be enabled, skipping firewall\n"
    fi
  else
    printf "  ${SYM_PENDING} ufw not installed, skipping firewall\n"
  fi

  systemctl --user daemon-reload
  printf "  ${SYM_OK} systemd daemon reloaded\n"
  echo ""

  # Step 14: volume units first (bind options from the rendered quadlets), then import.
  log "starting network and volume units..."
  systemctl --user start network-network.service db-volume.service fs-volume.service state-volume.service 2>/dev/null || true

  if [[ -f "${data_dir}/fs/fs_data.tar" ]]; then
    log "restoring fs volume..."
    podman volume inspect fs_data >/dev/null 2>&1 || podman volume create fs_data >/dev/null 2>&1 || true
    if podman volume import fs_data "${data_dir}/fs/fs_data.tar" >/dev/null 2>&1; then
      printf "  ${SYM_OK} restored fs volume (fs_data)\n"
    else
      warn "failed to import fs volume (fs_data)"
    fi
    rm -f "${data_dir}/fs/fs_data.tar"
  fi

  if [[ -f "${data_dir}/state/state_data.tar" ]]; then
    log "restoring state volume..."
    podman volume inspect state_data >/dev/null 2>&1 || podman volume create state_data >/dev/null 2>&1 || true
    if podman volume import state_data "${data_dir}/state/state_data.tar" >/dev/null 2>&1; then
      printf "  ${SYM_OK} restored state volume (state_data)\n"
    else
      warn "failed to import state volume (state_data)"
    fi
    rm -f "${data_dir}/state/state_data.tar"
  else
    printf "  ${SYM_PENDING} no state volume archive in backup (starting with clean state_data)\n"
  fi
  echo ""

  # Step 15: start db and wait until the real TCP server is up (not the init-only socket).
  log "starting database..."
  systemctl --user start db 2>/dev/null || true
  local db_name="${APP_POSTGRES_DB:-maindb}"
  local max_wait=90
  local waited=0
  while ! podman exec db pg_isready -h 127.0.0.1 -U postgres -d "${db_name}" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    if [[ ${waited} -ge ${max_wait} ]]; then
      err "database did not become ready within ${max_wait}s"
      restore_cleanup
      return 3
    fi
  done
  printf "  ${SYM_OK} database is ready (waited ${waited}s)\n"

  log "restoring database..."
  if [[ -f "${data_dir}/database/maindb.dump" ]]; then
    if ! podman cp "${data_dir}/database/maindb.dump" "db:/tmp/maindb.dump"; then
      err "failed to copy database dump to container"
      restore_cleanup
      return 3
    fi
    if ! podman exec db pg_restore -U postgres -d "${db_name}" \
         --clean --if-exists --no-owner \
         /tmp/maindb.dump 2>/dev/null; then
      warn "pg_restore completed with warnings (this is usually normal)"
    fi
    podman exec db rm -f /tmp/maindb.dump 2>/dev/null || true
    rm -f "${data_dir}/database/maindb.dump"
    printf "  ${SYM_OK} database restored\n"
  else
    warn "database dump not found in backup"
  fi
  echo ""

  # Step 16: state and fs after their volumes are imported, then the rest of the stack.
  log "starting remaining services..."
  systemctl --user start state 2>/dev/null || true
  sleep 2
  systemctl --user start fs 2>/dev/null || true
  sleep 3
  systemctl --user start be fe reverse-proxy worker 2>/dev/null || true
  if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
    systemctl --user start pgadmin 2>/dev/null || true
  fi
  deploy_install_disk_monitor
  sleep 5

  local units="db state fs be fe reverse-proxy worker"
  [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]] && units="${units} pgadmin"
  local active_count=0
  local unit_count=0
  local u="" state=""
  for u in ${units}; do
    unit_count=$((unit_count + 1))
    state=$(systemctl --user is-active "${u}" 2>/dev/null || true)
    if [[ "${state}" == "active" ]]; then
      active_count=$((active_count + 1))
      printf "  ${SYM_OK} ${GREEN}%-20s${NC} active\n" "${u}:"
    else
      printf "  ${SYM_FAIL} ${RED}%-20s${NC} %s\n" "${u}:" "${state}"
    fi
  done
  echo ""

  # Step 17: flags, cleanup, summary, optional deletion of the archives just restored.
  CONFIG_EXISTS=1
  rm -f "${INSTALL_CONFIG}" 2>/dev/null || true
  INSTALL_CONFIG_EXISTS=0
  restore_cleanup

  if [[ ${active_count} -eq ${unit_count} ]]; then
    log "removing unused container images..."
    restore_prune_unused_images || true
  fi

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  local minutes=$((duration / 60))
  local seconds=$((duration % 60))

  echo "+--------------------------------------------------------------+"
  printf "|           ${CYAN}restore summary${NC}                              |\n"
  echo "+--------------------------------------------------------------+"
  echo ""
  if [[ ${active_count} -eq ${unit_count} ]]; then
    printf "  ${SYM_OK} ${GREEN}RESTORE COMPLETED SUCCESSFULLY${NC}\n"
  else
    printf "  ${SYM_WARN} ${YELLOW}RESTORE COMPLETED WITH ISSUES${NC}\n"
  fi
  printf "  services: %d/%d active\n" "${active_count}" "${unit_count}"
  printf "  time: %d min %d sec\n" "${minutes}" "${seconds}"
  echo ""

  local domain="${APP_DOMAIN:-}"
  if [[ -n "${domain}" ]]; then
    printf "  your application is available at ${GREEN}https://${domain}${NC}\n"
    printf "  cockpit admin at https://${domain}:9090\n"
  fi
  echo ""

  if [[ ${active_count} -eq ${unit_count} ]]; then
    local -a _backup_files=()
    [[ -f "${data_archive}" ]] && _backup_files+=("${data_archive}")
    [[ -n "${repo_archive}" && -f "${repo_archive}" ]] && _backup_files+=("${repo_archive}")
    local _readme=""
    _readme="$(dirname "${data_archive}")/README-RESTORE-STEP-BY-STEP.md"
    [[ -f "${_readme}" ]] && _backup_files+=("${_readme}")
    if [[ ${#_backup_files[@]} -gt 0 ]]; then
      local _total=0 _f="" _bytes=0
      echo "backup files from this restore:"
      for _f in "${_backup_files[@]}"; do
        _bytes=$(stat -c%s "${_f}" 2>/dev/null || stat -f%z "${_f}" 2>/dev/null || echo "0")
        _total=$((_total + _bytes))
        printf "   - %s (%s)\n" "${_f}" "$(format_size_bytes "${_bytes}")"
      done
      echo ""
      if confirm "delete these backup files to free disk space ($(format_size_bytes "${_total}"))?" "n"; then
        rm -f "${_backup_files[@]}"
        info "backup files deleted (freed $(format_size_bytes "${_total}"))."
      fi
      echo ""
    fi
  fi

  read -r -p "press enter to continue..."
}

# Install system prerequisites and cockpit panels for the restore flow.
# Sources prerequisites.conf from the kit, installs packages if missing,
# then installs cockpit panels. Skips installation if all prerequisites are
# already present. Returns 0 on success, 1 on failure.
restore_install_prerequisites() {
  local prereq_conf="${SCRIPT_DIR}/prerequisites.conf"
  if [[ ! -f "${prereq_conf}" ]]; then
    err "prerequisites.conf not found: ${prereq_conf}"
    err "ensure you extracted the correct application kit archive (app-v*.tar.gz) before running restore."
    return 1
  fi
  # shellcheck source=/dev/null
  source "${prereq_conf}"
  APP_PREREQ_APT_PACKAGES="${APP_PREREQ_APT_PACKAGES:-}"
  APP_PREREQ_COCKPIT_PACKAGES="${APP_PREREQ_COCKPIT_PACKAGES:-}"
  APP_PREREQ_COCKPIT_FILES_PACKAGE="${APP_PREREQ_COCKPIT_FILES_PACKAGE:-}"
  APP_PREREQ_COCKPIT_FILES_RELEASE="${APP_PREREQ_COCKPIT_FILES_RELEASE:-}"
  APP_PREREQ_COCKPIT_FILES_DEB_URL="${APP_PREREQ_COCKPIT_FILES_DEB_URL:-}"
  APP_PREREQ_UNPRIVILEGED_PORT_START="${APP_PREREQ_UNPRIVILEGED_PORT_START:-}"
  APP_PREREQ_UFW_PORTS="${APP_PREREQ_UFW_PORTS:-}"
  if [[ -z "${APP_PREREQ_APT_PACKAGES// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_APT_PACKAGES is empty"
    return 1
  fi
  if [[ -z "${APP_PREREQ_COCKPIT_PACKAGES// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_COCKPIT_PACKAGES is empty"
    return 1
  fi
  if [[ -z "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" ]] || ! [[ "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" =~ ^[0-9]+$ ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_UNPRIVILEGED_PORT_START must be a non-negative integer (${prereq_conf})"
    return 1
  fi
  if [[ -z "${APP_PREREQ_UFW_PORTS// }" ]]; then
    err "invalid prerequisites.conf: APP_PREREQ_UFW_PORTS is empty (${prereq_conf})"
    return 1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_USE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_USE is empty"
    return 1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_FILE_SIZE// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_FILE_SIZE is empty"
    return 1
  fi
  if [[ -z "${PREREQ_JOURNAL_MAX_RETENTION// }" ]]; then
    err "invalid prerequisites.conf: PREREQ_JOURNAL_MAX_RETENTION is empty"
    return 1
  fi

  # Check if all prerequisite packages are already installed
  local needs_install=false
  local _pkg
  for _pkg in ${APP_PREREQ_APT_PACKAGES:-} ${APP_PREREQ_COCKPIT_PACKAGES:-}; do
    if ! dpkg -s "${_pkg}" >/dev/null 2>&1; then
      needs_install=true
      break
    fi
  done

  if [[ "${needs_install}" == "false" ]]; then
    info "system prerequisites already installed."

    local _port_start
    _port_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo "1024")
    if ! [[ "${_port_start}" =~ ^[0-9]+$ ]] || [[ "${_port_start}" -gt "${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" ]]; then
      log "configuring rootless ports (unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-})..."
      sudo rm -f /etc/sysctl.d/99-evi-rootless.conf 2>/dev/null || true
      echo "net.ipv4.ip_unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" | \
        sudo tee /etc/sysctl.d/99-app-rootless.conf >/dev/null
      sudo sysctl -p /etc/sysctl.d/99-app-rootless.conf >/dev/null 2>&1 || true
    fi

    if ! loginctl show-user "$(whoami)" -p Linger 2>/dev/null | grep -q "yes"; then
      log "enabling systemd linger for $(whoami)..."
      sudo loginctl enable-linger "$(whoami)"
    fi

    if command -v ufw >/dev/null 2>&1; then
      ensure_executable
      if "${SCRIPTS_DIR}/host/ufw-ensure-active.sh"; then
        log "opening application ports in ufw..."
        local port
        for port in ${APP_PREREQ_UFW_PORTS:-}; do
          sudo ufw allow "${port}" 2>/dev/null || true
        done
      else
        warn "ufw could not be enabled; skipping application firewall ports."
      fi
    fi

    if ! systemctl is-active --quiet cockpit.socket 2>/dev/null; then
      sudo systemctl enable --now cockpit.socket 2>/dev/null || true
    fi
    if ! systemctl --user is-active --quiet podman.socket 2>/dev/null; then
      systemctl --user enable --now podman.socket 2>/dev/null || true
    fi
  else
    log "--- installing system prerequisites (requires sudo) ---"

    if ! sudo -v 2>/dev/null; then
      err "sudo access is required to install prerequisites."
      err "ensure your user has sudo privileges and try again."
      return 1
    fi

    log "installing packages: ${APP_PREREQ_APT_PACKAGES:-}..."
    if ! app_apt_get update; then
      err "apt-get update failed. check your internet connection."
      return 1
    fi
    if ! app_apt_get install -y ${APP_PREREQ_APT_PACKAGES:-}; then
      err "failed to install packages: ${APP_PREREQ_APT_PACKAGES:-}"
      return 1
    fi

    log "configuring rootless ports (unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-})..."
    sudo rm -f /etc/sysctl.d/99-evi-rootless.conf 2>/dev/null || true
    echo "net.ipv4.ip_unprivileged_port_start=${APP_PREREQ_UNPRIVILEGED_PORT_START:-}" | \
      sudo tee /etc/sysctl.d/99-app-rootless.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-app-rootless.conf >/dev/null 2>&1 || true

    if ! loginctl show-user "$(whoami)" -p Linger 2>/dev/null | grep -q "yes"; then
      log "enabling systemd linger for $(whoami)..."
      sudo loginctl enable-linger "$(whoami)"
    fi

    if command -v ufw >/dev/null 2>&1; then
      ensure_executable
      if "${SCRIPTS_DIR}/host/ufw-ensure-active.sh"; then
        log "opening application ports in ufw..."
        local port
        for port in ${APP_PREREQ_UFW_PORTS:-}; do
          sudo ufw allow "${port}" 2>/dev/null || true
        done
      else
        warn "ufw could not be enabled; skipping application firewall ports."
      fi
    fi

    log "installing cockpit: ${APP_PREREQ_COCKPIT_PACKAGES:-}..."
    if ! app_apt_get install -y ${APP_PREREQ_COCKPIT_PACKAGES:-}; then
      err "failed to install cockpit packages: ${APP_PREREQ_COCKPIT_PACKAGES:-}"
      return 1
    fi
    sudo systemctl enable --now cockpit.socket 2>/dev/null || true

    systemctl --user enable --now podman.socket 2>/dev/null || true
    info "system prerequisites installed."
  fi

  install_cockpit_files_best_effort --rewrite-origin

  if ! install_journald_limits; then
    err "failed to configure journald limits"
    return 1
  fi

  if ! install_sshd_jail; then
    err "failed to configure sshd jail (fail2ban)"
    return 1
  fi

  # Install cockpit panels from kit
  log "--- installing cockpit panels ---"

  install_cockpit_app_admin_panel \
    "cockpit: app admin tools panel installed." \
    "cockpit-app-admin not found; skipping."

  # Deploy update kit so update/ matches the restored kit version (overwrite stale files).
  local _update_kit_src=""
  if [[ -d "${SCRIPT_DIR}/update-kit" ]]; then
    _update_kit_src="${SCRIPT_DIR}/update-kit"
  elif [[ -d "${SCRIPT_DIR}/../update-kit" ]]; then
    _update_kit_src="${SCRIPT_DIR}/../update-kit"
  fi
  if [[ -n "${_update_kit_src}" ]]; then
    mkdir -p "${SCRIPT_DIR}/update"
    cp -a "${_update_kit_src}/." "${SCRIPT_DIR}/update/"
    if [[ -d "${SCRIPT_DIR}/update/scripts" ]]; then
      chmod +x "${SCRIPT_DIR}/update/scripts/"*.sh 2>/dev/null || true
    fi
    info "update kit deployed."
  fi

  info "cockpit panels installed."
  return 0
}

# Interactive restore from backup (called from main menu option 4)
restore_from_backup() {
  echo ""
  log "=== restore application from full backup ==="
  echo ""

  # The backup version is not known until the operator picks an archive, and a fresh
  # README bootstrap does not have prerequisites.conf yet. Prerequisites run inside
  # execute_restore after the kit has been synchronized to that version.

  # Scan two candidate locations automatically:
  #   1. config/backup (default backup dir — covers existing installation)
  #   2. parent dir ~/   (covers new server — user copied archives to home dir)
  local default_backup_dir="${CONFIG_DIR}/backup"
  local parent_dir
  parent_dir="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd)"

  local default_valid=false
  local parent_valid=false
  local d_data="" d_encrypted="" d_repo="" d_ver=""
  local p_data="" p_encrypted="" p_repo="" p_ver=""

  # Pre-scan default backup directory and keep its results before the next scan overwrites SCAN_*.
  if scan_backup_directory "${default_backup_dir}"; then
    default_valid=true
    d_data="${SCAN_DATA_ARCHIVE}"
    d_encrypted="${SCAN_ENCRYPTED}"
    d_repo="${SCAN_REPO_ARCHIVE}"
    d_ver="${SCAN_VERSION}"
  fi

  # Pre-scan parent directory (only if different from default_backup_dir)
  if [[ "${parent_dir}" != "${default_backup_dir}" ]]; then
    if scan_backup_directory "${parent_dir}"; then
      parent_valid=true
      p_data="${SCAN_DATA_ARCHIVE}"
      p_encrypted="${SCAN_ENCRYPTED}"
      p_repo="${SCAN_REPO_ARCHIVE}"
      p_ver="${SCAN_VERSION}"
    fi
  fi

  # Build menu
  echo "where are the backup files located?"
  echo ""

  local option_num=0

  if [[ "${default_valid}" == "true" ]]; then
    option_num=$((option_num + 1))
    local default_label
    default_label="$(realpath --relative-to="${HOME}" "${default_backup_dir}" 2>/dev/null || echo "${default_backup_dir}")"
    echo "  ${option_num}) use backup found in ~/${default_label}:"
    echo ""
    scan_backup_directory "${default_backup_dir}" || true
    display_scan_results "${default_backup_dir}"
    echo ""
  fi

  if [[ "${parent_valid}" == "true" ]]; then
    option_num=$((option_num + 1))
    echo "  ${option_num}) use backup found in parent directory (~/  — new server):"
    echo ""
    scan_backup_directory "${parent_dir}" || true
    display_scan_results "${parent_dir}"
    echo ""
  fi

  option_num=$((option_num + 1))
  local custom_option_num="${option_num}"
  echo "  ${custom_option_num}) enter path to backup directory"
  echo ""
  echo "  0) back to main menu"
  echo ""

  local max_option="${option_num}"
  local choice=""
  while [[ -z "${choice}" ]]; do
    read -r -p "select [0-${max_option}]: " choice
    case "${choice}" in
      0) return ;;
      [1-9])
        if [[ "${choice}" -gt "${max_option}" ]]; then
          warn "invalid option"
          choice=""
        fi
        ;;
      *) warn "invalid option"; choice="" ;;
    esac
  done

  local selected_data_archive=""
  local selected_encrypted=false
  local selected_repo_archive=""
  local selected_version=""

  # Map numeric choice to the correct auto-found backup or custom path.
  # Options are numbered in order: default_backup_dir (if valid), parent_dir (if valid), then custom.
  local default_option_num=0
  local parent_option_num=0
  local _n=0
  if [[ "${default_valid}" == "true" ]]; then
    _n=$((_n + 1)); default_option_num=${_n}
  fi
  if [[ "${parent_valid}" == "true" ]]; then
    _n=$((_n + 1)); parent_option_num=${_n}
  fi

  if [[ "${default_option_num}" -gt 0 ]] && [[ "${choice}" == "${default_option_num}" ]]; then
    selected_data_archive="${d_data}"
    selected_encrypted="${d_encrypted}"
    selected_repo_archive="${d_repo}"
    selected_version="${d_ver}"
  elif [[ "${parent_option_num}" -gt 0 ]] && [[ "${choice}" == "${parent_option_num}" ]]; then
    selected_data_archive="${p_data}"
    selected_encrypted="${p_encrypted}"
    selected_repo_archive="${p_repo}"
    selected_version="${p_ver}"
  else
    # Custom path
    echo ""
    local custom_path=""
    while true; do
      read -r -p "enter path to backup directory: " custom_path
      if [[ -z "${custom_path}" ]]; then
        warn "path cannot be empty"
        continue
      fi
      # Expand ~ to home directory
      custom_path="${custom_path/#\~/$HOME}"
      if [[ ! -d "${custom_path}" ]]; then
        warn "directory not found: ${custom_path}"
        continue
      fi
      if scan_backup_directory "${custom_path}"; then
        echo ""
        display_scan_results "${custom_path}"
        echo ""
        selected_data_archive="${SCAN_DATA_ARCHIVE}"
        selected_encrypted="${SCAN_ENCRYPTED}"
        selected_repo_archive="${SCAN_REPO_ARCHIVE}"
        selected_version="${SCAN_VERSION}"
        break
      else
        err "no valid backup found in ${custom_path}"
        echo "  expected files: app-data-v*.tar.gz[.gpg]"
        if ! confirm "try another path?" "y"; then
          return
        fi
      fi
    done
  fi

  if [[ -z "${selected_data_archive}" ]]; then
    err "no backup archive selected"
    read -r -p "press enter to continue..."
    return
  fi

  # Get password if encrypted
  local restore_password=""
  if [[ "${selected_encrypted}" == "true" ]]; then
    echo ""
    read -r -s -p "enter backup decryption password: " restore_password
    echo ""
    if [[ -z "${restore_password}" ]]; then
      err "password cannot be empty for encrypted backup"
      read -r -p "press enter to continue..."
      return
    fi
  fi

  echo ""
  if detect_existing_installation_for_restore; then
    box_top
    panel_row_center "!!! ALERT: EXISTING APPLICATION INSTALLATION DETECTED !!!" "${RED}${BOLD}"
    panel_row_center "CURRENT INSTALLATION WILL BE COMPLETELY WIPED" "${NEON_AMBER}${BOLD}"
    box_bottom
    echo ""
    printf "  ${RED}${BOLD}ALL CURRENT APPLICATION DATA AND CONTAINERS WILL BE PERMANENTLY ERASED:${NC}\n"
    echo "   - all running application containers and systemd services will be stopped and removed"
    echo "   - current database (db_data), file storage (fs_data), and state store (state_data) volumes will be wiped"
    echo "   - current configuration (app.env, app.secrets.env), TLS certificates, and secrets will be replaced"
    echo "   - deploy kit files will be synchronized to match the backup version"
    echo ""
  else
    box_top
    panel_row_center "RESTORE WILL CONFIGURE AND DEPLOY THE APPLICATION" "${NEON_AMBER}${BOLD}"
    panel_row_center "FROM THE SELECTED BACKUP" "${NEON_AMBER}${BOLD}"
    box_bottom
    echo ""
    printf "  ${NEON_AMBER}${BOLD}no existing application installation was detected on this machine.${NC}\n"
    echo "   - restore will configure and deploy application from the selected backup"
    echo "   - deploy kit files will be synchronized to match the backup version"
    echo "   - container images, database, file storage, and state will be loaded from the backup"
    echo ""
  fi
  if ! confirm "proceed with restore?"; then
    log "restore cancelled."
    read -r -p "press enter to continue..."
    return
  fi

  echo ""
  execute_restore "${selected_data_archive}" "${restore_password}" "${selected_repo_archive}" "${selected_version}"
}

# Full uninstall: delegates to deploy/scripts/uninstall.sh (containers, volumes, secrets, images, state with sudo, config, quadlets, cockpit panels, UFW by rule number, sysctl, apt packages).
# On success (exit code 2 from uninstall.sh), exit install.sh so user can paste the two final commands (cd ~ and rm -rf ~/evi) from the hint.
run_uninstall() {
  ensure_executable
  local uninstall_ret=0
  "${SCRIPTS_DIR}/host/uninstall.sh" || uninstall_ret=$?
  if [[ "${uninstall_ret}" -eq 2 ]]; then
    exit 0
  fi
}

# --- Main Menu ---
main_menu() {
  ensure_executable
  while true; do
    echo ""
    banner_app

    if [[ "${CONFIG_EXISTS}" -eq 1 && "${INSTALL_CONFIG_EXISTS}" -eq 0 ]]; then
      # --- Existing installation (finished deploy; no .install-config) ---
      echo ""
      printf "${NEON_AMBER}${BOLD}%s${NC}\n" "application configuration already exists. you are modifying an existing configuration."
      printf "current status: application configured to work at ${NEON_CYAN}%s${NC}\n" "$(get_app_main_url_for_menu)"
      echo ""
      echo "  0) exit"
      echo ""
      printf "  ${DIM}${NEON_CYAN}--- manage deployment ---${NC}\n"
      echo "  1) check & repair prerequisites (requires sudo)"
      echo "  2) reconfigure containers environment (rootless)"
      echo "  3) apply configuration and restart containers (rootless)"
      echo ""
      printf "  ${DIM}${NEON_CYAN}--- restore installation from backup ---${NC}\n"
      echo "  4) restore application from full backup"
      echo ""
      printf "  ${DIM}${NEON_CYAN}--- uninstall ---${NC}\n"
      echo "  5) uninstall application (remove all containers, data volume and components)"
      echo ""
      read -r -p "${ARROW}select [0-5]: " opt
      case $opt in
        0) log "bye!"; exit 0 ;;
        1) bash "${SCRIPTS_DIR}/host/check-prerequisites.sh" "${SCRIPT_DIR}" ;;
        2) menu_env_config ;;
        3)
          read -r -p "${ARROW}Start deployment now? [y/N]: " deploy_confirm
          if [[ "${deploy_confirm}" == [yY] ]]; then
            do_apply_restart
          else
            log "deployment cancelled."
          fi
          ;;
        4) restore_from_backup ;;
        5) run_uninstall ;;
        *) warn "invalid option" ;;
      esac
    else
      # --- Fresh 2-step flow, including an unfinished deploy (.install-config still present) ---
      echo ""
      if [[ "${INSTALL_CONFIG_EXISTS}" -eq 1 ]]; then
        printf "${NEON_AMBER}%s${NC}\n" "saved configuration is present. deploy was interrupted (for example by a reboot). choose 2 to continue."
        echo ""
      fi
      echo "  0) exit"
      echo ""
      printf "  ${DIM}${NEON_CYAN}--- new deployment (2 steps) ---${NC}\n"
      echo "  1) environment configuration"
      echo "  2) deploy application"
      echo ""
      printf "  ${DIM}${NEON_CYAN}--- restore installation from backup ---${NC}\n"
      echo "  3) restore application from full backup"
      echo ""
      printf "  ${DIM}${NEON_CYAN}--- uninstall ---${NC}\n"
      echo "  4) uninstall application (remove all containers, data volume and components)"
      echo ""
      read -r -p "${ARROW}select [0-4]: " opt
      case $opt in
        0) log "bye!"; exit 0 ;;
        1) collect_config ;;
        2) deploy_full ;;
        3) restore_from_backup ;;
        4) run_uninstall ;;
        *) warn "invalid option" ;;
      esac
    fi
  done
}

# Non-interactive apply + restart entry point for Cockpit Container Environment panel.
# Runs run_deploy_init (render templates, update Podman secrets) and restarts all EVI systemd units.
# Does not call do_apply_restart to avoid interactive read prompts.
if [[ "${1:-}" == "__cockpit_apply_restart" ]]; then
  ensure_executable
  if [[ ! -f "${TARGET_ENV}" || ! -f "${TARGET_SECRETS}" ]]; then
    err "configuration files missing (${TARGET_ENV} or ${TARGET_SECRETS})."
    exit 1
  fi
  tls_status=$(check_tls_status)
  if [[ "${tls_status}" == "missing_certs" ]]; then
    err "tls certificates missing. generate them before applying."
    exit 1
  fi
  if ! run_deploy_init; then
    err "init failed."
    exit 1
  fi
  load_deploy_env
  systemctl --user daemon-reload
  systemctl --user restart db state fs be fe reverse-proxy worker 2>/dev/null || true
  if [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]]; then
    systemctl --user restart pgadmin 2>/dev/null || true
  fi
  _db_name="${APP_POSTGRES_DB:-maindb}"
  for _i in 1 2 3 4 5 6 7 8; do
    podman exec db pg_isready -U postgres -d "${_db_name}" 2>/dev/null && break
    sleep 0.5
  done
  _units="db state fs be fe reverse-proxy worker"
  [[ "${APP_PGADMIN_ENABLED:-false}" == "true" ]] && _units="${_units} pgadmin"
  _all_ok=1
  for _u in ${_units}; do
    _svc_state=$(systemctl --user is-active "${_u}" 2>/dev/null || true)
    if [[ "${_svc_state}" == "active" ]]; then
      printf "  ${GREEN}[✓]${NC} %-24s active\n" "${_u}"
    else
      printf "  ${RED}[✗]${NC} %-24s %s\n" "${_u}" "${_svc_state}"
      _all_ok=0
    fi
  done
  if [[ "${_all_ok}" -eq 1 ]]; then
    info "configuration applied, all containers active."
    exit 0
  else
    err "Some containers did not start. Check the output above."
    exit 1
  fi
fi

# Non-interactive entry point: resume deploy_full() after exec re-launch with version-matched installer.
# The kit archive was already downloaded by the previous (latest) installer; this continuation runs
# all deployment phases (prerequisites, cockpit, config, containers) with the correct version's code.
if [[ "${1:-}" == "__continue_deploy" ]]; then
  ensure_executable
  load_github_token
  if [[ ! -f "${INSTALL_CONFIG}" ]]; then
    err "no saved configuration (.install-config) found."
    exit 1
  fi
  _APP_CONTINUE_DEPLOY=1
  deploy_full
  exit $?
fi

# Start: interactive wizard without apt; host packages are installed in deploy_full (option 2).
# No eager token gate — a real GitHub call below (release list / kit download / GHCR pull)
# fails with a clear message if a key turns out to be needed and none is available.
load_github_token
main_menu
