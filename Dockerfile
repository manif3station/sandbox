# sandbox — Docker-in-Docker testing ground on Ubuntu, with Tailscale + SSH.
# One of three main files in this repo: Dockerfile, compose.yml, .env.
# Build assets the Dockerfile copies in live in docker/ (see below).
#
# Base: Ubuntu 24.04 LTS (Noble). Deliberately the stock Ubuntu archive for
# Docker (docker.io + compose v2 plugin + buildx) — no third-party Docker
# repo to keep track of. Tailscale is the one exception: it is not in the
# Ubuntu archive, so it comes from Tailscale's own apt repo (their
# documented install method).
#
# What runs inside, in order (see docker/entrypoint.sh):
#   1. tailscaled  — joins the tailnet when TS_AUTHKEY is set, or when a
#                    previous login is already stored in the tailscale-state
#                    volume. Never blocks the container from starting.
#   2. dockerd     — Docker-in-Docker, storage on the docker-data volume.
#   3. sshd        — foreground (PID 1). Key-only login as user `tester`.
#
# Persistence is by named volumes in compose.yml, not by anything in this
# image: /var/lib/docker, /var/lib/tailscale, /home/tester/.ssh, /etc/ssh,
# /home/tester/work. Anything installed with apt inside a running container
# is LOST on recreate — add system packages here and rebuild instead.
#
# Security notes — read before running this anywhere you would not run a
# root shell:
#   - The box runs privileged (dockerd manages iptables, tailscaled needs
#     /dev/net/tun). A privileged container is effectively root on the host.
#   - `tester` has passwordless sudo by design; the account itself has no
#     password (locked) and root login is disabled (see docker/sshd_config).
#   - Never commit a real TS_AUTHKEY in .env — pass it in your shell.

FROM ubuntu:24.04

# Version of this sandbox, from .env via compose build args (VERSION=...).
# Stamped on the image so `docker inspect` can tell builds apart.
ARG VERSION=latest
LABEL org.opencontainers.image.version="$VERSION"

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/London \
    LANG=en_GB.UTF-8 \
    LANGUAGE=en_GB:en \
    LC_ALL=en_GB.UTF-8

# --- Base tools + Docker-in-Docker + SSH -----------------------------------
# iptables + iproute2: dockerd needs them for its bridge/NAT networking.
# kmod: modprobe, used by dockerd's storage/network setup when available.
# openssh-server: sshd. sudo: tester is a sudoer (see below).
# The rest are the standard testing-ground kit: git, build tools, python,
# curl/wget, jq, network diagnostics, an editor.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        tzdata \
        locales \
        sudo \
        openssh-server \
        docker.io \
        docker-buildx \
        docker-compose-v2 \
        iptables \
        iproute2 \
        kmod \
        procps \
        git \
        vim \
        jq \
        wget \
        htop \
        iputils-ping \
        dnsutils \
        net-tools \
        build-essential \
        python3 \
    && locale-gen en_GB.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# --- Tailscale (official apt repo — the documented install method) ---------
# If your network intercepts TLS with a private CA (corporate proxy), pass
# it as a build secret and it is trusted just for this build, nothing more:
#   podman build --secret id=custom-ca,src=/path/to/ca.pem .
#   docker build --secret id=custom-ca,src=/path/to/ca.pem .
# Without the secret this is a no-op and the stock Ubuntu CA store is used.
RUN --mount=type=secret,id=custom-ca,required=false \
    if [ -f /run/secrets/custom-ca ]; then cp /run/secrets/custom-ca /usr/local/share/ca-certificates/custom-ca.crt && update-ca-certificates; fi \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        | tee /etc/apt/sources.list.d/tailscale.list >/dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

# --- User: tester, uid 1000, sudoer, member of the docker group ------------
# docker.io creates the `docker` group, so this must come after that install.
# No password is set on the account (locked): login is by SSH key only.
RUN useradd --create-home --uid 1000 --shell /bin/bash tester \
    && usermod --append --groups sudo,docker tester \
    && printf '%s\n' 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester \
    && chmod 0440 /etc/sudoers.d/tester \
    && passwd --lock tester \
    && mkdir -p /home/tester/.ssh /home/tester/work /var/run/sshd /run/tailscale \
    && chown --recursive tester:tester /home/tester \
    && chmod 700 /home/tester/.ssh

# --- Docker daemon defaults: overlay2, capped json-file logs ---------------
# Stated explicitly so a rebuild does not silently change storage drivers,
# and a chatty inner container cannot fill the docker-data volume with logs.
COPY docker/daemon.json /etc/docker/daemon.json

# --- SSH hardening: key-only, tester only, root login disabled -------------
COPY docker/sshd_config /etc/ssh/sshd_config
RUN chmod 644 /etc/ssh/sshd_config \
    && sshd -t

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 22

# sshd (foreground) is PID 1; dockerd + tailscaled run as its children.
# Fails the container's health if sshd config is bad or dockerd is down.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD sshd -t && docker info >/dev/null 2>&1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
