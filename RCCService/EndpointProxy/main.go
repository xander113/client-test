package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

type routeFile struct {
	path     string
	lastRead []byte
	active   atomic.Pointer[router]
}

func (file *routeFile) reload() (bool, error) {
	data, err := os.ReadFile(file.path)
	if err != nil {
		return false, err
	}
	if file.lastRead != nil && bytes.Equal(file.lastRead, data) {
		return false, nil
	}
	file.lastRead = data
	routes, err := parseRoutes(data)
	if err != nil {
		return false, err
	}
	file.active.Store(routes)
	return true, nil
}

func (file *routeFile) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	file.active.Load().ServeHTTP(w, r)
}

func (file *routeFile) watch(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	var lastError string
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			changed, err := file.reload()
			if err != nil {
				if err.Error() != lastError {
					log.Printf("Keeping active endpoint routes after reload error: %v", err)
				}
				lastError = err.Error()
				continue
			}
			lastError = ""
			if changed {
				log.Print("Loaded updated endpoint routes")
			}
		}
	}
}

func serve(address, configPath string) error {
	file := &routeFile{path: configPath}
	if _, err := file.reload(); err != nil {
		return err
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go file.watch(ctx)
	server := &http.Server{
		Handler:           file,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       time.Minute,
	}
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			log.Printf("Endpoint proxy shutdown: %v", err)
		}
	}()
	log.Printf("Endpoint proxy listening on %s", listener.Addr())
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		<-shutdownDone
		return nil
	}
	return err
}

func main() {
	config := flag.String("config", "", "Private server file containing endpoint routes")
	listen := flag.String("listen", "127.0.0.1:8080", "Listen address behind the public HTTP server")
	flag.Parse()
	if *config == "" || flag.NArg() != 0 {
		flag.Usage()
		os.Exit(2)
	}
	if err := serve(*listen, *config); err != nil {
		log.Fatal(err)
	}
}
