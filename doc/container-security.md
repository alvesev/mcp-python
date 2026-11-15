# Container security - running untrusted code

The container of `mcp-python-container` and `mcp-python-compose` (package
`mcp-python-container`, `container/docker-compose.yml`) and the pod of
`mcp-python-chart` (package `mcp-python-chart`) are good containment against
mistakes and casual misuse. It is not a security boundary against hostile
code: every client with a token (with `MCP_AUTH=none` - anyone who reaches
the listener) runs arbitrary code inside, and that code shares the kernel
with the host.

This note describes what to add when the submitted code is not trusted.
Nothing below is set up or tested in this repository - the commands are the
starting points, check them against the documentation of the tool.

## What the plain container leaves open

| Gap | Why it matters |
|---|---|
| Shared kernel, `runc` | A kernel or runtime bug is an escape to the host. |
| Rootful Docker, no user namespace | An escape lands as root of the host. |
| Open outbound network | The code reaches the internet, the LAN and host services. |
| One container for all calls | A call sees, kills and outlives the others; it can kill the server. |
| Privileged K3s container | `mcp-python-chart` runs its cluster as a privileged Docker container - full access to the host while it runs; an escape from the pod into the node is an escape to the host. |
| One level of access for all clients | The authentication (a bearer token per client) decides who gets in. Every token gives the same, full code execution - the clients are not separated from each other. |
| Server and code share the user | Without the root start (the image run as is, a pod of the Helm chart without TLS) the server is dumpable - a code may read its memory, with the tokens of the requests in flight, as far as `kernel.yama.ptrace_scope` allows. The token files hold the SHA-256 only - nothing to steal there. |

## Which measure closes what

| Measure | Kernel escape | Root at the host after an escape | Calls see each other | Network |
|---|---|---|---|---|
| Sandboxed runtime (gVisor, Kata) | much harder | - | no change | no change |
| Whole stack in a VM | contained in the VM | contained in the VM | no change | by the VM firewall |
| Rootless Docker or `userns-remap` | no change | no - an unprivileged user | no change | no change |
| One fresh container per call | no change | - | closed | closed with `--network none` |

No single one is enough. A reasonable set for untrusted code: a sandboxed
runtime (or a VM), plus an unprivileged Docker, plus one container per call
with no network.

## 1. Sandboxed runtime

The largest single gain - the submitted code no longer talks to the host
kernel directly.

### gVisor (`runsc`)

A user space kernel between the container and the host: the code's system
calls are served by gVisor, only a small set reaches the host kernel. Needs
no hardware virtualisation.

1. Install `runsc` (package `runsc` from the gVisor repository).
2. Register it with Docker and restart: `sudo runsc install`, then
   `sudo systemctl restart docker`. This adds the runtime to
   `/etc/docker/daemon.json`.
3. Check: `docker run --rm --runtime=runsc hello-world`.
4. Use it in `container/docker-compose.yml`:

   ```yaml
   services:
     mcp-python:
       runtime: runsc
   ```

   For `mcp-python-container` - `mcp-python-container --runtime=runsc`,
   its arguments go to `docker run`.

Cost: system calls and file I/O are slower, a few system calls are not
supported. A pure Python workload usually does not notice; check the
packages with native code that the clients need.

### Kata Containers

Each container runs in its own small virtual machine with its own kernel.
Stronger than gVisor in principle (hardware virtualisation), heavier at
start and in memory. Needs `/dev/kvm` at the host - inside a VM that means
nested virtualisation.

Registered with Docker as one more runtime in `/etc/docker/daemon.json`
(the containerd shim `io.containerd.kata.v2`), then used the same way:
`runtime: kata` in the compose file.

### A VM around everything

Run Docker and the whole compose stack inside a dedicated virtual machine
(libvirt, Multipass, a cloud instance) that holds nothing else. The
simplest to reason about: whatever happens stays in the VM, and the
network of the VM is limited at the host or at the network, outside of the
reach of the code. It does not separate the calls from each other.

## 2. Unprivileged Docker

Makes an escape land as an ordinary user instead of root. Two ways, pick
one.

### Rootless Docker

The daemon and the containers run as a regular user of the host; root of a
container is that user.

- Set up with `dockerd-rootless-setuptool.sh install` (package
  `docker-ce-rootless-extras`), as the user which will run the server.
- The memory, process and CPU limits need cgroup v2 with the controllers
  delegated to the user - without that the `mem_limit` and `pids_limit` of
  the compose file are ignored. Check with `docker info`.
- The secrets of the launchers (`~/.local/share/mcp-python` - the TLS key
  and the token files, mode 0600) belong to the same user, so root of the
  container reads them as the owner - `DAC_READ_SEARCH` of the launchers
  is not needed then.
- `mcp-python-chart` does not work there - its K3s container needs a
  rootful, privileged Docker.

### `userns-remap`

The daemon stays root, but the user IDs of every container are shifted:
root of a container is a high unprivileged UID of the host.

- `/etc/docker/daemon.json`: `{ "userns-remap": "default" }`, restart
  Docker. It applies to all containers of the host, and the images and
  containers created before are not visible until it is switched off.
- The secrets of the launchers become a problem here: the TLS key and the
  token files (mode 0600) belong to the host user, which has no mapping
  inside the container, and `DAC_READ_SEARCH` does not apply to such files.
  Give them to the shifted root (the first UID of `dockremap` in
  `/etc/subuid`), e.g. copies owned by it, mode 0600.

## 3. One fresh container per call

Today the server and every submitted code share one container: a call can
see and kill the processes of another, leave processes behind, and kill
the server. A sandboxed runtime does not change that.

To separate the calls, the server has to stay outside of the sandbox and
start a container for each call:

```
docker run --rm --interactive --network none --runtime runsc \
    --read-only --tmpfs /tmp --cap-drop ALL \
    --security-opt no-new-privileges \
    --memory 1g --pids-limit 64 --cpus 1 \
    python:3.12-slim-bookworm python3 -I -c "<code>"
```

`--network none` also closes the outbound network - a per call container
needs no listener.

How it fits this project:

- The server runs at the host (the Deb package), not in the compose
  container. `MCP_WORK_PYTHON` can point to a wrapper script, which runs
  the line above and passes its arguments on - `mcp_tools.py` calls
  `[MCP_WORK_PYTHON, "-I", "-c", code]`, so no change of the server for the
  first version.
- The server then needs the right to start containers. With a rootful
  Docker it is the right of root at the host - the server becomes a trusted
  part and must never run a submitted code itself. One more reason for
  rootless Docker.
- The timeout: the server kills its child, which here is the `docker`
  client - the container keeps running. The wrapper has to end the
  container itself (a named container and `docker kill`, or `timeout`
  inside the container).
- The cost - the start of a container at every call, a fraction of a
  second with `runc`, more with gVisor or Kata.

## Besides the runtime

Needed in any variant, and not specific to untrusted code:

- **Authentication.** Bearer tokens, a token per client - on by default
  (`MCP_AUTH=token`). The token files of the user (the launchers -
  `~/.local/share/mcp-python/tokens`, mode 0600; at the source tree -
  `make secrets`, `build/mcp-python/tokens`) are mounted read only at
  `/etc/mcp-python/tokens`. `mcp-python-container` and `mcp-python-compose`
  read them once, as root, before the privileges drop
  (`MCP_AUTH_RELOAD_PERIOD=once`) - a submitted code reads not even the
  hashes; a client added or revoked - a restart. In the pod of
  `mcp-python-chart` they are a Secret, readable by the server account and
  so by the code - the hashes only. Never pass a token through the
  environment of the container - a submitted code inherits it. A token over plain HTTP is readable on the
  wire - HTTPS, as the compose file has, or TLS in front. It does not
  separate the clients - that is the section 3.
- **Outbound network of the long running container.** A compose network
  with `internal: true` has no way out, but its ports are not published -
  a reverse proxy, attached to both networks, solves it.
- **CPU and restart.** The launchers limit the CPUs to 75% of the host
  (`MCP_CPUS`; the chart - `resources.limits.cpu`); `mcp-python-compose`
  and the K3s cluster of `mcp-python-chart` start again after a restart of
  Docker or of the host.
- **Published ports and the firewall.** Docker publishes ports past `ufw` -
  a rule there does not protect a published port.
