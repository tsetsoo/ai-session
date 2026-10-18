#!/usr/bin/env bash
set -euo pipefail
# Run on the Pi as root (or via sudo).
# Usage: sudo ./bootstrap.sh

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
# /opt/todo, /opt/todo/releases, and the updater script are root-owned;
# only /opt/todo/data (the sqlite db, owned by the todo.service user) is pi:pi.
install -d -o root -g root -m 0755 /opt/todo /opt/todo/releases
install -d -o pi -g pi -m 0755 /opt/todo/data
install -o root -g root -m 0755 "$REPO_DIR/todo-update.sh" /opt/todo/todo-update.sh
install -m 0644 "$REPO_DIR/todo.service" /etc/systemd/system/todo.service
install -m 0644 "$REPO_DIR/todo-update.service" /etc/systemd/system/todo-update.service
install -m 0644 "$REPO_DIR/todo-update.timer" /etc/systemd/system/todo-update.timer
systemctl daemon-reload
# First pull (may fail if pi-latest not published yet — OK)
/opt/todo/todo-update.sh || echo "first pull deferred until pi-latest exists"
systemctl enable --now todo.service || true
systemctl enable --now todo-update.timer
systemctl status todo.service --no-pager || true
systemctl list-timers todo-update.timer --no-pager

# Push notifications (optional; see docs/superpowers/specs/2026-10-17-push-notifications-design.md).
# Not done here: the APNs key is a secret the owner writes by hand. From the Mac, with the
# key downloaded from the Apple Developer portal (Keys → APNs):
#   ssh pi@<pi> 'umask 077; cat > /opt/todo/data/apns-key.p8' < AuthKey_<KEYID>.p8
#   ssh pi@<pi> 'umask 077; cat > /opt/todo/data/apns.env'   # APNS_KEY_PATH=/opt/todo/data/apns-key.p8,
#                                                            # APNS_KEY_ID=<KEYID>, APNS_TEAM_ID=233QTK6KCL
#   sudo mkdir -p /etc/systemd/system/todo.service.d
#   printf '[Service]\nEnvironmentFile=-/opt/todo/data/apns.env\n' | sudo tee /etc/systemd/system/todo.service.d/apns.conf
#   sudo systemctl daemon-reload && sudo systemctl restart todo
# Without them the server runs with push "not configured" (GET /api/push/status).
