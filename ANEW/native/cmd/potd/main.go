package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"pot.local/runtime/internal/desktop"
	"pot.local/runtime/internal/hub"
)

func env(name, fallback string) string {
	if s := os.Getenv(name); s != "" {
		return s
	}
	return fallback
}

func run(ctx context.Context, mode string) error {
	switch mode {
	case "desktop":
		return desktop.Run(os.Stdin, os.Stdout)
	case "render":
		address := net.JoinHostPort(env("POT_RENDER_HOST", "127.0.0.1"), env("POT_RENDER_PORT", "4812"))
		server, err := hub.StartRender(address, os.Getenv("POT_RENDER_TOKEN"))
		if err != nil {
			return err
		}
		fmt.Println("PotRenderService listening at", server.URL)
		<-ctx.Done()
		return server.Close()
	case "worlds":
		config := hub.Config{
			Address:   net.JoinHostPort(env("POT_WORLD_HOST", "127.0.0.1"), env("POT_WORLD_PORT", "4831")),
			DataDir:   os.Getenv("POT_WORLD_DATA_DIR"),
			ReadToken: os.Getenv("POT_WORLD_READ_TOKEN"), WriteToken: os.Getenv("POT_WORLD_WRITE_TOKEN"),
			RenderURL: os.Getenv("POT_RENDER_ENDPOINT"), RenderToken: os.Getenv("POT_RENDER_TOKEN"),
			BrowserOrigin: os.Getenv("POT_WORLD_BROWSER_ORIGIN"),
		}
		if config.RenderURL == "" {
			key, err := desktop.Credential()
			if err != nil {
				return err
			}
			prs, err := hub.StartRender("127.0.0.1:0", key)
			if err != nil {
				return err
			}
			defer prs.Close()
			config.RenderURL, config.RenderToken = prs.URL, key
		}
		server, err := hub.StartWorlds(config)
		if err != nil {
			return err
		}
		fmt.Println("Pot world service listening at", server.URL)
		<-ctx.Done()
		return server.Close()
	default:
		return errors.New("usage: potd desktop | worlds | render")
	}
}

func main() {
	if len(os.Args) != 2 {
		log.Fatal("usage: potd desktop | worlds | render")
	}
	// The desktop exits on pipe closure. The hosted commands handle OS signals.
	if os.Args[1] == "desktop" {
		if err := run(context.Background(), os.Args[1]); err != nil {
			log.Fatal(err)
		}
		return
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1]); err != nil {
		log.Fatal(err)
	}
}
