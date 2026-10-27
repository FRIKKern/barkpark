#!/usr/bin/env bash
# shellcheck disable=SC2154 # host, RG and the like come from the vars file.
# Path A step 2 says to create a DNS A record and gives no command. A run uses
# an Azure DNS name label on the VM's public IP instead.
"$GUIDE_REPO/scripts/setup-guide/azure.sh" dns "$RG" "$DNS_LABEL"
ip="$(az vm show -d -g "$RG" -n barkpark --query publicIps -o tsv)"
for _ in $(seq 1 30); do
  [ "$(dig +short "$host" | tail -n 1)" = "$ip" ] && { echo "dns: $host resolves to the VM"; exit 0; }
  sleep 10
done
echo "dns: $host does not resolve to the VM after 300 seconds" >&2; exit 1
