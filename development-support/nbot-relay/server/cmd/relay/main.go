package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"nbot/relay/relay"
)

func run() error {
	configPath := flag.String("config", "", "JSON 配置路径；省略时使用默认配置")
	flag.Parse()
	config := relay.DefaultConfig()
	if *configPath != "" {
		file, err := os.Open(*configPath)
		if err != nil {
			return err
		}
		config, err = relay.LoadConfig(file)
		file.Close()
		if err != nil {
			return err
		}
	}
	app, err := relay.New(config)
	if err != nil {
		return err
	}
	server := app.HTTPServer()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	finished := make(chan error, 1)
	go func() { finished <- server.ListenAndServe() }()
	log.Printf("relay listening=%s max_tasks=%d timeout=%s", config.Listen, relay.MaxTasks, relay.RequestTimeout)
	select {
	case err := <-finished:
		app.Broker.Stop()
		return err
	case <-ctx.Done():
		app.Broker.Stop()
		deadline, cancel := context.WithTimeout(context.Background(), 6*time.Second)
		defer cancel()
		if err := server.Shutdown(deadline); err != nil {
			_ = server.Close()
			return err
		}
		return nil
	}
}

func main() {
	if err := run(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Print(err)
		os.Exit(1)
	}
}
