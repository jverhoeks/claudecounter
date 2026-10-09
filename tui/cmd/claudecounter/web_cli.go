package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/jverhoeks/claudecounter/tui/internal/dashboard"
	"github.com/jverhoeks/claudecounter/tui/internal/webdash"
)

// runWebDashboards serves the dashboards on a random loopback port and
// opens the browser there (unless open is false); it runs until
// interrupted.
func runWebDashboards(load dashboard.Loader, open bool) {
	l, err := webdash.Listen()
	if err != nil {
		fmt.Fprintln(os.Stderr, "web-dashboards:", err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := webdash.Run(ctx, load, l, open, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "web-dashboards:", err)
		os.Exit(1)
	}
}
