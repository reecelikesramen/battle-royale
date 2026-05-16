#!/usr/bin/env bash
#
# GCE startup script. Runs on first boot and on every reboot. Idempotent.
# Templated variables from Terraform (interpolated by templatefile):
#   ${bucket}              - GCS bucket holding releases + manifest
#   ${project_id}          - GCP project id (used by metric/shutdown agents in Sprint 6+)
#   ${service_unit_body}   - contents of battle-royale-server.service
#   ${refresh_script}      - contents of refresh.sh
#   ${manifest_pub_b64}    - base64-encoded 32-byte ed25519 pubkey (for refresh.sh sig verify)

set -euo pipefail

BUCKET='${bucket}'
PROJECT_ID='${project_id}'

# ── Packages ───────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
if ! command -v jq >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq curl jq unzip openssl
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
systemctl enable --now battle-royale-server.service
systemctl enable --now battle-royale-agent.service

echo "startup-script complete"
