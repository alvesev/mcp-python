# To fix

Notes on the code as of version 0.5.0 - what is wrong or fragile in what is
already there, not what to develop next. "Checked" - reproduced by a run,
the rest is by reading the code.

## Start of the server (`src/mcp-python.py`)

- **A failed start prints a traceback instead of a message.** The entry
  point catches `KeyboardInterrupt` only. Some failures end by
  `sys.exit(message)` (unknown `MCP_HTTP_VARIANT`, `MCP_AUTH`, a value which
  is not an integer, root without `MCP_USER`), the others are exceptions,
  which nobody catches:
  - `ServeSettings.validate` - `ValueError`, `FileNotFoundError`,
    `PermissionError` for the TLS certificate and key. Checked.
  - `AuthSettings.validate` - `FileNotFoundError` for no `MCP_AUTH_TOKENS`
    directory (checked), `OSError` for a directory which is not readable.
  - `AuthSettings.server_kwargs` with `once` - `OSError` from
    `TokenStore.load`.
  - `Config.load` - `ssl.SSLError`, `OSError` for a wrong certificate or key.
  - `_drop_privileges` - `KeyError` from `pwd.getpwnam` for an unknown
    `MCP_USER`.
  - `os.chdir(tools.scratch)` - `OSError` for a missing `MCP_SCRATCH`.

  The message is there, but under a traceback in the journal. To fix: catch
  `OSError`, `ValueError`, `KeyError` at the entry point and
  `sys.exit(message)`.

- **`ServeSettings.validate` runs twice** - `from_env` calls it, then the
  entry point calls it again. `AuthSettings.from_env` does not call its
  `validate`. One of the two calls is to remove, the same way for both
  classes.

- **No check of the ranges.** `env_int` takes any integer: a port out of
  1..65535 fails later, in uvicorn; `MCP_EXEC_TIMEOUT` of 0 or less gives a
  timeout of 1 second without a word; `MCP_OUTPUT_LIMIT` below 0 cuts the
  output from its end (`s[:limit]`) and reports a wrong count.

## Execution of a code (`src/mcp_tools.py`)

- **A timeout does not stop the processes, which the code started.**
  `_exec` kills the interpreter only. Its children live on, and while they
  hold the `stdout` or `stderr` pipe, the second `proc.communicate()` waits
  for them - with no limit. Checked: `timeout_s` of 1 and a code, which
  starts `sleep 6`, returns after 6 seconds. So with `sleep infinity`
  the call would never return (not run). To fix: start the workload
  in its own session (`start_new_session=True`), kill the group
  (`os.killpg`), and give the second `communicate()` a timeout too.

- **`MCP_OUTPUT_LIMIT` does not limit the memory.** `communicate()` reads
  the whole `stdout` and `stderr` into the memory of the server, `_cut` is
  applied after. A code, which prints without an end, grows the server up
  to `MemoryMax=1G` of the unit - then the server is killed, with all the
  sessions, not the workload alone. To fix: read the pipes by pieces and
  stop (kill) at the limit.

- **`python_info` hides a failure.** The return codes of both `_exec` calls
  are not looked at. No `pip` for `MCP_WORK_PYTHON`, or a timeout - the
  answer is an empty `packages`, as if nothing is installed.

- **The temporary directory may not be removed.** A process left after a
  timeout (see above) can write into the directory while
  `TemporaryDirectory` removes it - the removal fails with `OSError`, and
  the call fails instead of returning `timed_out`. Goes away with the kill
  of the group.

## Tokens (`src/mcp_auth.py`)

- **`add` can overwrite a client.** The check `os.path.lexists` and the
  `os.rename` are two steps; `rename` replaces an existing file. Two `add`
  of one name at one time - both print a token, one of them is dead. To
  fix: `os.link` (fails if the name exists), then unlink the file aside.

- **The same hash in two files.** `_read` keeps a dictionary by the hash -
  the last name by the order wins, the other client is gone from `list`
  and from the log, without a warning. Happens only by a copy of a file by
  hand; a warning, as for a skipped file, is enough.

- **The help says "a running server notices a change by itself, in a few
  seconds"** (`main`, and the comment at `MCP_AUTH_TOKENS` in
  `src/mcp-python.conf`). Not so with `MCP_AUTH_RELOAD_PERIOD=once` - and
  it is the default of `container/docker-compose.yml`.

## Small things

- `src/mcp-python.py` has no newline at the end of the file.
- `src/mcp-python.py`: "priviledges", "privilidge" in the comment at
  `c.load()`; a trailing space after `lifespan="on" if i == 0 else "off",`.
- `src/mcp-python.py`, the header: "Here are the two lines with 'auth'
  only" - there are three.
- `doc/stateless-or-stateful-connecttion.md` - "connecttion" in the name.
- `doc/mcp-python-startup.dia` still shows a failed start as
  `sys.exit(message)` - `misc/doc/*.puml` are corrected, the `.dia` files
  are not compared with them.
