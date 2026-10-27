#!/usr/bin/env bash
# azure.sh: start and end a setup-guide run in its own Azure resource group.
#
#   scripts/setup-guide/azure.sh up   <rg>          empty group in Sweden Central
#   scripts/setup-guide/azure.sh vm   <rg> <label>  VM as Path A step 1 makes it,
#                                                   with a DNS name label
#   scripts/setup-guide/azure.sh dns  <rg> <label>  put the label on the VM's IP
#   scripts/setup-guide/azure.sh down <rg>          delete the group and wait
#
# `up` refuses a group that already exists, so a run starts from empty. The
# VM is Ubuntu 22.04, Standard_D2als_v7, sudo user azureuser, ports 22, 80
# and 443. Set AZ_SUBSCRIPTION to pin a subscription.
set -euo pipefail

LOCATION="${LOCATION:-swedencentral}"
VM_NAME="${VM_NAME:-barkpark}"
SIZE="${VM_SIZE:-Standard_D2als_v7}"
sub=()
[ -n "${AZ_SUBSCRIPTION:-}" ] && sub=(--subscription "$AZ_SUBSCRIPTION")

cmd="${1:-}"; rg="${2:-}"
[ -n "$cmd" ] && [ -n "$rg" ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

case "$cmd" in
  up)
    if [ "$(az group exists -n "$rg" "${sub[@]}")" = true ]; then
      echo "azure.sh: $rg exists. Run: $0 down $rg" >&2; exit 1
    fi
    az group create -n "$rg" -l "$LOCATION" --tags purpose=setup-guide-run "${sub[@]}" -o none
    echo "azure.sh: created $rg in $LOCATION"
    ;;
  vm)
    label="${3:?dns label}"
    az vm create -g "$rg" -n "$VM_NAME" --image Ubuntu2204 --size "$SIZE" \
      --location "$LOCATION" --admin-username azureuser --generate-ssh-keys \
      --public-ip-address-dns-name "$label" "${sub[@]}" -o none
    az vm open-port -g "$rg" -n "$VM_NAME" --port 80,443 --priority 900 "${sub[@]}" -o none
    "$0" dns "$rg" "$label"
    ;;
  dns)
    label="${3:?dns label}"
    ip="$(az network public-ip list -g "$rg" "${sub[@]}" --query '[0].name' -o tsv)"
    [ -n "$ip" ] || { echo "azure.sh: no public IP in $rg" >&2; exit 1; }
    fqdn="$(az network public-ip update -g "$rg" -n "$ip" --dns-name "$label" "${sub[@]}" \
      --query dnsSettings.fqdn -o tsv)"
    echo "azure.sh: $fqdn"
    ;;
  down)
    if [ "$(az group exists -n "$rg" "${sub[@]}")" != true ]; then
      echo "azure.sh: $rg does not exist"; exit 0
    fi
    az group delete -n "$rg" --yes "${sub[@]}"
    echo "azure.sh: deleted $rg"
    ;;
  *) echo "azure.sh: unknown command $cmd" >&2; exit 2 ;;
esac
