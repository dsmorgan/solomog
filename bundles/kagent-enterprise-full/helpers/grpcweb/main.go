// grpcweb calls an enterprise kagent API that's served only as gRPC-Web, from JSON.
//
// The controller serves the community kagent API as native gRPC on :8083, but the enterprise
// services the UI uses (evals, auth config) live on :8085, an HTTP/1 surface that speaks gRPC-Web
// with protobuf bodies only. This client reads the message types from the controller's gRPC
// reflection on :8083 (config.server.grpcReflection), turns a JSON request into protobuf, posts it
// as one gRPC-Web frame, and prints each response message as one line of JSON.
//
//	TOKEN=<bearer> grpcweb -reflect 127.0.0.1:8083 -url http://127.0.0.1:8085/api \
//	  rpc.evals.solo.io.EvalSets/List '{"limit":10}'
//
// Exit status: 0 on grpc-status 0, 2 on any other status (printed to stderr), 1 on a local error.
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	rpb "google.golang.org/grpc/reflection/grpc_reflection_v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

func main() {
	reflectAddr := flag.String("reflect", "127.0.0.1:8083", "controller gRPC address with reflection")
	url := flag.String("url", "http://127.0.0.1:8085/api", "gRPC-Web base URL")
	timeout := flag.Duration("timeout", 30*time.Second, "overall timeout")
	flag.Parse()
	if flag.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "usage: grpcweb [flags] package.Service/Method [json]")
		os.Exit(1)
	}
	method, body := flag.Arg(0), "{}"
	if flag.NArg() > 1 {
		body = flag.Arg(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	token := os.Getenv("TOKEN")

	svc, name, ok := strings.Cut(method, "/")
	if !ok {
		die("method must be package.Service/Method, got %q", method)
	}
	files, err := resolve(ctx, *reflectAddr, token, svc)
	if err != nil {
		die("reflection: %v", err)
	}
	d, err := files.FindDescriptorByName(protoreflect.FullName(svc))
	if err != nil {
		die("service %s: %v", svc, err)
	}
	sd, ok := d.(protoreflect.ServiceDescriptor)
	if !ok {
		die("%s is not a service", svc)
	}
	md := sd.Methods().ByName(protoreflect.Name(name))
	if md == nil {
		die("no method %s on %s", name, svc)
	}
	types := dynamicTypes(files)
	in := dynamicpb.NewMessage(md.Input())
	if err := (protojson.UnmarshalOptions{Resolver: types}).Unmarshal([]byte(body), in); err != nil {
		die("request JSON: %v", err)
	}
	raw, err := proto.Marshal(in)
	if err != nil {
		die("marshal: %v", err)
	}
	frame := make([]byte, 5+len(raw))
	binary.BigEndian.PutUint32(frame[1:5], uint32(len(raw)))
	copy(frame[5:], raw)

	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(*url, "/")+"/"+method, bytes.NewReader(frame))
	req.Header.Set("Content-Type", "application/grpc-web+proto")
	req.Header.Set("X-Grpc-Web", "1")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		die("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		fmt.Fprintf(os.Stderr, "HTTP %d: %s\n", resp.StatusCode, strings.TrimSpace(string(b)))
		os.Exit(2)
	}
	status, msg := resp.Header.Get("Grpc-Status"), resp.Header.Get("Grpc-Message")
	out := protojson.MarshalOptions{Resolver: types, EmitUnpopulated: false}
	for {
		hdr := make([]byte, 5)
		if _, err := io.ReadFull(resp.Body, hdr); err != nil {
			break
		}
		payload := make([]byte, binary.BigEndian.Uint32(hdr[1:5]))
		if _, err := io.ReadFull(resp.Body, payload); err != nil {
			die("short frame: %v", err)
		}
		if hdr[0]&0x80 != 0 { // trailers, as HTTP header lines
			for _, line := range strings.Split(string(payload), "\r\n") {
				k, v, _ := strings.Cut(line, ":")
				switch strings.ToLower(strings.TrimSpace(k)) {
				case "grpc-status":
					status = strings.TrimSpace(v)
				case "grpc-message":
					msg = strings.TrimSpace(v)
				}
			}
			continue
		}
		m := dynamicpb.NewMessage(md.Output())
		if err := proto.Unmarshal(payload, m); err != nil {
			die("response: %v", err)
		}
		j, _ := out.Marshal(m)
		fmt.Println(string(j))
	}
	if status != "" && status != "0" {
		fmt.Fprintf(os.Stderr, "grpc-status %s: %s\n", status, msg)
		os.Exit(2)
	}
}

// resolve asks the server's reflection service for the file declaring symbol and every file it
// imports, and returns them as a registry.
func resolve(ctx context.Context, addr, token, symbol string) (*protoregistry.Files, error) {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if token != "" {
		ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+token)
	}
	stream, err := rpb.NewServerReflectionClient(conn).ServerReflectionInfo(ctx)
	if err != nil {
		return nil, err
	}
	defer stream.CloseSend()
	seen := map[string]*descriptorpb.FileDescriptorProto{}
	ask := func(r *rpb.ServerReflectionRequest) error {
		if err := stream.Send(r); err != nil {
			return err
		}
		resp, err := stream.Recv()
		if err != nil {
			return err
		}
		if e := resp.GetErrorResponse(); e != nil {
			return fmt.Errorf("%s", e.GetErrorMessage())
		}
		for _, b := range resp.GetFileDescriptorResponse().GetFileDescriptorProto() {
			fd := &descriptorpb.FileDescriptorProto{}
			if err := proto.Unmarshal(b, fd); err != nil {
				return err
			}
			seen[fd.GetName()] = fd
		}
		return nil
	}
	if err := ask(&rpb.ServerReflectionRequest{MessageRequest: &rpb.ServerReflectionRequest_FileContainingSymbol{FileContainingSymbol: symbol}}); err != nil {
		return nil, err
	}
	// Fetch any import the server didn't send along, until the set is closed.
	for {
		var missing []string
		for _, fd := range seen {
			for _, dep := range fd.GetDependency() {
				if _, ok := seen[dep]; !ok {
					missing = append(missing, dep)
				}
			}
		}
		if len(missing) == 0 {
			break
		}
		for _, dep := range missing {
			if err := ask(&rpb.ServerReflectionRequest{MessageRequest: &rpb.ServerReflectionRequest_FileByFilename{FileByFilename: dep}}); err != nil {
				return nil, fmt.Errorf("%s: %w", dep, err)
			}
		}
	}
	set := &descriptorpb.FileDescriptorSet{}
	for _, fd := range seen {
		set.File = append(set.File, fd)
	}
	return protodesc.NewFiles(set)
}

// dynamicTypes registers every message in files, so protojson can resolve Any and well-known types.
func dynamicTypes(files *protoregistry.Files) *protoregistry.Types {
	t := new(protoregistry.Types)
	files.RangeFiles(func(fd protoreflect.FileDescriptor) bool {
		var walk func(protoreflect.MessageDescriptors)
		walk = func(ms protoreflect.MessageDescriptors) {
			for i := 0; i < ms.Len(); i++ {
				_ = t.RegisterMessage(dynamicpb.NewMessageType(ms.Get(i)))
				walk(ms.Get(i).Messages())
			}
		}
		walk(fd.Messages())
		return true
	})
	return t
}

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "grpcweb: "+format+"\n", a...)
	os.Exit(1)
}
