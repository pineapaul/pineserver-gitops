#!/usr/bin/env bash
set -e

NEW_PASS="$1"
NS="wazuh"
POD=$(kubectl -n $NS get pod -l app=wazuh-manager-master -o jsonpath='{.items[0].metadata.name}')

if [[ -z "$NEW_PASS" ]]; then
  echo "Usage: $0 <new-password>"
  exit 1
fi

echo "[+] Writing password inside manager..."
kubectl -n $NS exec "$POD" -- bash -c "
  echo '$NEW_PASS' > /var/ossec/etc/authd.pass &&
  chmod 640 /var/ossec/etc/authd.pass &&
  chown root:wazuh /var/ossec/etc/authd.pass
"

echo "[+] Restarting manager..."
kubectl -n $NS exec "$POD" -- /var/ossec/bin/wazuh-control restart

echo "[+] Password reset complete."
