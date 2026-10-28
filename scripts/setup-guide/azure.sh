#!/usr/bin/env bash
# azure.sh: start and end a setup-guide run in its own Azure resource group.
#
#   scripts/setup-guide/azure.sh up    <rg>          empty group in Sweden Central
#   scripts/setup-guide/azure.sh vm    <rg> <label>  VM as Path A step 1 makes it,
#                                                    with a DNS name label
#   scripts/setup-guide/azure.sh dns   <rg> <label>  put the label on the VM's IP
#   scripts/setup-guide/azure.sh entra <rg> <org> [entra-app-register.sh options]
#                                    register the run's Entra app and owners group
#   scripts/setup-guide/azure.sh down  <rg>          delete the group, its Key
#                    Vaults and the run's Entra app, service principal and group,
#                    purge them all, and check that nothing is left
#
# `up` refuses a group that already exists, so a run starts from empty. The
# VM is Ubuntu 22.04, Standard_D2als_v7, sudo user azureuser with the key
# ~/.ssh/barkpark, ports 22, 80 and 443. Set AZ_SUBSCRIPTION to pin a subscription.
#
# `entra` runs scripts/entra-app-register.sh with --name "Barkpark <org> (<rg>)"
# and --owners-group "Barkpark <org> owners (<rg>)". It refuses a name that is
# taken by an app or group it did not make. It tags the app setup-guide-run:<rg>
# and gives the group that description, and `down` deletes only what carries it.
set -euo pipefail

LOCATION="${LOCATION:-swedencentral}"
VM_NAME="${VM_NAME:-barkpark}"
SIZE="${VM_SIZE:-Standard_D2als_v7}"
GRAPH="https://graph.microsoft.com/v1.0"
sub=()
[ -n "${AZ_SUBSCRIPTION:-}" ] && sub=(--subscription "$AZ_SUBSCRIPTION")

cmd="${1:-}"; rg="${2:-}"
[ -n "$cmd" ] && [ -n "$rg" ] || { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
mark="setup-guide-run:$rg"

say() { printf 'azure.sh: %s\n' "$*"; }

# Object ids of the run's apps and groups, found by the mark only.
run_apps() { az ad app list --filter "tags/any(t:t eq '$mark')" --query "[].id" -o tsv; }
run_groups() {
  az ad group list --filter "startswith(displayName,'Barkpark ')" \
    --query "[?description=='$mark'].id" -o tsv
}

# Remove a deleted object from the Entra recycle bin. It can take a few
# seconds to arrive there after the delete.
purge() {
  local id="$1" kind="$2" n
  for n in 1 2 3 4 5 6; do
    if az rest --method DELETE --uri "$GRAPH/directory/deletedItems/$id" -o none 2>/dev/null; then
      say "purged $kind $id from the recycle bin"; return 0
    fi
    sleep $((n * 5))
  done
  say "could not purge $kind $id from the recycle bin" >&2; return 1
}

in_bin() { az rest --method GET --uri "$GRAPH/directory/deletedItems/$1" -o none 2>/dev/null; }

entra_down() {
  local id app_id sp_id gid left=0 ids=()
  for id in $(run_apps); do
    app_id="$(az ad app show --id "$id" --query appId -o tsv)"
    sp_id="$(az ad sp list --filter "appId eq '$app_id'" --query "[0].id" -o tsv)"
    if [ -n "$sp_id" ]; then
      az ad sp delete --id "$sp_id"; say "deleted service principal $sp_id"
      ids+=("$sp_id:service-principal")
    fi
    az ad app delete --id "$id"; say "deleted app registration $id ($app_id)"
    ids+=("$id:app")
  done
  for gid in $(run_groups); do
    az ad group delete --group "$gid"; say "deleted group $gid"
    ids+=("$gid:group")
  done
  for id in ${ids[@]+"${ids[@]}"}; do purge "${id%%:*}" "${id#*:}" || left=1; done

  # Check: no live app or group with the mark, nothing of ours in the bin.
  [ -z "$(run_apps)" ] || { say "an app tagged $mark is still there" >&2; left=1; }
  [ -z "$(run_groups)" ] || { say "a group described $mark is still there" >&2; left=1; }
  for id in ${ids[@]+"${ids[@]}"}; do
    if in_bin "${id%%:*}"; then say "${id#*:} ${id%%:*} is still in the recycle bin" >&2; left=1; fi
  done
  [ "$left" = 0 ] && say "Entra: no app, service principal or group for $rg, recycle bin clear"
  return "$left"
}

case "$cmd" in
  up)
    if [ "$(az group exists -n "$rg" ${sub[@]+"${sub[@]}"})" = true ]; then
      echo "azure.sh: $rg exists. Run: $0 down $rg" >&2; exit 1
    fi
    az group create -n "$rg" -l "$LOCATION" --tags purpose=setup-guide-run ${sub[@]+"${sub[@]}"} -o none
    echo "azure.sh: created $rg in $LOCATION"
    ;;
  vm)
    label="${3:?dns label}"
    [ -f "$HOME/.ssh/barkpark" ] || ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/barkpark"
    az vm create -g "$rg" -n "$VM_NAME" --image Ubuntu2204 --size "$SIZE" \
      --location "$LOCATION" --admin-username azureuser --ssh-key-values "$HOME/.ssh/barkpark.pub" \
      --public-ip-address-dns-name "$label" ${sub[@]+"${sub[@]}"} -o none
    az vm open-port -g "$rg" -n "$VM_NAME" --port 80,443 --priority 900 ${sub[@]+"${sub[@]}"} -o none
    "$0" dns "$rg" "$label"
    ;;
  dns)
    label="${3:?dns label}"
    ip="$(az network public-ip list -g "$rg" ${sub[@]+"${sub[@]}"} --query '[0].name' -o tsv)"
    [ -n "$ip" ] || { echo "azure.sh: no public IP in $rg" >&2; exit 1; }
    fqdn="$(az network public-ip update -g "$rg" -n "$ip" --dns-name "$label" ${sub[@]+"${sub[@]}"} \
      --query dnsSettings.fqdn -o tsv)"
    echo "azure.sh: $fqdn"
    ;;
  entra)
    org="${3:?org slug}"; shift 3
    for a in "$@"; do
      case "$a" in --name|--owners-group|--app-id)
        echo "azure.sh: entra sets the name and group itself; drop $a" >&2; exit 2 ;;
      esac
    done
    name="Barkpark $org ($rg)"; group="Barkpark $org owners ($rg)"
    app="$(az ad app list --display-name "$name" --query "[0].id" -o tsv)"
    if [ -n "$app" ] && [ "$(az ad app show --id "$app" --query "contains(tags, '$mark')" -o tsv)" != true ]; then
      echo "azure.sh: an app named \"$name\" exists that this run did not make" >&2; exit 1
    fi
    gid="$(az ad group list --display-name "$group" --query "[0].id" -o tsv)"
    if [ -n "$gid" ] && [ "$(az ad group show --group "$gid" --query description -o tsv)" != "$mark" ]; then
      echo "azure.sh: a group named \"$group\" exists that this run did not make" >&2; exit 1
    fi
    "$(dirname "$0")/../entra-app-register.sh" --org "$org" --name "$name" --owners-group "$group" "$@"
    app="$(az ad app list --display-name "$name" --query "[0].id" -o tsv)"
    gid="$(az ad group list --display-name "$group" --query "[0].id" -o tsv)"
    az rest --method PATCH --uri "$GRAPH/applications/$app" --headers "Content-Type=application/json" \
      --body "{\"tags\":[\"$mark\"]}" -o none
    az rest --method PATCH --uri "$GRAPH/groups/$gid" --headers "Content-Type=application/json" \
      --body "{\"description\":\"$mark\"}" -o none
    say "marked app $app and group $gid with $mark"
    ;;
  down)
    left=0
    if [ "$(az group exists -n "$rg" ${sub[@]+"${sub[@]}"})" = true ]; then
      # A deleted group leaves its Key Vault soft-deleted under the same name,
      # and the next deployment into a group of that name fails on it.
      vaults="$(az keyvault list -g "$rg" ${sub[@]+"${sub[@]}"} --query "[].[name,location]" -o tsv)"
      az group delete -n "$rg" --yes ${sub[@]+"${sub[@]}"}
      echo "azure.sh: deleted $rg"
      while read -r name loc; do
        [ -n "$name" ] || continue
        az keyvault purge -n "$name" -l "$loc" ${sub[@]+"${sub[@]}"}
        echo "azure.sh: purged Key Vault $name"
      done <<<"$vaults"
    else
      echo "azure.sh: $rg does not exist"
    fi
    entra_down || left=1
    # Check: the group is gone and no resource names it.
    if [ "$(az group exists -n "$rg" ${sub[@]+"${sub[@]}"})" = true ] ||
      az resource list ${sub[@]+"${sub[@]}"} --query "[].resourceGroup" -o tsv | grep -qixF "$rg"; then
      say "resources in $rg are still there" >&2; left=1
    else
      say "Azure: no resource group $rg and no resource in it"
    fi
    exit "$left"
    ;;
  *) echo "azure.sh: unknown command $cmd" >&2; exit 2 ;;
esac
