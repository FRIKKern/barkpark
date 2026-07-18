package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"

	"github.com/charmbracelet/x/ansi"
)

type metrics struct {
	MaxDisplayWidth int `json:"max_display_width"`
	OverflowLines   int `json:"overflow_lines"`
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: widthcheck <rendered-file> <max-columns>")
		os.Exit(2)
	}
	limit, err := strconv.Atoi(os.Args[2])
	if err != nil || limit < 1 {
		fmt.Fprintln(os.Stderr, "max-columns must be a positive integer")
		os.Exit(2)
	}
	file, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer file.Close()

	result := metrics{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		width := ansi.StringWidth(scanner.Text())
		if width > result.MaxDisplayWidth {
			result.MaxDisplayWidth = width
		}
		if width > limit {
			result.OverflowLines++
		}
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}
