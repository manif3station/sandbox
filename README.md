# sandbox

One Ubuntu box for testing, runnable on any machine on your Tailscale network. SSH in as `tester`, run Docker inside it, and everything that matters survives the container being recreated.

## What you get

| Requirement | How it works |
|---|---|
| Docker inside, images + containers survive recreate | `dockerd` runs in the box; its data lives on the `sandbox-docker-data` volume (`/var/lib/docker`) |
| Testing ground | Ubuntu 24.04 LTS, Docker + Compose v2 + buildx, git, build tools, Python, SSH, Tailscale |
| Joins Tailscale, login survives recreate | `tailscaled` runs in the box; its login state lives on the `sandbox-tailscale-state` volume (`/var/lib/tailscale`) |
| Runs on any machine on the tailnet, SSH in for testing | SSH on port 22 (also published as `2222` on the host); host keys + tester keys live on volumes |
| Normal user, not root | `tester`, uid 1000, sudoer (`NOPASSWD`), SSH key-only. Root login is disabled in `sshd_config` |

## Quick start

```sh
# Put your SSH public key in .env as TESTER_AUTHORIZED_KEY (it is public,
# so it is safe to commit), and export a reusable Tailscale auth key:
export TS_AUTHKEY=tskey-auth-...
docker compose up -d --build
ssh -i ~/.ssh/id_ed25519 -p 2222 tester@localhost
# or, once it is on the tailnet: ssh tester@<tailscale-ip>
```

Create the auth key at <https://login.tailscale.com/admin/settings/keys> → Generate auth key. Use a **reusable** key: a single-use key cannot re-join if the `tailscale-state` volume is ever lost. First boot is the only time the key is needed — after that the stored login on the volume is enough, and the key is not needed again.

`VERSION` in `.env` (currently `1.0.0`) tags the image as `sandbox:<VERSION>` and is stamped on it as a label. Bump it when you change the `Dockerfile` or `compose.yml` in a way worth telling apart — `docker compose up -d --build` then builds and runs the new version.

## Everyday commands

```sh
docker compose up -d --build   # (re)create the box; volumes keep everything
docker compose down            # stop it; volumes are kept
docker compose logs -f sandbox # entrypoint + service logs
docker compose exec --user tester sandbox bash   # shell inside, as tester
```

`docker compose down -v` is the factory reset: it **destroys all five volumes** — Docker images, Tailscale login, SSH keys, and `~/work`. That is the only way to lose the persisted state.

## What persists, what does not

Persisted (named volumes — `docker volume ls | grep sandbox`):

| Volume | Mounted at | Holds |
|---|---|---|
| `sandbox-docker-data` | `/var/lib/docker` | inner images, containers, inner volumes |
| `sandbox-tailscale-state` | `/var/lib/tailscale` | Tailscale login + node key |
| `sandbox-tester-ssh` | `/home/tester/.ssh` | `authorized_keys` |
| `sandbox-ssh-host-keys` | `/etc/ssh` | SSH host keys (fingerprint stays stable) |
| `sandbox-work` | `/home/tester/work` | your files — keep test work here |

Not persisted: anything else in the container filesystem. An `apt install` inside a running box vanishes on recreate — add system packages to the `Dockerfile` and rebuild instead.

## Inside the box, as tester

```sh
docker info                 # inner Docker daemon
docker run --rm hello-world # prove it works
docker compose version      # Compose v2 plugin is installed
sudo apt update             # tester can sudo without a password
tailscale status            # tailnet status; tailscale ip -4 for its IP
```

## Multi-machine notes

- Set a different `TS_HOSTNAME` per host (`sandbox-mac`, `sandbox-win`, …), or two boxes will fight over the same tailnet name.
- The published `2222:22` port is for the host / LAN. Over Tailscale, SSH goes straight to port 22 on the tailnet IP — no mapping needed.
- `restart: unless-stopped` means the box comes back up when the host reboots.

## Security notes

Read these before running it somewhere that matters.

- `privileged: true` is required — Docker-in-Docker manages iptables and its bridge, and Tailscale needs `/dev/net/tun`. A privileged container is effectively root on the host. Only run this on machines you trust, and only for testing.
- `tester` has passwordless sudo by design. The account itself has no password (locked) — login is by SSH key only, and root login is disabled (`PermitRootLogin no`).
- `.env` is tracked in the repo with placeholder values only — never put a real `TS_AUTHKEY` in the committed copy. Pass it in your shell (`export TS_AUTHKEY=...`) before `docker compose up`; compose prefers shell env over `.env`. Never put an SSH *private* key in this repo.
- Tailscale SSH (`TS_SSH=true`) is off by default. Turning it on adds Tailscale's own SSH on top of OpenSSH; it uses tailnet ACLs, not `authorized_keys`.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Ubuntu 24.04, Docker, Tailscale, `tester` (uid 1000), SSH hardening |
| `compose.yml` | service, privileged mode, `/dev/net/tun`, all five volumes |
| `.env` | `VERSION`, `TS_AUTHKEY`, `TS_HOSTNAME`, `TESTER_AUTHORIZED_KEY`, `TZ` — tracked, placeholder values only |
| `docker/entrypoint.sh` | starts tailscaled → dockerd → sshd; seeds `authorized_keys` only on first boot |
| `docker/sshd_config` | key-only, `tester` only, no root |
| `docker/daemon.json` | overlay2, capped json-file logs |

## Troubleshooting

- **SSH says "Permission denied (publickey)"** — the box has no key for you yet. Check `docker compose exec sandbox ls -l /home/tester/.ssh/` and that `TESTER_AUTHORIZED_KEY` in `.env` (or your shell) held your real public key *before* the first boot. If the volume already exists with an empty key file, add the key with `docker compose exec sandbox sh -c 'cat >> /home/tester/.ssh/authorized_keys'` or wipe the volume (`down -v`, then fix the key and `up` again).
- **Not on the tailnet** — `docker compose exec sandbox tailscale status`. If `TS_AUTHKEY` was empty at boot, run `tailscale up` inside the box, or set the key in your shell and recreate.
- **Inner `docker` fails** — check `docker compose exec sandbox tail -n 50 /var/log/dockerd.log`. The box must be `privileged: true`; without it dockerd cannot set up networking.
- **"port 2222 is already allocated"** — another service uses 2222 on the host. Change the left side of `"2222:22"` in `compose.yml`.
- **Build fails at the Tailscale step with a certificate error** — your network intercepts TLS with a private CA (corporate proxy). Pass the CA as a build secret and the build trusts it just for that step: `podman build --secret id=custom-ca,src=/path/to/ca.pem .` (or `docker build --secret ...`). Without the secret the stock Ubuntu CA store is used.

## Verified status

Not yet verified end to end. The image build is still running on the test machine (see the certificate note above). What is verified so far: the Dockerfile's package list installs cleanly on Ubuntu 24.04 (Docker 29.1.3, Compose v2 2.40.3, buildx 0.30.1), the compose file parses, and the optional `custom-ca` build secret works both with a secret passed and without one. Still to check once the build lands: `dockerd` inside the box, a `hello-world` image and an inner container surviving a full recreate, SSH as `tester` (uid 1000, sudo works, root login refused), and a stable host-key fingerprint. Tailscale: `tailscaled` starts and its state directory persists, but a live tailnet join was **not** verified here — no auth key was available on the test machine. Give the box a real `TS_AUTHKEY` once and confirm with `tailscale status` inside it.
