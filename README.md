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
# Put your SSH public key in config/docker/sandbox/.env as
# TESTER_AUTHORIZED_KEY (it is public, so it is safe to commit), and export
# a reusable Tailscale auth key:
export TS_AUTHKEY=tskey-auth-...
docker compose -f config/docker/sandbox/compose.yml up -d --build
ssh -i ~/.ssh/id_ed25519 -p 2222 tester@localhost
# or, once it is on the tailnet: ssh tester@<tailscale-ip>
```

Create the auth key at <https://login.tailscale.com/admin/settings/keys> → Generate auth key. Use a **reusable** key: a single-use key cannot re-join if the `tailscale-state` volume is ever lost. First boot is the only time the key is needed — after that the stored login on the volume is enough, and the key is not needed again.

`VERSION` in `config/docker/sandbox/.env` (currently `1.0.0`) tags the image as `sandbox:<VERSION>` and is stamped on it as a label. Bump it when you change the `Dockerfile` or `compose.yml` in a way worth telling apart — `docker compose -f config/docker/sandbox/compose.yml up -d --build` then builds and runs the new version.

## Everyday commands

```sh
docker compose -f config/docker/sandbox/compose.yml up -d --build   # (re)create the box; volumes keep everything
docker compose -f config/docker/sandbox/compose.yml down            # stop it; volumes are kept
docker compose -f config/docker/sandbox/compose.yml logs -f sandbox # entrypoint + service logs
docker compose -f config/docker/sandbox/compose.yml exec --user tester sandbox bash   # shell inside, as tester
```

`docker compose -f config/docker/sandbox/compose.yml down -v` is the factory reset: it **destroys all five volumes** — Docker images, Tailscale login, SSH keys, and `~/work`. That is the only way to lose the persisted state.

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
- `tester` has passwordless sudo by design. The account has no usable password — the shadow entry is `*`, so no password can ever match. It is deliberately *not* locked (`passwd --lock` would make sshd refuse even key login, since this box runs with `UsePAM no`). Login is by SSH key only, and root login is disabled (`PermitRootLogin no`).
- `config/docker/sandbox/.env` is tracked in the repo with placeholder values only — never put a real `TS_AUTHKEY` in the committed copy. Pass it in your shell (`export TS_AUTHKEY=...`) before `docker compose up`; compose prefers shell env over `.env`. Never put an SSH *private* key in this repo.
- Tailscale SSH (`TS_SSH=true`) is off by default. Turning it on adds Tailscale's own SSH on top of OpenSSH; it uses tailnet ACLs, not `authorized_keys`.

## Files

| File | Purpose |
|---|---|
| `config/docker/sandbox/Dockerfile` | Ubuntu 24.04, Docker, Tailscale, `tester` (uid 1000), SSH hardening |
| `config/docker/sandbox/compose.yml` | service, privileged mode, `init: true`, `/dev/net/tun`, all five volumes |
| `config/docker/sandbox/.env` | `VERSION`, `TS_AUTHKEY`, `TS_HOSTNAME`, `TESTER_AUTHORIZED_KEY`, `TZ` — tracked, placeholder values only |
| `config/docker/sandbox/docker/entrypoint.sh` | starts tailscaled → dockerd → sshd; seeds `authorized_keys` only on first boot |
| `config/docker/sandbox/docker/sshd_config` | key-only, `tester` only, no root |
| `config/docker/sandbox/docker/daemon.json` | overlay2, capped json-file logs |

## Troubleshooting

- **SSH says "Permission denied (publickey)"** — the box has no key for you yet. Check `docker compose -f config/docker/sandbox/compose.yml exec sandbox ls -l /home/tester/.ssh/` and that `TESTER_AUTHORIZED_KEY` in `config/docker/sandbox/.env` (or your shell) held your real public key *before* the first boot. If the volume already exists with an empty key file, add the key with `docker compose -f config/docker/sandbox/compose.yml exec sandbox sh -c 'cat >> /home/tester/.ssh/authorized_keys'` or wipe the volume (`down -v`, then fix the key and `up` again).
- **Not on the tailnet** — `docker compose -f config/docker/sandbox/compose.yml exec sandbox tailscale status`. If `TS_AUTHKEY` was empty at boot, run `tailscale up` inside the box, or set the key in your shell and recreate. If the key is bad or expired, the entrypoint's `tailscale up` gives up after 120 seconds (it cannot stall the box) and the box still comes up — check `tail /var/log/tailscaled.log` for the control plane's answer; a `400 Bad Request` on `/machine/register` means the key itself was rejected.
- **Inner `docker` fails** — check `docker compose -f config/docker/sandbox/compose.yml exec sandbox tail -n 50 /var/log/dockerd.log`. The box must be `privileged: true`; without it dockerd cannot set up networking.
- **"port 2222 is already allocated"** — another service uses 2222 on the host. Change the left side of `"2222:22"` in `config/docker/sandbox/compose.yml`.
- **Build fails at the Tailscale step with a certificate error** — your network intercepts TLS with a private CA (corporate proxy). Pass the CA as a build secret and the build trusts it just for that step: `podman build --secret id=custom-ca,src=/path/to/ca.pem .` (or `docker build --secret ...`). Without the secret the stock Ubuntu CA store is used.

## Verified status

Tested 14 Nov 2026 on a Podman VM. Docker 29.1.3 was later installed on the same host: the daemon runs (`iptables: false`, `bridge: none`, `storage-driver: vfs`, runtime `crun`) and `docker compose config` renders, but containers still cannot start under Docker there — the VM denies its network sandbox and its session keyring — so Podman remains the only runtime that can run a container on that host. The test script is not in this repo (`~/workspace/sandbox-test/run-tests.sh` on the test machine); 18 of 26 checks pass, and every failure is traced to the test environment, not the product.

Proven:

- Image builds clean (16/16 steps), `VERSION` label `1.0.0`, no secrets baked in.
- SSH as `tester` (uid 1000, sudo + docker groups) with a key; root login, password login and a wrong key are all refused.
- Tester reads and writes `/home/tester/work` and `.ssh`.
- `dockerd` 29.1.3 (overlay2) starts and answers as tester; `docker load`, `docker images` and `docker create` work as tester.
- After a recreate with no key supplied: SSH still works, host keys unchanged, work file intact.
- A bad `TS_AUTHKEY` cannot stall the box: `tailscale up` is time-boxed to 120s, then the entrypoint warns and sshd still comes up.

Not provable on that VM (needs a real Docker host):

- `docker run` as tester: the VM strips `NET_ADMIN`/`NET_RAW` from containers (PID 1 `CapEff` has neither), so `dockerd` cannot create its iptables rules, and its read-only cgroupfs blocks starting a container (`mkdir /sys/fs/cgroup/docker: read-only file system`). `privileged: true` in `config/docker/sandbox/compose.yml` grants both on a real host.
- `tailscaled` in normal (tun) mode, for the same `NET_ADMIN` reason. Userspace networking (`TS_TUN=userspace-networking`) works and reaches the control plane, but the auth key supplied for the test was rejected by it (`400 Bad Request` on `/machine/register` — invalid or expired key).

Still to check on a real machine with a fresh reusable auth key: `docker run --rm hello-world` as tester, and `ssh tester@<tailscale-ip>` over the tailnet.
