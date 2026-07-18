// Command htmlcheck extracts evidence from the authored Paper body of an HTML
// reader response. It deliberately ignores page chrome so a successful shell
// cannot masquerade as readable Paper content.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/net/html"
)

type metrics struct {
	BodyFound    bool   `json:"body_found"`
	Meaningful   bool   `json:"meaningful"`
	VisibleChars int    `json:"visible_chars"`
	VisibleWords int    `json:"visible_words"`
	HeadingCount int    `json:"heading_count"`
	TextSHA256   string `json:"text_sha256"`
	LinkCount    int    `json:"link_count"`
	InvalidLinks int    `json:"invalid_links"`
	LinksValid   bool   `json:"links_valid"`
}

func main() {
	if len(os.Args) != 3 || (os.Args[1] != "gui" && os.Args[1] != "email") {
		fmt.Fprintln(os.Stderr, "usage: htmlcheck <gui|email> <html-file>")
		os.Exit(2)
	}

	f, err := os.Open(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer f.Close()

	doc, err := html.Parse(f)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	target := findTarget(doc, os.Args[1])
	result := metrics{BodyFound: target != nil, LinksValid: true}
	if target != nil {
		var parts []string
		collectVisible(target, false, &parts, &result.HeadingCount)
		text := strings.Join(strings.Fields(strings.Join(parts, " ")), " ")
		sum := sha256.Sum256([]byte(text))
		result.Meaningful = hasSemanticText(text)
		result.VisibleChars = utf8.RuneCountInString(text)
		result.VisibleWords = len(strings.Fields(text))
		result.TextSHA256 = hex.EncodeToString(sum[:])
		if os.Args[1] == "email" {
			result.LinkCount, result.InvalidLinks = linkMetrics(target, false)
			result.LinksValid = result.InvalidLinks == 0
		}
	}

	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func linkMetrics(n *html.Node, hidden bool) (total, invalid int) {
	if n.Type == html.ElementNode {
		hidden = hidden || isHiddenElement(n)
		if !hidden && n.Data == "a" && hasAttribute(n, "href") {
			total++
			if !portableEmailHref(attribute(n, "href")) {
				invalid++
			}
		}
	}
	for child := n.FirstChild; child != nil; child = child.NextSibling {
		childTotal, childInvalid := linkMetrics(child, hidden)
		total += childTotal
		invalid += childInvalid
	}
	return total, invalid
}

func portableEmailHref(raw string) bool {
	href := strings.TrimSpace(raw)
	if strings.HasPrefix(href, "#") {
		return true
	}
	parsed, err := url.Parse(href)
	if err != nil || parsed.Scheme == "" {
		return false
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https", "mailto", "tel":
		return true
	default:
		return false
	}
}

func hasSemanticText(text string) bool {
	return strings.IndexFunc(text, func(r rune) bool {
		return unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.Is(unicode.Symbol, r)
	}) >= 0
}

func findTarget(n *html.Node, mode string) *html.Node {
	if n.Type == html.ElementNode {
		if mode == "email" && n.Data == "body" {
			return n
		}
		if mode == "gui" && n.Data == "article" && attribute(n, "id") == "paper-body" {
			return n
		}
	}
	for child := n.FirstChild; child != nil; child = child.NextSibling {
		if found := findTarget(child, mode); found != nil {
			return found
		}
	}
	return nil
}

func collectVisible(n *html.Node, hidden bool, parts *[]string, headings *int) {
	if n.Type == html.ElementNode {
		hidden = hidden || isHiddenElement(n)
		if !hidden && len(n.Data) == 2 && n.Data[0] == 'h' && n.Data[1] >= '1' && n.Data[1] <= '6' {
			(*headings)++
		}
		if !hidden && n.Data == "img" {
			if alt := strings.TrimSpace(attribute(n, "alt")); alt != "" {
				*parts = append(*parts, alt)
			}
		}
	}
	if n.Type == html.TextNode && !hidden {
		if text := strings.TrimSpace(n.Data); text != "" {
			*parts = append(*parts, text)
		}
	}
	for child := n.FirstChild; child != nil; child = child.NextSibling {
		collectVisible(child, hidden, parts, headings)
	}
}

func isHiddenElement(n *html.Node) bool {
	switch n.Data {
	case "script", "style", "template", "noscript", "svg":
		return true
	}
	return hasAttribute(n, "hidden") || strings.EqualFold(attribute(n, "aria-hidden"), "true")
}

func attribute(n *html.Node, name string) string {
	for _, attr := range n.Attr {
		if attr.Key == name {
			return attr.Val
		}
	}
	return ""
}

func hasAttribute(n *html.Node, name string) bool {
	for _, attr := range n.Attr {
		if attr.Key == name {
			return true
		}
	}
	return false
}
