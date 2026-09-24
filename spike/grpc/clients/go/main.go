// goclient makes unary calls with grpc-go's defaults, a raw codec so no
// generated code is involved: `-n` calls, `-c` of them at once, one channel.
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"log"
	"math/rand"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding"
	_ "google.golang.org/grpc/encoding/gzip"
)

type raw struct{}

func (raw) Marshal(v any) ([]byte, error)      { return *(v.(*[]byte)), nil }
func (raw) Unmarshal(d []byte, v any) error    { *(v.(*[]byte)) = append([]byte(nil), d...); return nil }
func (raw) Name() string                       { return "proto" }

func main() {
	target := flag.String("target", "127.0.0.1:50051", "")
	n := flag.Int("n", 32, "")
	c := flag.Int("c", 16, "")
	size := flag.Int("size", 200, "request message bytes")
	gz := flag.Bool("gzip", false, "")
	random := flag.Bool("random", false, "fill the message with random bytes rather than zeros")
	useTLS := flag.Bool("tls", false, "dial with TLS, not checking the certificate (the suite's own is self-signed)")
	flag.Parse()
	encoding.RegisterCodec(raw{})
	creds := insecure.NewCredentials()
	if *useTLS {
		creds = credentials.NewTLS(&tls.Config{InsecureSkipVerify: true})
	}
	conn, err := grpc.NewClient(*target, grpc.WithTransportCredentials(creds))
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	msg := make([]byte, *size)
	if *random {
		rand.Read(msg)
	}
	var wg sync.WaitGroup
	sem := make(chan struct{}, *c)
	start := time.Now()
	for i := 0; i < *n; i++ {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			var out []byte
			opts := []grpc.CallOption{}
			if *gz {
				opts = append(opts, grpc.UseCompressor("gzip"))
			}
			in := msg
			if err := conn.Invoke(context.Background(), "/opentelemetry.proto.collector.trace.v1.TraceService/Export", &in, &out, opts...); err != nil {
				log.Printf("call: %v", err)
			}
		}()
	}
	wg.Wait()
	log.Printf("grpc-go: %d calls in %s", *n, time.Since(start))
}
