module solomog.local/a2a-turn

go 1.27.0

require (
	github.com/a2aproject/a2a-go/v2 v2.6.0
	github.com/google/uuid v1.6.0
	github.com/kagent-dev/kagent/go v0.0.0-20261016134445-673d181ec269
	google.golang.org/grpc v1.84.0
	google.golang.org/protobuf v1.36.12
)

require (
	buf.build/gen/go/bufbuild/protovalidate/protocolbuffers/go v1.36.12-20260825204119-511051f7f437.2 // indirect
	github.com/agent-substrate/substrate v0.0.0 // indirect
	golang.org/x/net v0.61.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20261005182115-fad411399dd8 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20261005182115-fad411399dd8 // indirect
)

// kagent's own go.mod carries this replace, and replaces don't propagate to dependents.
replace github.com/agent-substrate/substrate => github.com/kagent-dev/substrate v0.5.0-alpha2
