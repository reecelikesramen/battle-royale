#!/usr/bin/env bash
#
# GCE startup script. Runs on first boot and on every reboot. Idempotent.
# Template variables (interpolated by terraform templatefile): bucket,
# project_id, service_unit_body, agent_unit_body, refresh_script,
# manifest_pub_b64. Do NOT use literal $${...} forms in comments — they
# expand multi-line values into the rendered script and break bash parsing.

set -euo pipefail

BUCKET='${bucket}'
PROJECT_ID='${project_id}'

# ── Packages ───────────────────────────────────────────────────────────────
# Probe every required tool individually. Gating only on `jq` left us on a
# VM where jq was present but unzip wasn't, so refresh.sh blew up at the
# release-extract step with `unzip: command not found`.
export DEBIAN_FRONTEND=noninteractive
missing=()
for cmd in curl jq unzip openssl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ $${#missing[@]} -gt 0 ]; then
  apt-get update -qq
  apt-get install -y -qq "$${missing[@]}"
fi

# ── User + dirs ────────────────────────────────────────────────────────────
id gameserver >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --home-dir /opt/battle-royale gameserver

install -d -o gameserver -g gameserver -m 0755 /opt/battle-royale
install -d -o root -g root -m 0755 /etc/battle-royale

# ── Drop static files ──────────────────────────────────────────────────────
cat > /etc/battle-royale/meta.env <<EOF
BUCKET=$BUCKET
PROJECT_ID=$PROJECT_ID
EOF

cat > /etc/battle-royale/manifest_pub.ed25519.b64 <<'B64EOF'
${manifest_pub_b64}
B64EOF
base64 -d /etc/battle-royale/manifest_pub.ed25519.b64 > /etc/battle-royale/manifest_pub.ed25519
chmod 0644 /etc/battle-royale/manifest_pub.ed25519
rm -f /etc/battle-royale/manifest_pub.ed25519.b64

cat > /opt/battle-royale/refresh.sh <<'REFRESH_EOF'
${refresh_script}
REFRESH_EOF
chmod 0755 /opt/battle-royale/refresh.sh

cat > /etc/systemd/system/battle-royale-server.service <<'UNIT_EOF'
${service_unit_body}
UNIT_EOF

cat > /etc/systemd/system/battle-royale-agent.service <<'AGENT_UNIT_EOF'
${agent_unit_body}
AGENT_UNIT_EOF

# ── Install server-agent (idle watcher + release watcher) ─────────────────
curl -fsSL "https://storage.googleapis.com/$BUCKET/server-agent/latest/server-agent" \
  -o /opt/battle-royale/server-agent
chmod 0755 /opt/battle-royale/server-agent
chown gameserver:gameserver /opt/battle-royale/server-agent

# ── First pull of binaries before the service starts ──────────────────────
sudo -u gameserver -E /opt/battle-royale/refresh.sh || true

systemctl daemon-reload
# Enable both first (no --now) so failures don't block each other; then start
# them. A crash-looping server service used to make `enable --now` exit
# non-zero and kill the rest of the script under `set -e`, leaving the agent
# unit on disk but never enabled.
# `--no-block` queues the start without waiting for `active`. Without it,
# `systemctl start server` blocks for ~60s on the first boot (refresh.sh
# downloads + unzips the ~430MB release), the agent line never runs, and
# the VM ends up with the agent unit enabled but never started.
systemctl enable battle-royale-server.service battle-royale-agent.service
systemctl start --no-block battle-royale-server.service || true
systemctl start --no-block battle-royale-agent.service  || true

echo "startup-script complete"
