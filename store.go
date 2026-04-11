package main

import (
	"fmt"
	"strings"
	"time"
)

// Doc represents a single document in the store.
type Doc struct {
	ID        string
	Title     string
	Status    string
	Category  string
	Author    string
	UpdatedAt time.Time
	Values    map[string]string // extra field values
}

// ── Seed data ────────────────────────────────────────────────────────────────
// Replace this with an API client or database in production.

var store = map[string][]Doc{
	"post": {
		{ID: "p1", Title: "Getting Started with Structured Content", Status: "published", Category: "Technology", Author: "Knut Melvær", UpdatedAt: time.Now().Add(-2 * time.Hour)},
		{ID: "p2", Title: "Why Headless CMS Changes Everything", Status: "published", Category: "Technology", Author: "Simeon Griggs", UpdatedAt: time.Now().Add(-26 * time.Hour)},
		{ID: "p3", Title: "Content Modeling Best Practices", Status: "draft", Category: "Engineering", Author: "Knut Melvær", UpdatedAt: time.Now().Add(-50 * time.Hour)},
		{ID: "p4", Title: "Building with Portable Text", Status: "draft", Category: "Engineering", Author: "Simeon Griggs", UpdatedAt: time.Now().Add(-74 * time.Hour)},
		{ID: "p5", Title: "Real-time Collaboration in Practice", Status: "published", Category: "Design", Author: "Knut Melvær", UpdatedAt: time.Now().Add(-98 * time.Hour)},
		{ID: "p6", Title: "GROQ vs GraphQL Deep Dive", Status: "draft", Category: "Technology", Author: "Simeon Griggs", UpdatedAt: time.Now().Add(-122 * time.Hour)},
		{ID: "p7", Title: "Design Systems for Content Teams", Status: "published", Category: "Design", Author: "Knut Melvær", UpdatedAt: time.Now().Add(-146 * time.Hour)},
		{ID: "p8", Title: "Deploying Studio to Production", Status: "published", Category: "Engineering", Author: "Simeon Griggs", UpdatedAt: time.Now().Add(-170 * time.Hour)},
	},
	"page": {
		{ID: "pg1", Title: "Home", Status: "published", UpdatedAt: time.Now().Add(-4 * time.Hour)},
		{ID: "pg2", Title: "About Us", Status: "published", UpdatedAt: time.Now().Add(-48 * time.Hour)},
		{ID: "pg3", Title: "Pricing", Status: "draft", UpdatedAt: time.Now().Add(-120 * time.Hour)},
		{ID: "pg4", Title: "Contact", Status: "published", UpdatedAt: time.Now().Add(-168 * time.Hour)},
		{ID: "pg5", Title: "Terms of Service", Status: "published", UpdatedAt: time.Now().Add(-240 * time.Hour)},
	},
	"author": {
		{ID: "a1", Title: "Knut Melvær", Status: "published", UpdatedAt: time.Now().Add(-300 * time.Hour), Values: map[string]string{"role": "admin", "email": "knut@sanity.io"}},
		{ID: "a2", Title: "Simeon Griggs", Status: "published", UpdatedAt: time.Now().Add(-360 * time.Hour), Values: map[string]string{"role": "editor", "email": "simeon@sanity.io"}},
		{ID: "a3", Title: "Espen Hovlandsdal", Status: "published", UpdatedAt: time.Now().Add(-420 * time.Hour), Values: map[string]string{"role": "writer", "email": "espen@sanity.io"}},
	},
	"category": {
		{ID: "c1", Title: "Technology", Status: "published", UpdatedAt: time.Now().Add(-600 * time.Hour), Values: map[string]string{"color": "#3b82f6"}},
		{ID: "c2", Title: "Design", Status: "published", UpdatedAt: time.Now().Add(-624 * time.Hour), Values: map[string]string{"color": "#ec4899"}},
		{ID: "c3", Title: "Engineering", Status: "published", UpdatedAt: time.Now().Add(-648 * time.Hour), Values: map[string]string{"color": "#10b981"}},
	},
	"project": {
		{ID: "pr1", Title: "Website Redesign", Status: "active", UpdatedAt: time.Now().Add(-8 * time.Hour), Values: map[string]string{"client": "Acme Corp"}},
		{ID: "pr2", Title: "Mobile App v3", Status: "planning", UpdatedAt: time.Now().Add(-52 * time.Hour), Values: map[string]string{"client": "StartupX"}},
		{ID: "pr3", Title: "API Migration", Status: "completed", UpdatedAt: time.Now().Add(-200 * time.Hour), Values: map[string]string{"client": "BigCo"}},
		{ID: "pr4", Title: "Design System", Status: "active", UpdatedAt: time.Now().Add(-270 * time.Hour), Values: map[string]string{"client": "Internal"}},
	},
	"siteSettings": {
		{ID: "siteSettings", Title: "My Studio Site", Status: "published", UpdatedAt: time.Now().Add(-240 * time.Hour), Values: map[string]string{"description": "A headless CMS powered site", "analyticsId": "G-XXXXXXXXXX"}},
	},
	"navigation": {
		{ID: "navigation", Title: "Main Navigation", Status: "published", UpdatedAt: time.Now().Add(-300 * time.Hour)},
	},
	"colors": {
		{ID: "colors", Title: "Brand Colors", Status: "published", UpdatedAt: time.Now().Add(-360 * time.Hour), Values: map[string]string{"primary": "#3b82f6", "secondary": "#6366f1", "accent": "#f59e0b"}},
	},
}

// queryDocs returns documents for a type, optionally filtered.
// Filter format: "field=value" (e.g. "status=published", "category=Design").
func queryDocs(typeName, filter string) []Doc {
	docs := store[typeName]
	if filter == "" {
		return docs
	}

	parts := strings.SplitN(filter, "=", 2)
	if len(parts) != 2 {
		return docs
	}
	field, value := parts[0], parts[1]

	var result []Doc
	for _, d := range docs {
		match := false
		switch field {
		case "status":
			match = d.Status == value
		case "category":
			match = d.Category == value
		case "author":
			match = d.Author == value
		default:
			if d.Values != nil {
				match = d.Values[field] == value
			}
		}
		if match {
			result = append(result, d)
		}
	}
	return result
}

// timeAgo returns a human-readable relative time string.
func timeAgo(t time.Time) string {
	d := time.Since(t)
	if d.Minutes() < 60 {
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	}
	if d.Hours() < 24 {
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
	return fmt.Sprintf("%dd ago", int(d.Hours()/24))
}

// statusIcon returns a unicode indicator for a document status.
func statusIcon(status string) string {
	switch status {
	case "published":
		return "●"
	case "draft":
		return "○"
	case "active":
		return "◆"
	case "planning":
		return "◇"
	case "completed":
		return "✓"
	default:
		return "·"
	}
}
