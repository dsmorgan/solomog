# Draft issue: ateom-gvisor doesn't inherit the actor veth MTU

Not filed. Target repo: `agent-substrate/substrate`. Everything below the line is the issue
body; reproduced on substrate 0.0.9 with kagent 0.10.1, 2026-09-18.

Check before filing:

- Re-test on the 0.2.x line. This was found on 0.0.9, and `cmd/ateom-gvisor/` may have
  changed. The claim to re-verify is that the directory still contains no MTU handling.
- Search for an existing issue. Terms: `mtu`, `gvisor`, `egress`, `TLS handshake`.
- Decide whether to file against `agent-substrate/substrate` or `kagent-dev/substrate`. The
  code is the same, but kagent pins the fork, so a fix has to reach the fork to help kagent.
- Replace the vcluster reproduction with kind plus a VXLAN CNI if you want a reproduction the
  maintainers can run without vcluster. The bug needs only an overlay CNI, not vcluster.

---

## Actor egress fails on any CNI with an MTU below 1500

### What happens

An actor running under `ateom-gvisor` can resolve DNS and complete a TCP handshake to an
external host, then hangs on the first large exchange. Any HTTPS call out of the actor fails
during the TLS handshake:

```
OpenAI chat completion request failed: Post "https://api.openai.com/v1/chat/completions":
  net/http: TLS handshake timeout
```

Small packets pass and large ones disappear, which is a path MTU blackhole rather than a
reachability problem.

### Why

The gVisor actor's netstack uses 1500 regardless of the MTU on the veth it's attached to. On
a cluster whose CNI runs an overlay, pods get less than 1500 — 1450 for flannel in VXLAN
mode — so every segment the actor sends at its assumed MSS is too large for the path.

`cmd/ateom-microvm` already solves this. `cmd/ateom-microvm/net.go` reads the actor veth and
passes the value to the guest:

```go
// actorVethMTU reads the MTU of the actor veth (eth0 in the interior netns) so
// ateom can configure the guest eth0 with a matching MTU via the agent
func (s *AteomService) actorVethMTU(ctx context.Context) int {
```

`cmd/ateom-gvisor` contains no equivalent. A search for `mtu` across that directory returns
nothing, and the Helm chart exposes no MTU value either.

### Why this isn't caught

`hack/create-kind-cluster.sh` builds a kind cluster, and kindnet routes pod traffic without
an overlay at MTU 1500. The actor's assumption is correct there, so the development and e2e
path never meets the bug. Clusters that do use an overlay — Calico in IPIP mode, Cilium in
VXLAN mode, flannel in VXLAN mode, and most managed clusters configured this way — meet it
on the first outbound TLS call from an actor.

### Reproduction

1. Create a cluster whose pods get an MTU below 1500. Confirm it:

   ```
   kubectl exec -n ate-system valkey-cluster-0 -- cat /sys/class/net/eth0/mtu
   1450
   ```

2. Install substrate and run any actor that makes an outbound HTTPS request.

3. Observe the TLS handshake timeout. Confirm the path itself is healthy by making the same
   request from the node, which succeeds.

4. Clamp TCP MSS on the node so handshake segments fit the path:

   ```
   iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
   ```

5. Repeat the request. It succeeds.

### Evidence

Two agents on one cluster, sharing a credential and a model configuration, differing only in
whether they run as an actor:

| Agent | Runs as | Result |
| --- | --- | --- |
| `k8s-agent` | ordinary pod | completed |
| `explainer` | substrate actor | failed, TLS handshake timeout |

Turns attempted against the actor, changing nothing but the MSS clamp:

| MSS clamped on the node | Turns | Result |
| --- | --- | --- |
| no | 4 | all failed, TLS handshake timeout |
| yes | 1 | completed |

### Suggested fix

Give `ateom-gvisor` the veth-MTU inheritance `ateom-microvm` already has: read the actor
veth's MTU and configure the sandbox's interface to match, falling back to 1500 when the read
fails, as `actorVethMTU` does.

A Helm value for the MTU would also unblock affected users, but it makes every operator
discover and set a number the runtime can read for itself.

### Environment

| | |
| --- | --- |
| substrate | 0.0.9 (`ghcr.io/kagent-dev/substrate`) |
| kagent | 0.10.1, `controller.substrate.enabled=true` |
| sandbox class | gvisor, `ateom-gvisor:v0.0.9` |
| Kubernetes | 1.36.0 |
| CNI | flannel, VXLAN, pod MTU 1450 |
| Host | macOS on arm64, Docker Desktop |
