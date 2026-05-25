package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	apiURL := "http://localhost:4000"
	if env := os.Getenv("BARKPARK_API_URL"); env != "" {
		apiURL = env
	}

	apiToken := os.Getenv("BARKPARK_API_TOKEN")
	if apiToken == "" {
		apiToken = "barkpark-dev-token"
	}

	// Workspace/Project/Dataset scope for the /w/:ws/p/:project/v1/ routing.
	workspace := os.Getenv("BARKPARK_WORKSPACE")
	if workspace == "" {
		workspace = "default"
	}
	project := os.Getenv("BARKPARK_PROJECT")
	if project == "" {
		project = "default"
	}
	dataset := os.Getenv("BARKPARK_DATASET")
	if dataset == "" {
		dataset = "production"
	}

	// Load schemas from Phoenix API
	fmt.Fprintf(os.Stderr, "Connecting to %s (workspace=%s project=%s dataset=%s)...\n", apiURL, workspace, project, dataset)
	if err := loadSchemas(apiURL, apiToken, workspace, project, dataset); err != nil {
		fmt.Fprintf(os.Stderr, "Error loading schemas: %v\n", err)
		fmt.Fprintf(os.Stderr, "Is the Phoenix API running? Start it with: cd api && mix phx.server\n")
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "Loaded %d schemas\n", len(schemas))

	// Build structure tree (auto-generated from schemas)
	initRootStructure()

	// Create API client
	ds := NewDataStore(apiURL)
	ds.SetToken(apiToken)
	ds.Workspace = workspace
	ds.Project = project
	ds.Dataset = dataset

	// Start TUI
	p := tea.NewProgram(initialModel(ds), tea.WithAltScreen())
	ds.SetProgram(p)
	go ds.StartSSE(apiToken)

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
