#!/bin/bash
# sandbox entrypoint — starts tailscaled, dockerd, then sshd (foreground).
#
# Order matters: tailscaled and dockerd run in the background; sshd execs as
# PID 1 so the container lives as long as sshd does. Neither tailscaled nor
# dockerd failing stops the container — both are logged, and sshd still
# comes up so the box stays reachable for debugging.
#
# Idempotency / persistence rules (the whole point of this box):
#   - authorized_keys is seeded ONLY when the tester-ssh volume has none
#     yet (from TESTER_AUTHORIZED_KEY, your public key — safe to commit,
#     it is public). After the first boot the volume wins; re-seeding never
#     overwrites keys that are already there.
#   - `tailscale up` runs only when already logged in (state on the volume)
#     or when TS_AUTHKEY is set. Without either, tailscaled still runs and
#     the container works — it just is not on the tailnet yet.
#   - dockerd storage lives on the docker-data volume, so inner images and
#     containers survive a container recreate.
set -eu
# pipefail is a bashism this script relies on for the wait loops.
set -o pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

# --- Directories that may be fresh mounts on first boot ----------------------
mkdir -p /var/lib/tailscale /var/lib/docker /var/run/tailscale /run/tailscale \
    /var/run/sshd /home/tester/.ssh /home/tester/work /var/log

# --- tester SSH key: volume wins, seed only if the volume is empty ---------
if [ ! -s /home/tester/.ssh/authorized_keys ]; then
    if [ -n "${TESTER_AUTHORIZED_KEY:-}" ]; then
        printf '%s\n' "$TESTER_AUTHORIZED_KEY" > /home/tester/.ssh/authorized_keys
        log "seeded authorized_keys from TESTER_AUTHORIZED_KEY"
    else
        log "WARNING: no authorized_keys found — SSH key login as tester will fail"
        log "         set TESTER_AUTHORIZED_KEY (your public key) in .env, then recreate"
    fi
fi
chown --recursive tester:tester /home/tester/.ssh /home/tester/work
chmod 700 /home/tester/.ssh
[ -f /home/tester/.ssh/authorized_keys ] && chmod 600 /home/tester/.ssh/authorized_keys

# --- SSH host keys: generated once, then persisted by the ssh-host-keys volume
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    ssh-keygen -A
    log "generated SSH host keys (persisted in ssh-host-keys volume)"
fi

# --- Tailscale ---------------------------------------------------------------
# tailscaled needs /dev/net/tun (compose mounts it) and NET_ADMIN — both are
# provided by privileged: true in compose.yml. If the device is missing the
# daemon still starts but cannot create the tunnel; that is logged, not fatal.
tailscaled \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    --port="${TS_PORT:-41641}" \
    >/var/log/tailscaled.log 2>&1 &
TAILSCALED_PID=$!

# Wait for the control socket, then decide whether to bring the node up.
for _ in $(seq 1 30); do
    [ -S /var/run/tailscale/tailscaled.sock ] && break
    sleep 1
done

if [ -S /var/run/tailscale/tailscaled.sock ]; then
    if tailscale ip -4 >/dev/null 2>&1; then
        log "Tailscale: already on tailnet, IP $(tailscale ip -4 | head -n 1)"
    elif [ -n "${TS_AUTHKEY:-}" ]; then
        # Build the `up` args as an array so values with spaces stay intact.
        UP_ARGS=(up --authkey="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-sandbox}")
        [ "${TS_ACCEPT_ROUTES:-false}" = "true" ] && UP_ARGS+=(--accept-routes)
        [ "${TS_SSH:-false}" = "true" ] && UP_ARGS+=(--ssh)
        [ -n "${TS_ADVERTISE_ROUTES:-}" ] && UP_ARGS+=(--advertise-routes="$TS_ADVERTISE_ROUTES")
        if tailscale "${UP_ARGS[@]}" >>/var/log/tailscaled.log 2>&1; then
            log "Tailscale: joined tailnet as ${TS_HOSTNAME:-sandbox}, IP $(tailscale ip -4 | head -n 1)"
        else
            log "WARNING: 'tailscale up' failed — see /var/log/tailscaled.log; container continues without tailnet"
        fi
    else
        log "WARNING: Tailscale not logged in and TS_AUTHKEY is not set — tailscaled is running, run 'tailscale up' inside or set TS_AUTHKEY and recreate"
    fi
else
    log "WARNING: tailscaled socket never appeared — Tailscale is down, container continues; see /var/log/tailscaled.log"
fi

# --- Docker-in-Docker --------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
    dockerd --config-file=/etc/docker/daemon.json \
        >/var/log/dockerd.log 2>&1 &
    DOCKERD_PID=$!
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
    if docker info >/dev/null 2>&1; then
        log "Docker: dockerd is up ($(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo 'version unknown'))"
    else
        log "WARNING: dockerd did not come up in 60s — see /var/log/dockerd.log; sshd still starts"
    fi
else
    log "Docker: already up (socket answered before dockerd was started)"
fi

# --- SSH, foreground as PID 1 -----------------------------------------------
# Tailscaled/dockerd were started by this shell (PID 1); after exec they are
# re-parented to sshd and die with the container. `docker stop` sends SIGTERM
# to sshd and the container exits.
log "starting sshd (tester only, key-only, root login disabled)"
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
