// a2a-turn drives turns against an enterprise kagent controller over gRPC: create a Session for an
// Agent, send it one A2A message, print the reply, delete the Session.
//
// Why not the community kagent CLI: the enterprise controller authenticates every call on
// :8083, and the community CLI has no way to send a bearer token on its API calls (its only
// --token is the model key it passes through on invoke). This is the call sequence enterprise
// kagent's own e2e test uses (test/e2e/session/interaction_test.go at 1.0.0-alpha6), with the
// token in the gRPC "authorization" metadata key, which the controller forwards to its
// authenticator.
//
// Since kagent 1.0.0-alpha7 an Agent pairs an AgentTemplate with a Harness, and the conversation
// is a Session. A2A names the Agent in the request's tenant (<namespace>/<agent>) and the Session
// in the message's context id; there are no routing headers.
//
// Modes, besides the default turn:
//
//	-probe          one read-only ListSessions; prints the gRPC code
//	-keep           leave the Session in place and print "session=<id>" on stdout; with no
//	                -text, create the Session and send nothing
//	-session ID     send to an existing Session instead of creating one
//	-get ID         print the Session's state, or NotFound
//	-suspend ID     suspend the Session, wait for the operation to finish, print its state
//	-resume ID      resume the Session the same way
//	-retry=false    report the first Unavailable instead of retrying it, to read the
//	                answer the controller gives when no worker can take the actor
//	-actors         SystemService.ListSubstrateActors (with -atespace, one atespace), printed as
//	                protojson
//
// kagent 1.0.0-alpha14 (kagent#3184) moved the API from kagent.api.v1alpha1 to kagent.api.v1:
// same messages, new service names, so a client built on v1alpha1 gets Unimplemented.
//
// The token comes from the caller (TOKEN env). tests/ gets one from the bundled auto-auth IdP,
// which issues an admin token to anyone who asks; see helpers/checks.sh.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	a2atype "github.com/a2aproject/a2a-go/v2/a2a"
	a2apb "github.com/a2aproject/a2a-go/v2/a2apb/v1"
	"github.com/a2aproject/a2a-go/v2/a2apb/v1/pbconv"
	"github.com/google/uuid"
	apiv1 "github.com/kagent-dev/kagent/go/api/gen/kagent/api/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8083", "controller gRPC address")
	ns := flag.String("namespace", "", "Agent namespace")
	agent := flag.String("agent", "triage", "Agent name")
	text := flag.String("text", "", "message to send")
	user := flag.String("user", "admin", "x-user-id metadata")
	timeout := flag.Duration("timeout", 4*time.Minute, "overall timeout")
	probe := flag.Bool("probe", false, "authorization probe only: one read-only ListSessions; "+
		"prints the gRPC code; exit 0 = allowed, 3 = PermissionDenied, 1 = anything else")
	keep := flag.Bool("keep", false, "leave the Session in place and print its id")
	sessionID := flag.String("session", "", "send to this existing Session")
	getID := flag.String("get", "", "print this Session's state, or NotFound; exit 0 found, 4 NotFound")
	suspendID := flag.String("suspend", "", "suspend this Session and wait for the operation to finish")
	resumeID := flag.String("resume", "", "resume this Session and wait for the operation to finish")
	retry := flag.Bool("retry", true, "retry Unavailable while a cold Session's actor resumes")
	cancelID := flag.String("cancel", "", "A2A CancelTask on this task id (needs -namespace and -agent); prints its state")
	actors := flag.Bool("actors", false, "SystemService.ListSubstrateActors, printed as protojson")
	atespace := flag.String("atespace", "", "with -actors: list this atespace only")
	flag.Parse()
	token := os.Getenv("TOKEN")
	lifecycle := *suspendID != "" || *resumeID != ""
	if token == "" || (!*probe && !*actors && *getID == "" && !lifecycle && *cancelID == "" && (*ns == "" || (*text == "" && !*keep))) {
		fail("need TOKEN, plus -namespace and -text unless -probe, -get or -keep")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	ctx = metadata.AppendToOutgoingContext(ctx, "x-user-id", *user, "authorization", "Bearer "+token)

	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fail("dial %s: %v", *addr, err)
	}
	defer conn.Close()

	sessions := apiv1.NewSessionServiceClient(conn)
	if *probe {
		_, err := sessions.ListSessions(ctx, &apiv1.ListSessionsRequest{})
		code := status.Code(err)
		fmt.Println(code)
		switch code {
		case codes.OK:
			os.Exit(0)
		case codes.PermissionDenied:
			os.Exit(3)
		default:
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	if *actors {
		got, err := apiv1.NewSystemServiceClient(conn).ListSubstrateActors(ctx, &apiv1.ListSubstrateActorsRequest{Atespace: *atespace})
		if err != nil {
			fail("ListSubstrateActors: code=%s: %v", status.Code(err), err)
		}
		out, _ := protojson.Marshal(got)
		fmt.Println(string(out))
		os.Exit(0)
	}
	if *getID != "" {
		got, err := sessions.GetSession(ctx, &apiv1.GetSessionRequest{SessionId: *getID})
		switch status.Code(err) {
		case codes.OK:
			s := got.GetSession()
			fmt.Printf("state=%s operation=%s\n", s.GetState(), s.GetOperation())
			os.Exit(0)
		case codes.NotFound:
			fmt.Println("NotFound")
			os.Exit(4)
		default:
			fail("get Session %s: %v", *getID, err)
		}
	}

	if *cancelID != "" {
		t, err := a2apb.NewA2AServiceClient(conn).CancelTask(ctx, &a2apb.CancelTaskRequest{Tenant: *ns + "/" + *agent, Id: *cancelID})
		if err != nil {
			fail("A2A CancelTask %s: code=%s: %v", *cancelID, status.Code(err), err)
		}
		fmt.Printf("state=%s\n", t.GetStatus().GetState())
		os.Exit(0)
	}

	if lifecycle {
		id := *suspendID + *resumeID
		var err error
		if *suspendID != "" {
			_, err = sessions.SuspendSession(ctx, &apiv1.SuspendSessionRequest{SessionId: id})
		} else {
			_, err = sessions.ResumeSession(ctx, &apiv1.ResumeSessionRequest{SessionId: id})
		}
		if err != nil {
			fail("lifecycle call on Session %s: %v", id, err)
		}
		for {
			got, err := sessions.GetSession(ctx, &apiv1.GetSessionRequest{SessionId: id})
			if err != nil {
				fail("get Session %s: %v", id, err)
			}
			s := got.GetSession()
			if s.GetOperation() == apiv1.RuntimeOperation_RUNTIME_OPERATION_NONE {
				fmt.Printf("state=%s\n", s.GetState())
				if msg := s.GetFailure().GetMessage(); msg != "" {
					fmt.Printf("failure=%s\n", msg)
				}
				os.Exit(0)
			}
			select {
			case <-ctx.Done():
				fail("Session %s still in %s at timeout", id, s.GetOperation())
			case <-time.After(time.Second):
			}
		}
	}

	var session *apiv1.Session
	if *sessionID != "" {
		got, err := sessions.GetSession(ctx, &apiv1.GetSessionRequest{SessionId: *sessionID})
		if err != nil {
			fail("get Session %s: %v", *sessionID, err)
		}
		session = got.GetSession()
	} else {
		session = create(ctx, sessions, *ns, *agent)
		if !*keep {
			defer func() {
				dctx, dcancel := context.WithTimeout(metadata.NewOutgoingContext(context.Background(),
					metadata.Pairs("x-user-id", *user, "authorization", "Bearer "+token)), time.Minute)
				defer dcancel()
				deleteIdle(dctx, sessions, session.GetId())
			}()
		}
	}
	fmt.Fprintf(os.Stderr, "session %s state %s\n", session.GetId(), session.GetState())
	if *keep {
		fmt.Printf("session=%s\n", session.GetId())
		if *text == "" {
			return
		}
	}

	req, err := pbconv.ToProtoSendMessageRequest(&a2atype.SendMessageRequest{
		Message: a2atype.NewMessage(a2atype.MessageRoleUser, a2atype.NewTextPart(*text)),
	})
	if err != nil {
		fail("build A2A request: %v", err)
	}
	req.Tenant = *ns + "/" + *agent
	// The e2e test sends the Session id; the gateway compares against the Session's context id.
	req.Message.ContextId = session.GetContextId()
	if req.Message.ContextId == "" {
		req.Message.ContextId = session.GetId()
	}
	resp, err := sendWithRetry(ctx, a2apb.NewA2AServiceClient(conn), req, *retry)
	if err != nil {
		fail("A2A SendMessage: code=%s: %v", status.Code(err), err)
	}
	result, err := pbconv.FromProtoSendMessageResponse(resp)
	if err != nil {
		fail("decode A2A response: %v", err)
	}
	switch r := result.(type) {
	case *a2atype.Task:
		fmt.Printf("state=%s\n%s\n", r.Status.State, taskText(r))
		if r.Status.State != a2atype.TaskStateCompleted {
			os.Exit(1)
		}
	case *a2atype.Message:
		fmt.Println(partsText(r.Parts))
	default:
		fail("unexpected A2A response %T", result)
	}
}

// create makes a Session, retrying FailedPrecondition: an Agent can be Ready before it has a
// prepared revision a Session can pin, and the controller answers that gap with this code.
func create(ctx context.Context, sessions apiv1.SessionServiceClient, ns, agent string) *apiv1.Session {
	req := &apiv1.CreateSessionRequest{
		Agent:     &apiv1.ResourceReference{Namespace: ns, Name: agent},
		RequestId: uuid.NewString(),
	}
	for {
		created, err := sessions.CreateSession(ctx, req)
		if err == nil {
			s := created.GetSession()
			if s.GetState() != apiv1.RuntimeState_RUNTIME_STATE_READY {
				fail("Session not READY (%s): %s", s.GetState(), s.GetFailure().GetMessage())
			}
			return s
		}
		if status.Code(err) != codes.FailedPrecondition {
			fail("create Session for Agent %s/%s: %v", ns, agent, err)
		}
		select {
		case <-ctx.Done():
			fail("create Session for Agent %s/%s: still %v at timeout", ns, agent, err)
		case <-time.After(2 * time.Second):
		}
	}
}

// sendWithRetry retries only Unavailable, which the gateway returns while a cold Session's actor
// is still resuming. Anything else is the answer. With retry false, Unavailable is the answer too.
func sendWithRetry(ctx context.Context, c a2apb.A2AServiceClient, req *a2apb.SendMessageRequest, retry bool) (*a2apb.SendMessageResponse, error) {
	for {
		resp, err := c.SendMessage(ctx, req)
		if !retry || status.Code(err) != codes.Unavailable {
			return resp, err
		}
		fmt.Fprintf(os.Stderr, "send: %v; retrying\n", err)
		select {
		case <-ctx.Done():
			return nil, err
		case <-time.After(3 * time.Second):
		}
	}
}

// deleteIdle deletes the Session once its lifecycle work lets go of it. The controller answers
// FailedPrecondition while automatic suspension still owns the Session.
func deleteIdle(ctx context.Context, sessions apiv1.SessionServiceClient, id string) {
	for {
		_, err := sessions.DeleteSession(ctx, &apiv1.DeleteSessionRequest{SessionId: id})
		switch status.Code(err) {
		case codes.OK, codes.NotFound:
			return
		case codes.FailedPrecondition:
		default:
			fmt.Fprintf(os.Stderr, "delete Session %s: %v\n", id, err)
			return
		}
		select {
		case <-ctx.Done():
			fmt.Fprintf(os.Stderr, "delete Session %s: still owned at timeout\n", id)
			return
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func taskText(t *a2atype.Task) string {
	var out []string
	if t.Status.Message != nil {
		out = append(out, partsText(t.Status.Message.Parts))
	}
	for _, a := range t.Artifacts {
		out = append(out, partsText(a.Parts))
	}
	return strings.Join(out, "\n")
}

func partsText(parts a2atype.ContentParts) string {
	var out []string
	for _, p := range parts {
		// A structured result is a data part; print it as JSON with a "data=" prefix so a test
		// can tell it from text. It has crossed gRPC as a protobuf Struct, whose numbers are
		// doubles, so an integer above 2^53 arrives here already rounded.
		if _, ok := p.Content.(a2atype.Data); ok {
			b, err := json.Marshal(p.Data())
			if err != nil {
				b = []byte(err.Error())
			}
			out = append(out, "data="+string(b))
			continue
		}
		out = append(out, p.Text())
	}
	return strings.Join(out, "\n")
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "a2a-turn: "+format+"\n", a...)
	os.Exit(1)
}
