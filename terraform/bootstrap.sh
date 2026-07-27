#!/bin/sh
#
# Lightsail user_data — runs ONCE, at instance creation.
#
# POSIX sh ONLY (G4): Lightsail's init wrapper inlines this script and runs it
# under dash, ignoring the shebang. A single bashism aborts the whole file —
# `set -o pipefail` did exactly that on the first build of the host.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ WARNING (spec G4): user_data is ForceNew on aws_lightsail_instance.       │
# │ Editing this file destroys and recreates the host on the next apply,      │
# │ taking every database on it. It must therefore contain the ABSOLUTE       │
# │ MINIMUM needed for Ansible to open a connection — and then never change.  │
# │                                                                          │
# │ Anything you are tempted to add here belongs in an Ansible role (AD-7,    │
# │ A6). Package installs, Docker, Postgres, Caddy: all of it is Ansible's.   │
# └──────────────────────────────────────────────────────────────────────────┘
#
# The SSH key is NOT installed here — Lightsail does that from key_pair_name.
#
set -eux

export DEBIAN_FRONTEND=noninteractive

apt-get update -y

# Ubuntu 24.04 ships python3, so this is normally a no-op. It is here because
# Ansible's raw-module fallback is unpleasant, and because a future blueprint
# revision dropping python3 would be discovered at the worst possible moment —
# and by then this file cannot be edited without rebuilding the host.
apt-get install -y --no-install-recommends python3

# Marker so `make check-ssh` / Phase 2 can prove user_data actually ran rather
# than inferring it from a successful ping.
echo "bootstrap complete: $(date -u +%FT%TZ)" > /var/log/bootstrap-done
