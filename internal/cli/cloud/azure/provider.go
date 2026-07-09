package azure

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/arm"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/runtime"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/to"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v5"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/network/armnetwork/v4"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/resources/armresources"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// Resource-naming + provisioning defaults. A single resource group holds the
// whole fleet (resource-group-per-fleet convention): the group and its VNet are
// shared and idempotently ensured on every create; the PublicIP / NIC / VM are
// per-box, named off the box name so teardown targets exactly one instance's
// resources and never the shared fabric.
const (
	// DefaultResourceGroup is the fleet's resource group when none is configured.
	DefaultResourceGroup = "barkpark-fleet"
	// DefaultLocation is where the group + VNet live when a spec carries no region.
	DefaultLocation = "eastus"
	// DefaultServerType is the fallback VM size (2 vCPU-burstable, cheap).
	DefaultServerType = "Standard_B1s"
	// DefaultAdminUsername is the VM's Linux admin account.
	DefaultAdminUsername = "barkpark"

	vnetSuffix   = "-vnet"
	subnetName   = "default"
	pipSuffix    = "-ip"
	nicSuffix    = "-nic"
	osDiskSuffix = "-osdisk"

	vnetAddressPrefix   = "10.0.0.0/16"
	subnetAddressPrefix = "10.0.0.0/24"

	// defaultPollFrequency is how often an LRO is polled in the absence of a
	// Retry-After header. Kept modest for prod; tests inject a small value.
	defaultPollFrequency = 5 * time.Second

	// Env overrides that mirror the Hetzner path's BARKPARK_SERVER_* knobs.
	EnvResourceGroup = "BARKPARK_AZURE_RESOURCE_GROUP"
	EnvLocation      = "BARKPARK_AZURE_LOCATION"
	EnvServerType    = "BARKPARK_AZURE_SERVER_TYPE"
	EnvSSHPublicKey  = "BARKPARK_AZURE_SSH_PUBKEY"
)

// DefaultSpec is the Azure analogue of cloud.DefaultSpec(hetzner): a complete
// spec so a bare `--provider azure` renders without the caller filling
// region/type/image. Env overrides win so a size/region change needs no rebuild.
// Name is left for the caller to fill.
func DefaultSpec() cloud.ServerSpec {
	spec := cloud.ServerSpec{
		Region:     DefaultLocation,
		ServerType: DefaultServerType,
		Image:      "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest",
	}
	if v := strings.TrimSpace(os.Getenv(EnvLocation)); v != "" {
		spec.Region = v
	}
	if v := strings.TrimSpace(os.Getenv(EnvServerType)); v != "" {
		spec.ServerType = v
	}
	return spec
}

// AzureProvider implements cloud.CloudProvider + the optional label capabilities
// against ARM. Construct it with New. The zero value is NOT usable (it has no
// credential or clients) — this differs from HcloudProvider because ARM has no
// ambient CLI context to fall back on; auth is always an explicit 4-tuple.
type AzureProvider struct {
	creds         Credentials
	cred          azcore.TokenCredential // nil when creds are incomplete
	transport     policy.Transporter     // nil => SDK default HTTPS transport
	resourceGroup string
	location      string
	serverType    string
	adminUsername string
	sshPublicKey  string
	pollFreq      time.Duration

	// ARM clients, built once in New when a credential is present.
	groups *armresources.ResourceGroupsClient
	tags   *armresources.TagsClient
	res    *armresources.Client
	vnets  *armnetwork.VirtualNetworksClient
	pips   *armnetwork.PublicIPAddressesClient
	nics   *armnetwork.InterfacesClient
	vms    *armcompute.VirtualMachinesClient
}

// Option customizes an AzureProvider. WithTransport is the test seam; the rest
// tune the resource-group-per-fleet convention and VM shape.
type Option func(*AzureProvider)

// WithTransport injects the azcore transport every ARM client AND the credential
// use. Tests pass a fixture-replaying fake here; production passes nothing.
func WithTransport(t policy.Transporter) Option { return func(p *AzureProvider) { p.transport = t } }

// WithCredential injects a pre-built token credential, bypassing the real
// client-secret exchange. Handy for focused unit tests; production uses the
// credential New builds from the tuple.
func WithCredential(c azcore.TokenCredential) Option { return func(p *AzureProvider) { p.cred = c } }

// WithResourceGroup overrides the fleet resource group.
func WithResourceGroup(rg string) Option { return func(p *AzureProvider) { p.resourceGroup = rg } }

// WithLocation overrides the location the shared group + VNet are created in.
func WithLocation(loc string) Option { return func(p *AzureProvider) { p.location = loc } }

// WithPollFrequency tunes the LRO poll interval (tests set this small).
func WithPollFrequency(d time.Duration) Option { return func(p *AzureProvider) { p.pollFreq = d } }

// WithSSHPublicKey sets the Linux admin SSH public key baked into created VMs.
func WithSSHPublicKey(k string) Option { return func(p *AzureProvider) { p.sshPublicKey = k } }

// New builds an AzureProvider. It does NOT hard-fail on an incomplete tuple:
// the returned provider is usable for HasAuth (which reports false) and its
// Create/Delete/… return a clear "incomplete credentials" error — this mirrors
// HcloudProvider, whose HasAuth is a cheap presence check and whose Create fails
// later if the credential is actually bad. New DOES return an error if a COMPLETE
// tuple is malformed (azidentity rejects it) or a client constructor fails, so a
// genuinely broken configuration surfaces at construction, not first use.
func New(creds Credentials, opts ...Option) (*AzureProvider, error) {
	p := &AzureProvider{
		creds:         creds,
		resourceGroup: strings.TrimSpace(os.Getenv(EnvResourceGroup)),
		location:      strings.TrimSpace(os.Getenv(EnvLocation)),
		serverType:    strings.TrimSpace(os.Getenv(EnvServerType)),
		sshPublicKey:  strings.TrimSpace(os.Getenv(EnvSSHPublicKey)),
		adminUsername: DefaultAdminUsername,
		pollFreq:      defaultPollFrequency,
	}
	for _, o := range opts {
		o(p)
	}
	if p.resourceGroup == "" {
		p.resourceGroup = DefaultResourceGroup
	}
	if p.location == "" {
		p.location = DefaultLocation
	}

	// Build the credential from the tuple unless one was injected. An incomplete
	// tuple is NOT an error here (HasAuth handles that); a malformed complete one
	// is.
	if p.cred == nil && creds.Complete() {
		cred, err := newClientSecretCredential(creds, p.transport)
		if err != nil {
			return nil, err
		}
		p.cred = cred
	}
	if p.cred != nil {
		if err := p.buildClients(); err != nil {
			return nil, err
		}
	}
	return p, nil
}

// buildClients constructs every ARM client with the shared credential and the
// injected transport. Called once from New. RP auto-registration is disabled: it
// fires an extra provider-registration round-trip on some errors that would
// otherwise need a fixture, and the fleet's providers are registered out of band.
func (p *AzureProvider) buildClients() error {
	sub := p.creds.SubscriptionID
	armOpts := &arm.ClientOptions{
		ClientOptions:         policy.ClientOptions{Transport: p.transport},
		DisableRPRegistration: true,
	}
	var err error
	if p.groups, err = armresources.NewResourceGroupsClient(sub, p.cred, armOpts); err != nil {
		return fmt.Errorf("azure: resource-groups client: %w", err)
	}
	if p.tags, err = armresources.NewTagsClient(sub, p.cred, armOpts); err != nil {
		return fmt.Errorf("azure: tags client: %w", err)
	}
	if p.res, err = armresources.NewClient(sub, p.cred, armOpts); err != nil {
		return fmt.Errorf("azure: resources client: %w", err)
	}
	if p.vnets, err = armnetwork.NewVirtualNetworksClient(sub, p.cred, armOpts); err != nil {
		return fmt.Errorf("azure: vnet client: %w", err)
	}
	if p.pips, err = armnetwork.NewPublicIPAddressesClient(sub, p.cred, armOpts); err != nil {
		return fmt.Errorf("azure: public-ip client: %w", err)
	}
	if p.nics, err = armnetwork.NewInterfacesClient(sub, p.cred, armOpts); err != nil {
		return fmt.Errorf("azure: nic client: %w", err)
	}
	if p.vms, err = armcompute.NewVirtualMachinesClient(sub, p.cred, armOpts); err != nil {
		return fmt.Errorf("azure: vm client: %w", err)
	}
	return nil
}

// ── credential gate ─────────────────────────────────────────────────────────

// HasAuth reports whether a complete Azure credential is present. Like the
// Hetzner provider it is a cheap presence check, not a live API call — the live
// check is the control plane's verify-before-save preflight.
func (p *AzureProvider) HasAuth(ctx context.Context) bool { return p.creds.Complete() }

// ready returns the credential error when the provider was built without a usable
// credential, so every op fails with the same clear message instead of a nil
// dereference.
func (p *AzureProvider) ready() error {
	if p.cred == nil || p.vms == nil {
		if err := p.creds.Validate(); err != nil {
			return err
		}
		return errors.New("azure: provider not initialized (no credential)")
	}
	return nil
}

// ── resource id + name helpers (pure) ───────────────────────────────────────

func (p *AzureProvider) vnetName() string { return p.resourceGroup + vnetSuffix }
func pipName(box string) string           { return box + pipSuffix }
func nicName(box string) string           { return box + nicSuffix }
func osDiskName(box string) string        { return box + osDiskSuffix }

func (p *AzureProvider) rgID() string {
	return fmt.Sprintf("/subscriptions/%s/resourceGroups/%s", p.creds.SubscriptionID, p.resourceGroup)
}

// vmID is the ARM resource id of a box's VM — the scope the tag operations patch.
func (p *AzureProvider) vmID(box string) string {
	return p.rgID() + "/providers/Microsoft.Compute/virtualMachines/" + box
}

func (p *AzureProvider) subnetID() string {
	return p.rgID() + "/providers/Microsoft.Network/virtualNetworks/" + p.vnetName() + "/subnets/" + subnetName
}

func (p *AzureProvider) pipID(box string) string {
	return p.rgID() + "/providers/Microsoft.Network/publicIPAddresses/" + pipName(box)
}

func (p *AzureProvider) specLocation(spec cloud.ServerSpec) string {
	if loc := strings.TrimSpace(spec.Region); loc != "" {
		return loc
	}
	return p.location
}

func (p *AzureProvider) specSize(spec cloud.ServerSpec) string {
	if t := strings.TrimSpace(spec.ServerType); t != "" {
		return t
	}
	if p.serverType != "" {
		return p.serverType
	}
	return DefaultServerType
}

// imageReference maps a spec.Image string onto an ARM ImageReference. Three forms
// are accepted: a full resource id (a custom/gallery image), a
// publisher:offer:sku:version URN (a platform image), or empty (Ubuntu 22.04).
func imageReference(image string) *armcompute.ImageReference {
	image = strings.TrimSpace(image)
	if image == "" {
		return &armcompute.ImageReference{
			Publisher: to.Ptr("Canonical"),
			Offer:     to.Ptr("0001-com-ubuntu-server-jammy"),
			SKU:       to.Ptr("22_04-lts-gen2"),
			Version:   to.Ptr("latest"),
		}
	}
	if strings.HasPrefix(image, "/subscriptions/") {
		return &armcompute.ImageReference{ID: to.Ptr(image)}
	}
	if parts := strings.Split(image, ":"); len(parts) == 4 {
		return &armcompute.ImageReference{
			Publisher: to.Ptr(parts[0]),
			Offer:     to.Ptr(parts[1]),
			SKU:       to.Ptr(parts[2]),
			Version:   to.Ptr(parts[3]),
		}
	}
	// Unrecognized: treat as a platform-image SKU on the Ubuntu publisher/offer.
	return &armcompute.ImageReference{
		Publisher: to.Ptr("Canonical"),
		Offer:     to.Ptr("0001-com-ubuntu-server-jammy"),
		SKU:       to.Ptr(image),
		Version:   to.Ptr("latest"),
	}
}

// managedTags is the tag set stamped on every created VM: barkpark-managed=true,
// the fence the orphan sweep never crosses, exactly as the Hetzner label does.
func managedTags() map[string]*string {
	return map[string]*string{cloud.ManagedLabelKey: to.Ptr("true")}
}

// ── CloudProvider ────────────────────────────────────────────────────────────

// Create provisions the minimum ARM slice for one box and blocks (via LRO
// polling) until the VM is running and its public IP is readable. The shared
// resource group + VNet are ensured idempotently; the PublicIP, NIC and VM are
// per-box.
//
// It honors the SAME failed-create-orphan guarantee HcloudProvider has, and then
// some: a deferred cleanup tears down THIS box's per-box resources (VM, NIC,
// PublicIP — never the shared group/VNet) if any step, INCLUDING the final IP
// read-back, fails. The cleanup runs on a fresh context so a cancelled/timed-out
// create still gets to delete what it made — no billed orphan, no stranded NIC.
func (p *AzureProvider) Create(ctx context.Context, spec cloud.ServerSpec) (cloud.Server, error) {
	if err := p.ready(); err != nil {
		return cloud.Server{}, err
	}
	if strings.TrimSpace(spec.Name) == "" {
		return cloud.Server{}, errors.New("azure: create: spec.Name is required")
	}
	box := spec.Name
	loc := p.specLocation(spec)

	success := false
	defer func() {
		if !success {
			dctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			defer cancel()
			_ = p.cleanupBox(dctx, box) // best-effort; error already surfaced by Create
		}
	}()

	// 1. Fleet resource group (idempotent, synchronous).
	if _, err := p.groups.CreateOrUpdate(ctx, p.resourceGroup, armresources.ResourceGroup{Location: to.Ptr(loc)}, nil); err != nil {
		return cloud.Server{}, fmt.Errorf("azure: ensure resource group %q: %w", p.resourceGroup, err)
	}

	// 2. Shared VNet + subnet (idempotent LRO).
	vnetPoller, err := p.vnets.BeginCreateOrUpdate(ctx, p.resourceGroup, p.vnetName(), armnetwork.VirtualNetwork{
		Location: to.Ptr(loc),
		Properties: &armnetwork.VirtualNetworkPropertiesFormat{
			AddressSpace: &armnetwork.AddressSpace{AddressPrefixes: []*string{to.Ptr(vnetAddressPrefix)}},
			Subnets: []*armnetwork.Subnet{{
				Name:       to.Ptr(subnetName),
				Properties: &armnetwork.SubnetPropertiesFormat{AddressPrefix: to.Ptr(subnetAddressPrefix)},
			}},
		},
	}, nil)
	if err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create vnet: %w", err)
	}
	if _, err := poll(ctx, p.pollFreq, vnetPoller); err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create vnet: %w", err)
	}

	// 3. Public IP (per-box LRO). Static + Standard so the address is stable and
	//    zone-redundant — the address a DNS A-record will point at.
	pipPoller, err := p.pips.BeginCreateOrUpdate(ctx, p.resourceGroup, pipName(box), armnetwork.PublicIPAddress{
		Location: to.Ptr(loc),
		SKU:      &armnetwork.PublicIPAddressSKU{Name: to.Ptr(armnetwork.PublicIPAddressSKUNameStandard)},
		Properties: &armnetwork.PublicIPAddressPropertiesFormat{
			PublicIPAllocationMethod: to.Ptr(armnetwork.IPAllocationMethodStatic),
			PublicIPAddressVersion:   to.Ptr(armnetwork.IPVersionIPv4),
		},
		Tags: managedTags(),
	}, nil)
	if err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create public ip: %w", err)
	}
	if _, err := poll(ctx, p.pollFreq, pipPoller); err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create public ip: %w", err)
	}

	// 4. NIC binding the subnet + public IP (per-box LRO).
	nicPoller, err := p.nics.BeginCreateOrUpdate(ctx, p.resourceGroup, nicName(box), armnetwork.Interface{
		Location: to.Ptr(loc),
		Properties: &armnetwork.InterfacePropertiesFormat{
			IPConfigurations: []*armnetwork.InterfaceIPConfiguration{{
				Name: to.Ptr("ipconfig1"),
				Properties: &armnetwork.InterfaceIPConfigurationPropertiesFormat{
					Subnet:          &armnetwork.Subnet{ID: to.Ptr(p.subnetID())},
					PublicIPAddress: &armnetwork.PublicIPAddress{ID: to.Ptr(p.pipID(box))},
				},
			}},
		},
		Tags: managedTags(),
	}, nil)
	if err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create nic: %w", err)
	}
	nicRes, err := poll(ctx, p.pollFreq, nicPoller)
	if err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create nic: %w", err)
	}

	// 5. VM (per-box LRO) referencing the NIC, tagged barkpark-managed.
	vmPoller, err := p.vms.BeginCreateOrUpdate(ctx, p.resourceGroup, box, p.virtualMachine(box, loc, spec, nicRes), nil)
	if err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create vm: %w", err)
	}
	if _, err := poll(ctx, p.pollFreq, vmPoller); err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create vm: %w", err)
	}

	// 6. IP read-back — the step that, on failure, must leave no orphan (the
	//    deferred cleanup fires because success is still false).
	ip, err := p.IP(ctx, box)
	if err != nil {
		return cloud.Server{}, fmt.Errorf("azure: create %q: ip read-back failed (created resources deleted to avoid an orphan): %w", box, err)
	}

	success = true
	return cloud.Server{ID: p.vmID(box), Name: box, IP: ip}, nil
}

// virtualMachine builds the VM parameters. When a NIC create response carries the
// NIC id we use it; otherwise we fall back to the deterministic id (the fake path
// and any provider that returns a bare poller both work).
func (p *AzureProvider) virtualMachine(box, loc string, spec cloud.ServerSpec, nic armnetwork.InterfacesClientCreateOrUpdateResponse) armcompute.VirtualMachine {
	nicID := p.rgID() + "/providers/Microsoft.Network/networkInterfaces/" + nicName(box)
	if nic.ID != nil && *nic.ID != "" {
		nicID = *nic.ID
	}
	osProfile := &armcompute.OSProfile{
		ComputerName:  to.Ptr(box),
		AdminUsername: to.Ptr(p.adminUsername),
	}
	if p.sshPublicKey != "" {
		osProfile.LinuxConfiguration = &armcompute.LinuxConfiguration{
			DisablePasswordAuthentication: to.Ptr(true),
			SSH: &armcompute.SSHConfiguration{PublicKeys: []*armcompute.SSHPublicKey{{
				Path:    to.Ptr("/home/" + p.adminUsername + "/.ssh/authorized_keys"),
				KeyData: to.Ptr(p.sshPublicKey),
			}}},
		}
	}
	return armcompute.VirtualMachine{
		Location: to.Ptr(loc),
		Tags:     managedTags(),
		Properties: &armcompute.VirtualMachineProperties{
			HardwareProfile: &armcompute.HardwareProfile{
				VMSize: to.Ptr(armcompute.VirtualMachineSizeTypes(p.specSize(spec))),
			},
			StorageProfile: &armcompute.StorageProfile{
				ImageReference: imageReference(spec.Image),
				OSDisk: &armcompute.OSDisk{
					Name:         to.Ptr(osDiskName(box)),
					CreateOption: to.Ptr(armcompute.DiskCreateOptionTypesFromImage),
					ManagedDisk:  &armcompute.ManagedDiskParameters{StorageAccountType: to.Ptr(armcompute.StorageAccountTypesStandardLRS)},
				},
			},
			OSProfile: osProfile,
			NetworkProfile: &armcompute.NetworkProfile{
				NetworkInterfaces: []*armcompute.NetworkInterfaceReference{{
					ID:         to.Ptr(nicID),
					Properties: &armcompute.NetworkInterfaceReferenceProperties{Primary: to.Ptr(true)},
				}},
			},
		},
	}
}

// IP reads the box's public IPv4 back from its PublicIP resource. An empty
// address is an error (the address isn't allocated yet / the box is gone) — the
// same signal Create's read-back treats as "clean up the orphan".
func (p *AzureProvider) IP(ctx context.Context, name string) (string, error) {
	if err := p.ready(); err != nil {
		return "", err
	}
	resp, err := p.pips.Get(ctx, p.resourceGroup, pipName(name), nil)
	if err != nil {
		return "", fmt.Errorf("azure: get public ip %q: %w", pipName(name), err)
	}
	if resp.Properties == nil || resp.Properties.IPAddress == nil || *resp.Properties.IPAddress == "" {
		return "", fmt.Errorf("azure: public ip %q has no allocated address", pipName(name))
	}
	return *resp.Properties.IPAddress, nil
}

// Delete tears down ONE box's per-box resources (VM, then NIC, then PublicIP —
// dependency order) and leaves the shared resource group + VNet standing (the
// resource-group-per-fleet convention: deleting the group would nuke the whole
// fleet). A resource that is already gone (404) is treated as success so Delete
// is idempotent and the orphan sweep can call it safely.
func (p *AzureProvider) Delete(ctx context.Context, name string) error {
	if err := p.ready(); err != nil {
		return err
	}
	return p.cleanupBox(ctx, name)
}

// cleanupBox deletes VM → NIC → PublicIP for one box, ignoring not-found. It is
// the shared engine behind Delete and Create's failed-create teardown.
func (p *AzureProvider) cleanupBox(ctx context.Context, box string) error {
	vmPoller, err := p.vms.BeginDelete(ctx, p.resourceGroup, box, nil)
	if err != nil {
		if !isNotFound(err) {
			return fmt.Errorf("azure: delete vm %q: %w", box, err)
		}
	} else if _, err := poll(ctx, p.pollFreq, vmPoller); err != nil && !isNotFound(err) {
		return fmt.Errorf("azure: delete vm %q: %w", box, err)
	}

	nicPoller, err := p.nics.BeginDelete(ctx, p.resourceGroup, nicName(box), nil)
	if err != nil {
		if !isNotFound(err) {
			return fmt.Errorf("azure: delete nic %q: %w", nicName(box), err)
		}
	} else if _, err := poll(ctx, p.pollFreq, nicPoller); err != nil && !isNotFound(err) {
		return fmt.Errorf("azure: delete nic %q: %w", nicName(box), err)
	}

	pipPoller, err := p.pips.BeginDelete(ctx, p.resourceGroup, pipName(box), nil)
	if err != nil {
		if !isNotFound(err) {
			return fmt.Errorf("azure: delete public ip %q: %w", pipName(box), err)
		}
	} else if _, err := poll(ctx, p.pollFreq, pipPoller); err != nil && !isNotFound(err) {
		return fmt.Errorf("azure: delete public ip %q: %w", pipName(box), err)
	}
	return nil
}

// List returns every managed VM in the fleet (barkpark-managed tagged). It reads
// the generic resources pager filtered to VMs, then keeps the ones carrying the
// managed tag. IP is left empty: resolving each VM's address needs a NIC→PublicIP
// hop the fleet listing doesn't need (the orphan sweep reads the fqdn tag, not
// the IP) — this mirrors cloud.List, which is intentionally thin.
func (p *AzureProvider) List(ctx context.Context) ([]cloud.Server, error) {
	return p.listWhere(ctx, func(tags map[string]string) bool {
		return tags[cloud.ManagedLabelKey] != ""
	})
}

// ListByLabel returns managed VMs carrying key=val. SweepOrphans calls it with
// barkpark-orphaned=true; the full tag map rides back on each Server so the
// stranded DNS record (barkpark-fqdn) can be cleaned up too.
func (p *AzureProvider) ListByLabel(ctx context.Context, key, val string) ([]cloud.Server, error) {
	return p.listWhere(ctx, func(tags map[string]string) bool {
		return tags[key] == val
	})
}

// listWhere pages VMs (resourceType filter — the ONE filter ARM lets us combine
// with nothing else and still return tags) and applies `keep` client-side. We do
// NOT filter by tag server-side: ARM strips the tag map from tag-filtered results,
// and the sweep needs the fqdn tag back. Results are scoped to THIS fleet's
// resource group (the list pager is subscription-wide, but a subscription may
// host several fleets — the sweep must only ever see its own).
func (p *AzureProvider) listWhere(ctx context.Context, keep func(map[string]string) bool) ([]cloud.Server, error) {
	if err := p.ready(); err != nil {
		return nil, err
	}
	pager := p.res.NewListPager(&armresources.ClientListOptions{
		Filter: to.Ptr("resourceType eq 'Microsoft.Compute/virtualMachines'"),
	})
	var servers []cloud.Server
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("azure: list resources: %w", err)
		}
		for _, r := range page.Value {
			if r == nil || r.Name == nil {
				continue
			}
			if r.ID != nil && !idInResourceGroup(*r.ID, p.resourceGroup) {
				continue
			}
			tags := flattenTags(r.Tags)
			if !keep(tags) {
				continue
			}
			srv := cloud.Server{Name: *r.Name, Labels: tags}
			if r.ID != nil {
				srv.ID = *r.ID
			}
			servers = append(servers, srv)
		}
	}
	return servers, nil
}

// idInResourceGroup reports whether an ARM resource id lives in rg. ARM ids spell
// the group as ".../resourceGroups/<rg>/..." but the casing of the segment name
// is not guaranteed, so the compare is case-insensitive.
func idInResourceGroup(id, rg string) bool {
	lower := strings.ToLower(id)
	marker := "/resourcegroups/" + strings.ToLower(rg) + "/"
	return strings.Contains(lower, marker)
}

// ── label capabilities (tags) ───────────────────────────────────────────────

// LabelServer merges key=val onto the box's VM tags via a single Tags PATCH
// (Merge) — no LRO, idempotent. Used best-effort in teardown to stamp
// barkpark-orphaned=true on a box whose Delete persistently failed.
func (p *AzureProvider) LabelServer(ctx context.Context, name, key, val string) error {
	if err := p.ready(); err != nil {
		return err
	}
	_, err := p.tags.UpdateAtScope(ctx, p.vmID(name), armresources.TagsPatchResource{
		Operation:  to.Ptr(armresources.TagsPatchOperationMerge),
		Properties: &armresources.Tags{Tags: map[string]*string{key: to.Ptr(val)}},
	}, nil)
	if err != nil {
		return fmt.Errorf("azure: tag %q %s=%s: %w", name, key, val, err)
	}
	return nil
}

// RemoveLabel deletes key from the box's VM tags via a Tags PATCH (Delete). Used
// by the warm-pool assign path to strip barkpark-warm off a promoted box.
func (p *AzureProvider) RemoveLabel(ctx context.Context, name, key string) error {
	if err := p.ready(); err != nil {
		return err
	}
	_, err := p.tags.UpdateAtScope(ctx, p.vmID(name), armresources.TagsPatchResource{
		Operation:  to.Ptr(armresources.TagsPatchOperationDelete),
		Properties: &armresources.Tags{Tags: map[string]*string{key: to.Ptr("")}},
	}, nil)
	if err != nil {
		return fmt.Errorf("azure: untag %q %s: %w", name, key, err)
	}
	return nil
}

// ── power actions (LRO) ──────────────────────────────────────────────────────
// Deallocate/Start are the Azure analogue of stop/start. They are NOT part of the
// core CloudProvider contract (which stays Create/IP/Delete/List) — they land
// here so the later neutral-lifecycle slice can type-assert for them, exactly the
// optional-capability idiom ServerLabeler follows.

// Deallocate stops the VM AND releases its compute (billing stops) — an LRO.
func (p *AzureProvider) Deallocate(ctx context.Context, name string) error {
	if err := p.ready(); err != nil {
		return err
	}
	poller, err := p.vms.BeginDeallocate(ctx, p.resourceGroup, name, nil)
	if err != nil {
		return fmt.Errorf("azure: deallocate %q: %w", name, err)
	}
	if _, err := poll(ctx, p.pollFreq, poller); err != nil {
		return fmt.Errorf("azure: deallocate %q: %w", name, err)
	}
	return nil
}

// Start powers a deallocated VM back on — an LRO.
func (p *AzureProvider) Start(ctx context.Context, name string) error {
	if err := p.ready(); err != nil {
		return err
	}
	poller, err := p.vms.BeginStart(ctx, p.resourceGroup, name, nil)
	if err != nil {
		return fmt.Errorf("azure: start %q: %w", name, err)
	}
	if _, err := poll(ctx, p.pollFreq, poller); err != nil {
		return fmt.Errorf("azure: start %q: %w", name, err)
	}
	return nil
}

// ── LRO + error helpers ──────────────────────────────────────────────────────

// poll blocks a runtime.Poller to a terminal state at the provider's configured
// frequency. Generic over the poller's result type so every LRO shares one path.
func poll[T any](ctx context.Context, freq time.Duration, poller *runtime.Poller[T]) (T, error) {
	return poller.PollUntilDone(ctx, &runtime.PollUntilDoneOptions{Frequency: freq})
}

// isNotFound reports whether err is an ARM 404 — the signal a delete target is
// already gone, which Delete/cleanup treat as success.
func isNotFound(err error) bool {
	var respErr *azcore.ResponseError
	return errors.As(err, &respErr) && respErr.StatusCode == 404
}

// flattenTags converts ARM's map[string]*string tag shape to the map[string]string
// the cloud.Server.Labels contract uses, dropping nil values.
func flattenTags(in map[string]*string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		if v != nil {
			out[k] = *v
		} else {
			out[k] = ""
		}
	}
	return out
}

// compile-time assertions: AzureProvider satisfies the core seam and every
// optional label capability the orphan-recovery + warm-pool paths use, exactly
// like HcloudProvider does — so it drops into the seam as an implementation, not
// a fork, the moment a later slice wires it into the registry.
var (
	_ cloud.CloudProvider      = (*AzureProvider)(nil)
	_ cloud.ServerLabeler      = (*AzureProvider)(nil)
	_ cloud.LabelLister        = (*AzureProvider)(nil)
	_ cloud.ServerLabelRemover = (*AzureProvider)(nil)
)
