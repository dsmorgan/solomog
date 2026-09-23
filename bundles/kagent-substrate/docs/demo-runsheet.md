# Demo run sheet — agents that aren't pods

Written for whoever is driving the screen. Twelve minutes, three beats. The point to land
is that agent density is an infrastructure problem with an infrastructure answer, not a
prompt-engineering one.

## Before anyone joins

```bash
solomog test BUNDLE=kagent-substrate CLUSTER=<c>          # all green
bash bundles/kagent-substrate/helpers/scope.sh <c>        # http://localhost:8123
```

Leave scope open on the board. Have a second terminal ready for the stimulator, and the
kagent UI on `http://localhost:8001` if you plan to chat by hand.

The first turn after an install is the slowest one you will ever see — a cold actor is
restored from a snapshot before the model is called at all. Send one throwaway chat
before the call so the demo does not open on the worst number.

## Beat 1 — what kubectl doesn't show you (3 min)

Start in the terminal, not the UI.

```bash
kubectl --context <ctx> get pods -n kagent
```

Four SandboxAgents are defined. Count the pods running them: none. Then:

```bash
kubectl --context <ctx> get actortemplates.ate.dev -n kagent
```

Each agent has a golden snapshot sitting in object storage. **This is the whole idea.** An
idle agent is a compressed memory image, not a pod holding a CPU reservation. `kubectl get
pods` makes substrate look boring precisely because the interesting state isn't in pods.

Now switch to scope and let the board do the explaining.

## Beat 2 — watch a turn (4 min)

Chat one agent from the kagent UI, or from the terminal, and narrate the chip:

> storage → queue → worker → storage

The agent is restored onto a pre-warmed gVisor sandbox, runs its turn, is checkpointed
back, and the worker is free again. Click the agent to open its drawer: the prompt, the
reply, the latency, the restore and the checkpoint, all real.

Two things to say while it moves:

- **The sandbox is gVisor, not a container.** Agent code runs against a user-space kernel.
  That is the security posture that makes it reasonable to let an agent execute code at
  all.
- **The agent definition has nothing substrate-specific in it** except one `spec.substrate`
  block. Show `30-sandboxagents.yaml` if asked. The same declarative agent runs as an
  always-on pod or as a snapshot-backed actor; that block is the only thing that decides.

## Beat 3 — density, honestly (4 min)

```bash
bash bundles/kagent-substrate/helpers/scope.sh <c> --stimulate
```

Traffic starts. Chips move continuously, the restore queue becomes visible, and the
telemetry panel earns its place: reserved capacity — worker slots times unit — against the
dotted "if these were all always-on pods" line.

Be straight about what that line means. Idle pods use almost no CPU; they **reserve** it
forever. Reservation is the honest comparison, and it is the one that decides how many
agents fit on a cluster. Say that out loud rather than letting the gap speak for itself —
it is the claim a skeptical platform engineer will test, and it survives testing.

Then scale: hit worker **+** and **−**. That runs `kubectl scale workerpool` against the
real CR. Turn AUTOSCALE on and let demand drive it — the policy targets `busy + queued`,
not CPU, because workers are slot-bound and LLM turns are mostly I/O wait. CPU is the
wrong signal for this runtime and every autoscaler you already own uses it.

## The question you will get

**"Is this production?"** No. Agent Substrate is early — the version pairing between
kagent and substrate is tight, in-place upgrades across substrate patch versions are not
safe, and the pins in this bundle are deliberate rather than latest. Say so. What is real
is the shape of the answer: snapshot-restore density plus gVisor isolation, with
agentgateway already routing every request that reaches an actor.

## Cleanup

```bash
solomog teardown CLUSTER=<c>      # vind
kind delete cluster --name <c>    # kind
```
