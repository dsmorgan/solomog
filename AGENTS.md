# AGENTS.md

Architecture, conventions, and how-to-extend details live in [CLAUDE.md](CLAUDE.md)
and [README.md](README.md) — read those first. This file only adds guidance for
running the codebase inside a **Cursor Cloud** agent VM (Linux), which differs from
the tool's native target (macOS + Docker Desktop).

## Cursor Cloud specific instructions

`solomog` is a CLI (go-task + helmfile) that stands up local **vcluster (vind)**
Kubernetes clusters and installs Solo.io products onto them. Standard commands are in
[README.md](README.md) / [CLAUDE.md](CLAUDE.md); `solomog` (no args) lists every task.

The system tools (`docker`, `kubectl`, `helm`, `helmfile` v1, `task`, `vcluster`,
`step`, `mkcert`, `uv`, plus the `helm-diff` plugin and a `k3s` binary) are already
installed in the VM image, and `/etc/docker/daemon.json` + `iptables-legacy` are
pre-configured. You do **not** need to reinstall them. `scripts/setup.sh` is macOS/Homebrew
only — do not run it here.

### Hard limitation: no real Kubernetes *node* runs in this VM

This Firecracker VM **cannot delegate the `memory`/`io` cgroup v2 controllers**
(writing `+memory` to `cgroup.subtree_control` returns `Operation not supported`, and
`docker run --memory=…` fails with `domain controllers … threaded mode`). Docker
containers run fine *without* memory limits, but **anything that runs a kubelet/kubepods
refuses to start**. Consequences:

- The **vcluster docker driver (vind)** — solomog's default cluster backend
  (`scripts/vind-create.sh`) — **cannot start** (its node container dies in the
  cgroup/systemd bootstrap). `kind`, `minikube`, and a full `k3s` agent fail the same way.
- Therefore `solomog stack` / `istio:*` / `kgateway` / `agentgateway` / `gloo-gateway`
  etc. that **create and use a vind cluster will not complete** here, and any product
  install (all use `wait: true`) would hang on `Pending` pods even against a node-less
  cluster. This is an environment constraint, **not** a solomog bug — do not try to "fix"
  it in the code.

### What works, and how to exercise solomog end-to-end

Everything that doesn't need a schedulable pod works against a **control-plane-only
Kubernetes API server** via solomog's built-in **external-cluster path** (`CONTEXT=`,
see `scripts/lib/target.sh`): CLI/help, `bundles:list`/`show`, `versions:show`,
`helmfile build`/`template` (pulls the real community charts — good install-machinery
check), and `solomog apply` / `solomog test` for pod-free bundles.

Start the services (they do NOT persist across VM restarts — this is session startup, so
it's intentionally not in the update script):

```bash
# 1) Docker daemon (config already on disk). Run it in a tmux session, then fix the socket.
sudo dockerd >/tmp/dockerd.log 2>&1 &      # or a tmux session
sleep 6
sudo ln -sf /var/run/docker.sock /run/docker.sock   # vcluster/others hardcode /run/docker.sock
sudo chmod 666 /var/run/docker.sock

# 2) A real (control-plane-only) k8s API server. --disable-agent avoids the kubelet cgroup
#    wall above; --snapshotter=fuse-overlayfs avoids the (unsupported) native overlay driver.
sudo k3s server --write-kubeconfig-mode 644 --snapshotter=fuse-overlayfs \
  --disable-agent --disable=traefik,servicelb,metrics-server,local-storage \
  >/tmp/k3s.log 2>&1 &                       # or a tmux session
sleep 30
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config \
  && sudo chown "$(id -u):$(id -g)" ~/.kube/config
kubectl config rename-context default k3s-hello 2>/dev/null; kubectl config use-context k3s-hello
```

Then drive solomog against it as an external cluster (the `example` bundle is the
dependency-free hello-world — creates a Namespace + templated ConfigMap + Secret, no pods):

```bash
./solomog apply BUNDLE=example CLUSTER=hello-world CONTEXT=k3s-hello GATEWAY=agw HOST=agw.hello-world.test
./solomog test  BUNDLE=example CLUSTER=hello-world CONTEXT=k3s-hello GATEWAY=agw HOST=agw.hello-world.test
kubectl --context k3s-hello get cm,secret -n solomog-example
```

Pass `CONTEXT=k3s-hello` (verbatim kube context) on every task; solomog then treats the
target as external and skips vind create/teardown/networking. Set `GATEWAY`/`HOST`
explicitly for bundles (there's no gateway on the node-less cluster to auto-detect).

### Notes / gotchas

- Run docker/k3s under `tmux` (or `nohup`) so they survive between tool calls; kill by
  **specific PID**, never `pkill -f`.
- Native `overlay2` is unavailable (kernel) — Docker uses `fuse-overlayfs`; k3s needs
  `--snapshotter=fuse-overlayfs`. `containerd-snapshotter` is disabled in `daemon.json`
  so fuse-overlayfs works with Docker 29.
- `.env` is optional for community/dev use (go-task ignores a missing dotenv); the update
  script creates it from `.env.example` if absent. Enterprise product installs need real
  Solo license keys in `.env` — and those installs can't complete here anyway (see above).
- This VM is `x86_64`; CLAUDE.md's "images must be arm64" note is a macOS/Apple-Silicon
  concern and does not apply here.
