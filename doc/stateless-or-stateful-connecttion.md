# Stateless or stateful connection

The `stateless_http` switch of the Streamable HTTP transport and its
effect on this server. Derived from
[`src/mcp-python.py`](../../src/mcp-python.py) and the MCP Python SDK
`mcp==2.3.0` ([`src/requirements.txt`](../../src/requirements.txt)) - a
reading of the code, not a live test.

Summary - the server is stateful now (the default). Stateless fits it
better: its tools are plain request - response and keep no state, and a
service restart would no longer break the connected clients.


## The two modes

| | `stateless_http=False` (default) | `stateless_http=True` |
|---|---|---|
| Session | `initialize` creates a session, the response carries the header `Mcp-Session-Id`; the client sends it with every later request. | No session, no `Mcp-Session-Id`. |
| Server memory | A transport object per session, held by the session manager. | A fresh transport and server instance per POST, dropped after the response. |
| Session end | Client `DELETE`, idle longer than `session_idle_timeout`, server restart. Limited by `max_sessions`. | Not applicable. |
| `GET /mcp` (SSE stream) | Yes - server to client notifications. | No. |
| Resumability (`event_store`) | Possible. | No. |
| Server initiated requests (sampling, elicitation) | Possible. | No. |
| Several instances or workers | Need sticky routing - the session lives in one process. | Any instance answers any request. |
| Authentication (`MCP_AUTH=token`) | The token is checked at every request. A session belongs to the client, which opened it - the token of another client gets `404 Session not found`. | The token is checked at every request. No session to belong to. |


## Effect on this server

Gains:

- A restart of the service (`systemctl restart`, package upgrade, crash
  with `Restart=on-failure`) does not break the clients. Stateful - a
  client holding an old session ID gets `404 Session not found` until it
  initializes again; Claude Desktop through `mcp-proxy` is the most
  likely to hit it.
- No session bookkeeping - no idle timeout, no `max_sessions` limit, no
  memory per client.
- Ready for a load balancer or several workers.
- `MCP_HTTP_VARIANT=both` - both listeners share one app and one session
  manager already, so the gain is small.

Losses - none in practice:

- `run_python` and `python_info` are request - response, every call is a
  fresh interpreter anyway. The server sends no notifications
  (`tools/list_changed`, logging) and asks the client for nothing
  (sampling, elicitation).
- It changes nothing in the security - a session ID is not an
  authentication, the bearer token is, and it is checked at every request
  in both modes. The binding of a session to its client goes away with
  the sessions - nothing is left to take over; see
  [client-access-notes.md](client-access-notes.md).


## The change

In the SDK 2.x `FastMCP` became `MCPServer`, and its constructor has no
`stateless_http` - the 1.x form

```python
mcp = FastMCP("python-dev", stateless_http=True)
```

does not work. The switch is an argument of the app factory, at
[`src/mcp-python.py:100`](../../src/mcp-python.py#L100):

```python
app = mcp.streamable_http_app(host=serve.host, stateless_http=True)
```

Optional - `json_response=True` returns a plain JSON body instead of a one
event SSE stream; easier to read with `curl`, the clients take both.


## Check

The `mcp-proxy` test (`initialize`, `notifications/initialized`,
`tools/list`) must still pass. Stateless - the `initialize` response has
no `Mcp-Session-Id` header; it is expected. The token - of
`make secrets` (`make dev-launch`), the client `dev`; without the header
the answer is `401` in both modes.

```sh
curl -si -X POST http://127.0.0.1:8765/mcp \
  -H "Authorization: Bearer $(cat build/mcp-python/clients/dev.token)" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  | grep -i '^mcp-session-id' || echo 'no session - stateless'
```
