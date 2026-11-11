# EVI README Version 0.27.5-beta

Before install, read the [Prepare your VM for deployment](prepare-your-vm-for-evi-deployment.md) guide — host requirements, disk layout, and filesystem recommendations.

Optionally read the [Installation reference](installation-reference.md) — installer settings, secrets, tips.

## Installation

Copy the whole block of commands below and paste it in your Linux server terminal, hit enter and follow the installation wizard.

```bash
sudo apt-get update && sudo apt-get install -y curl \
  && mkdir -p "$HOME/app/scripts/lib" && cd "$HOME/app" \
  && for f in install.sh scripts/lib/github-auth.sh; do
       echo "downloading ${f}..."
       url="https://api.github.com/repos/vk74/ready-room/contents/deploy-kit/${f}?ref=main"
       curl -sS --fail --connect-timeout 15 --max-time 60 -H "Accept: application/vnd.github.raw" -o "${f}" "${url}" \
         || curl -sS --fail --connect-timeout 15 --max-time 60 -H "Accept: application/vnd.github.raw" -H "Authorization: Bearer ${APP_GITHUB_TOKEN:-}" -o "${f}" "${url}" \
         || { echo "error: could not download ${f}. If the repository is private, export APP_GITHUB_TOKEN and retry." >&2; exit 1; }
     done \
  && test -s install.sh && test -s scripts/lib/github-auth.sh \
  && chmod +x install.sh \
  && ./install.sh
```
