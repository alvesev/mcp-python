# Data access of a client code

What a code, submitted by an MCP client through `run_python`, can reach
on the host. Derived from [`src/mcp-python.py`](../../src/mcp-python.py),
[`src/mcp_tools.py`](../../src/mcp_tools.py),
[`src/mcp_auth.py`](../../src/mcp_auth.py),
[`src/mcp-python.conf`](../../src/mcp-python.conf) and
[`debian/mcp-python.service`](../../debian/mcp-python.service) (version
0.5.0) - a reading of the code and the unit, not a live test. The host of
the Deb package `mcp-python`; the container launchers - see
[container-security.md](container-security.md).

Summary - the code has everything the account `mcp-python` has, minus
what the Systemd unit takes away. File access is limited fairly well;
network, processes and the other clients' calls are not limited.
Authorisation is not implemented: the authentication decides, who
submits a code - not what the code reaches.

## Who is a client

The holder of a token. Each client has a token of its own and sends it
with every request (`Authorization: Bearer <token>`); a request without a
known token gets `401` (`MCP_AUTH=token`, the default). The clients are
the files of `MCP_AUTH_TOKENS`, a file per client, managed with
`mcp-python-token`. No clients - nobody gets in; it is the state after
the installation.

- A token is the whole right - every client gets the same, full code
  execution. No scopes, no expiry: a token is valid until its file is
  removed.
- A token over plain HTTP is readable on the wire - beyond the local host
  use the HTTPS listener, or TLS in front of the server.
- `MCP_AUTH=none` - no authentication, whoever reaches a listener
  executes a code. With the default `MCP_HOST=127.0.0.1` it is every
  local user and process of the host; with another address - the whole
  network segment.


## Identity

- The uid `mcp-python`, no supplementary groups (`setgroups([])`),
  `NoNewPrivileges=yes`.
- `python3 -I` isolates the Python import path only - it is not a
  security boundary.


## Files

| Area | Access |
|---|---|
| Whole file system (`ProtectSystem=strict`) | Read only - but every file readable by "others": `/etc`, `/usr`, `/opt`, `/srv`, `/var/www`, world readable configurations and backups, other services' `/var/lib/*`, where the permissions allow. |
| `/home`, `/root`, `/run/user` | Hidden (`ProtectHome=yes`). |
| `/tmp`, `/var/tmp` | Private to the service (`PrivateTmp=yes`). |
| `/dev` | Minimal (`PrivateDevices=yes`). |
| `/var/lib/mcp-python/scratch` | Read and write - shared by all the calls. |
| TLS key | The file is out of reach. A copy is in the server memory, but the server is non-dumpable after the privileges drop from root - the same uid can not read `/proc/<pid>/mem`. Safe while nothing re-enables dumpable (`prctl(PR_SET_DUMPABLE)`). |
| Token files, `/etc/mcp-python/tokens` | Read only - the directory is of root, readable by the group `mcp-python`. The code sees the names of the clients and the SHA-256 of their tokens - nothing to connect with: a token is 32 random bytes, not to be found by its hash. The code can not add a client. With `MCP_AUTH_RELOAD_PERIOD=once` the server reads them at start, as root, before the privileges drop, and never again - then the directory may be of root only, and the code reads not even the names; a client added or revoked needs a restart. |
| Tokens | Not in a file and not in the environment. A token is in the server memory for the time of a request - out of reach as the TLS key, while the server is non-dumpable. Started as `MCP_USER` at once (the image run as is, a pod of the Helm chart without TLS) the server is dumpable: a code of the same uid may read its memory, as far as `kernel.yama.ptrace_scope` allows. The launchers `mcp-python-container` and `mcp-python-compose` start it as root - non-dumpable after the drop. |
| Root only files (`/etc/shadow`, `adm` group logs, `/etc/ssl/private`) | Not readable. |


## Network - not restricted

The unit has no `PrivateNetwork`, `IPAddressDeny` or
`RestrictAddressFamilies`. The code reaches whatever the host reaches:

- localhost services - databases without authentication, admin ports,
  the D-Bus system bus, abstract Unix sockets;
- LAN and the Internet - so anything readable can be sent out;
- the cloud metadata endpoint `169.254.169.254` - instance credentials,
  if the host runs in a cloud;
- at a Kubernetes node - the kubelet and API endpoints, as far as their
  authentication allows.


## Processes and isolation between clients

- The code is visible to everyone. It is passed as `python3 -c <code>` -
  any local user reads it in `/proc/*/cmdline` or `ps`, including secrets
  a client puts into the code.
- Calls see each other. One uid for all the calls - a concurrent call
  reads the temporary directory, `/proc/<pid>/environ` and `cwd` of
  another one. The per call working directory is the only separation.
- The authentication does not separate the clients - everything here
  holds between the calls of different clients too. An MCP session
  belongs to the client, which opened it (the token of another client
  gets `404` there), the submitted code does not.
- Calls are not stateless. The source says "no state between calls", but
  nothing enforces it:
  - a code writes files anywhere within `scratch`, outside its own
    temporary directory - they stay;
  - on a timeout `proc.kill()` kills the direct child only - a forked or
    spawned grandchild keeps running within the service cgroup until the
    service restart, and can watch every later call.
- All the host processes are visible in `/proc`, with their command lines
  (no `ProtectProc`, `ProcSubset`).
- The code inherits the server environment - all of `MCP_*`. Harmless,
  while no secret is there: the tokens are in files, as hashes, for that
  reason - never pass a token (or another secret) to the server through
  the environment.
- The code can kill the server (the same uid). `SIGTERM` is a clean exit -
  `Restart=on-failure` does not start it again.
- Limits - `MemoryMax=1G` and `TasksMax=64` are shared with the server
  itself; no CPU limit.


## Narrowing

In the order of effect:

1. Network - `IPAddressDeny=any` with `IPAddressAllow=` for what is
   needed, or `PrivateNetwork=yes`, if no network is needed.
2. Code delivery - pass the code on `stdin` or as a file in the temporary
   directory instead of `-c`.
3. Per call separation - run each call as its own transient unit
   (`systemd-run --pipe` with `DynamicUser=yes`) or in bubblewrap /
   nsjail: own uid, own `/tmp`, kill of the whole process tree.
4. Processes - `ProtectProc=invisible`, `ProcSubset=pid`,
   `RestrictNamespaces=yes`, `SystemCallFilter=@system-service`,
   `CPUQuota=`.
5. Files - `TemporaryFileSystem=/var /srv /opt` (or an allow list with
   `BindReadOnlyPaths=`).
6. Access - done, a bearer token per client (`MCP_AUTH=token`). Left:
   HTTPS, or TLS in front of the listener, beyond localhost; the
   separation of the clients from each other is the item 3.
