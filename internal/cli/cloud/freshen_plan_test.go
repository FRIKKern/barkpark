package cloud

import (
	"strings"
	"testing"
)

// TestFreshenPlan pins the per-provider freshen descriptor the resurrect step feed
// renders: Hetzner rides the baked warm-image, Azure runs the from-scratch base
// install (no snapshot substrate — charter S14/D41).
func TestFreshenPlan(t *testing.T) {
	if got := FreshenPlan(ProviderHetzner); got != "hetzner warm-image" {
		t.Errorf("hetzner freshen plan = %q, want the warm-image", got)
	}
	az := FreshenPlan(ProviderAzure)
	if az == "hetzner warm-image" {
		t.Error("azure must NOT ride the hetzner warm-image (no snapshot substrate)")
	}
	if !strings.Contains(az, AzureBaseInstallScript) {
		t.Errorf("azure freshen plan %q must name the base-install script %q", az, AzureBaseInstallScript)
	}
	// An unknown/empty kind defaults to the hetzner path (the common case).
	if got := FreshenPlan(""); got != "hetzner warm-image" {
		t.Errorf("empty kind should default to the hetzner warm-image, got %q", got)
	}
}
