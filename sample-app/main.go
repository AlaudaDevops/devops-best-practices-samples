// Series: the delivery article — sample application: a minimal HTTP "hello" service built
// and delivered by the pipelines in .tekton/, cd/ and promotion/.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// version is overridden at build time with -ldflags "-X main.version=<value>";
// the default keeps local runs self-describing.
var version = "dev"

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	// "GET /{$}" matches only the root path, so unknown paths return 404
	// instead of the greeting.
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintf(w, "hello from shop (%s)\n", version)
	})
	// Liveness and readiness probe endpoint; it must stay dependency-free so a
	// slow downstream never restarts the pod.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintln(w, "ok")
	})
	return mux
}

func main() {
	addr := ":8080"
	// PORT lets the platform move the listener without rebuilding the image;
	// 8080 matches containerPort in the GitOps template.
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}
	srv := &http.Server{
		Addr:              addr,
		Handler:           newMux(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("listening on %s", addr)
		// ErrServerClosed is the normal result of Shutdown, not a failure.
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	// Give in-flight requests a bounded grace period when Kubernetes sends
	// SIGTERM during a rollout.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}
