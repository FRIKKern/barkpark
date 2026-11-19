package cli

// instance_up_help.go holds the bp instance help for up and resize, which
// printInstanceHelp in cloud12_cmd.go joins into its text.

const instanceUpUsageHelp = `  bp instance up    --azure --path vm|containerapps --resource-group <rg>
                    --owner <upn> [--host <dns label or host>]
                    [--breakglass <email>] [--image <ref> | --from-source <ref>]
                    [--region <r>] [--org <slug>] [--org-name <n>]
                    [--env-file <f>] [--state <f>] [--studio-origin <o>]
                    [--size <vm size>] [--disk-sku <sku>] [--disk-gb <n>]
                    [--postgres-sku <sku>] [--alert-email <e>] [--ssh-key <path>]
                    [--vm-name <n>] [--subnet-id <id>] [--public-ip <name>]
                    [--entra-app-id <appId>] [--assign-identity] [--entra-ssh]
  bp instance resize --size <vm size> [--state <f>] --yes
`

const instanceUpWhatHelp = `  up           take an empty Azure resource group to an instance whose owner
               signs in with Entra ID, on a VM (deploy.sh) or on Container
               Apps (main.bicep): checks az, providers and quota, writes and
               checks barkpark.env, deploys the published image or builds
               --from-source, waits for /readyz, registers the Entra app and
               owners group, named after --org (default pensum) and the host,
               connects bp and the organization, and prints the sign-in link. .bp-instance-up.json records the finished steps
               without secrets, so the same command again resumes. --host is
               a DNS label or your own host on a VM, and your own domain or
               nothing on Container Apps. See docs/setup/SELF-HOST.md.
               Where IT owns the network and the app registration, on a VM:
               --subnet-id puts the VM in that subnet with no NSG of its own
               and opens no port; --public-ip names the address; --entra-app-id
               adds a client secret to that app and pipes it to the VM;
               --assign-identity gives the VM a system-assigned identity;
               --entra-ssh adds AADSSHLoginForLinux. Ubuntu 24.04 LTS. See
               docs/setup/SELF-HOST-IT-MANAGED.md.
  resize       change the size of the VM from up, as after an import on a
               larger size. Restarts the VM, waits for /readyz and records the
               size in the state file.
`
