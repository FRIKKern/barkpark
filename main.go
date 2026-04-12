package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	apiURL := "http://localhost:4000"
	if env := os.Getenv("SANITY_API_URL"); env != "" {
		apiURL = env
	}

	// Load schemas from Phoenix API
	fmt.Fprintf(os.Stderr, "Connecting to %s...\n", apiURL)
	if err := loadSchemas(apiURL); err != nil {
		fmt.Fprintf(os.Stderr, "Error loading schemas: %v\n", err)
		fmt.Fprintf(os.Stderr, "Is the Phoenix API running? Start it with: cd ../sanity_api && mix phx.server\n")
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "Loaded %d schemas\n", len(schemas))

	// Build structure tree (requires schemas to be loaded first)
	initRootStructure()

	// Create API client
	ds := NewDataStore(apiURL)

	// Start TUI
	p := tea.NewProgram(initialModel(ds), tea.WithAltScreen())
	ds.SetProgram(p)
	go ds.StartPolling()

	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
