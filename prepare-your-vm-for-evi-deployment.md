# Prepare your VM for evi deployment

## Host requirements

Recommended specs for your physical server or virtual machine to run evi:

**RAM :** 2Gb for test environment, 4Gb or more for production


**CPU:** 1 core for test, 2 cores or more depending on workload. installation script wil pull arm64 or amd64 app builds depending on your platfom



**Network:** 1 NIC 

**SSD** ~ 1.5 Gb of free space for containers environment + additional space as needed for DB and FS volumes.

**OS:** EVI was tested on Ubuntu 24.04 and 26.04 and is compatible with any distributions of Debian family. The README paste installs `curl` (via `sudo apt-get update && sudo apt-get install -y curl`); you do not need to preinstall it. Podman, Cockpit, UFW, fail2ban, and the rest of the evi host stack are installed only when you start Deploy (option 2) in the installer. fail2ban also arrives later via update/repair from `prerequisites.conf`. It is not installed by the README paste or Configure. On a public IP, finish Deploy promptly so SSH is not left without an autoban jail. README still installs curl only.

## Deployment

You can install EVI on virtual machine or physical server. 

1. Deploy Linux OS on your server. You do not need to confirm `curl` first — the README paste installs it. OS updates and evi host prerequisites are **not** applied until you confirm Deploy (option 2) — they are not installed by the README paste or by Configure (option 1).
2. Optional step to improve disk IOPS and overall app performance: use separate physical drives for DB and FS volumes and choose them during installation.
3. Copy and run installation block of commands from README.md

## Additional information to consider

### Filesystems 

* **ext4**
  Best for: general use, standard deployments.
  Features: universal support, stable, simple setup.
  Limitations: no Docker --storage-opt size= enforcement with overlay2.

* **XFS**
  Best for: large files, high throughput, quota enforcement.
  Features: project quotas (pquota), requires ftype=1 for OverlayFS.
  Limitations: complex quota setup.

* **BTRFS**
  Best for: snapshots, advanced storage features, thin provisioning.
  Features: native snapshots, COW, compression, checksums, qgroup quotas.
  Limitations: higher overhead, complexity, requires balancing; quota support only with BTRFS storage driver.

### Container volume quotas

XFS: project quotas (pquota) — full Docker/Podman enforcement supported.
ext4: project quotas (prjquota) — manual quotas only, no quota enforcement.
BTRFS: qgroup quotas — only with Btrfs storage driver (not overlay2).

Note: deploy DB and FS volumes on separate disks of your host server. This will limit space available for DB and FS.

## Containerization basics

### What is Containerization?

Containerization on Linux is an OS-level virtualization method that packages an application and its dependencies into isolated, portable containers. Unlike virtual machines, containers share the host OS kernel and provide process-level isolation. Each container has its own process tree, network stack, and filesystem.

### Linux Kernel Container Features

* Namespaces — isolate processes, network, filesystem, users, IPC, and hostname.
* Control Groups (cgroups) — limit and monitor CPU, memory, disk I/O, network resources.
* Union Filesystems — layer-based image storage (overlay, aufs).

In the cockpit you can set individual CPU and RAM limits for consumption by each container.

### Virtualization requirements:

* Virtualization needed at host level (L0) to run VM.
* Guest VM (L1) runs Linux OS.
* Containers inside VM still don't require virtualization.
* Nested virtualization is not needed for containers.

## Known problems (host platforms)

evi install expects a Debian-family guest with systemd, `sudo`, and **rootless Podman** (user namespaces + `newuidmap`). That is a full Linux VM or a physical host — not a nested container unless the hoster explicitly allows user namespaces.

### Usually fine

Same path as a local Ubuntu/Debian VM: you have your own kernel, `/etc/subuid` + `/etc/subgid`, and `podman unshare` works.

* KVM / QEMU (including Proxmox **VM**, not CT)
* VMware, Hyper-V
* OpenStack Nova instances
* Azure VM, Azure Stack IaaS
* AWS EC2, GCP Compute Engine, typical KVM VPS (Hetzner, DigitalOcean, and similar)

The installer does not contain cloud-specific code. If the guest is a normal Debian VM, `install.sh` does not care who sold the hypervisor.

### Problems we have seen or expect

* **Proxmox LXC / LXD (unprivileged CT)**  
  Two separate blockers for rootless Podman:  
  1. `newuidmap: write to uid_map failed: Operation not permitted` — CT needs **nesting** + **keyctl**, and `/etc/subuid` must sit **inside 0–65535**. Debian’s default `100000:65536` is outside an unprivileged CT map; `install.sh` 1.43 remaps that user to `10000:55536` (other users untouched).  
  2. `/dev/net/tun` missing — pasta/slirp cannot create a network. Ask the hoster for **TUN**, then reboot. There is no guest-only workaround and no rootful fallback in the installer.  
  `sysctl --system` may print Permission denied on LXC; that is treated as non-fatal. A failed userns or missing TUN is fatal.

* **OpenVZ / Virtuozzo** and many cheap “VPS” products that are a container, not a VM  
  User namespaces are often disabled. Rootless Podman cannot pull or start. There is no guest-side workaround. Use a KVM-style VM or ask the hoster for user namespaces.

* **Windows, FreeBSD, Alpine without systemd**  
  `install.sh` uses `apt-get`, systemd user units (quadlets), and `loginctl enable-linger`. These hosts are out of scope.

If deploy does not bring every expected container up, the installer must **not** print “evi is online”. Fix the host (or switch to a real VM) and run deploy again.
