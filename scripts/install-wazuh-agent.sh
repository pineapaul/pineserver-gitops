#!/usr/bin/env bash
set -e

MANAGER_IP="$1"
AGENT_NAME="$2"
PASSWORD="$3"

if [[ -z "$MANAGER_IP" || -z "$AGENT_NAME" ]]; then
  echo "Usage: $0 <manager-ip> <agent-name> [password]"
  exit 1
fi

echo "[+] Installing Wazuh agent..."
curl -s https://packages.wazuh.com/4.x/bash/wazuh-install.sh | bash -s -- \
  --agent \
  --manager-ip "$MANAGER_IP" \
  --agent-name "$AGENT_NAME"

if [[ -n "$PASSWORD" ]]; then
  echo "[+] Setting password authentication..."
  echo "$PASSWORD" > /var/ossec/etc/authd.pass
  chmod 640 /var/ossec/etc/authd.pass
  chown root:wazuh /var/ossec/etc/authd.pass
fi

echo "[+] Restarting Wazuh agent..."
/var/ossec/bin/wazuh-control restart

echo "[+] Done."
