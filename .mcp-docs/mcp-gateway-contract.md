# Docker MCP Gateway HTTP/SSE Contract (Client Integration Notes)

This document summarizes how a client (our Flutter MCP client) must talk to the Docker MCP Gateway when using the SSE transport, and what responses to expect. All references cite concrete files in the gateway repo `/.mcp-gateway/mcp-gateway`.

## Endpoints and routing

- __GET `/sse`__
  - Starts an SSE session. The very first SSE event is `event: endpoint` whose `data` is a RequestURI string containing the session endpoint (e.g., `?sessionid=abcd`).
  - Source: `cmd/docker-mcp/internal/gateway/transport.go` `startSseServer()` and `vendor/github.com/modelcontextprotocol/go-sdk/mcp/sse.go`.

- __POST session endpoint__
  - Canonical contract: `/sse?sessionid=<id>` is the session POST endpoint.
  - Some gateway variants/builds emit an endpoint of the form `/message?sessionId=<id>` in the initial `endpoint` SSE event and accept POSTs there with `202 Accepted`.
  - Best practice (confirmed working): prefer posting to the exact endpoint emitted by the gateway in the `endpoint` event, with a fallback to the canonical `/sse?sessionid=<id>`.
  - Returns `202 Accepted` on success; `400/404` on errors (details below).
  - Source: `vendor/.../mcp/sse.go::SSEServerTransport.ServeHTTP()`.

- __GET `/`__
  - 307 redirect to `/sse`.
  - Source: `cmd/docker-mcp/internal/gateway/transport.go` `redirectHandler("/sse")`.

- __GET `/health`__
  - Health probe. 200 when healthy, 503 when not.

- Alternative transport (streaming): __GET/POST `/mcp`__ via `NewStreamableHTTPHandler` if the gateway is started with `--transport streaming`.

## SSE session behavior

- __Handshake event__
  - The first SSE event after `GET /sse` is:
    - `event: endpoint`
    - `data: ?sessionid=<id>` (plain string, not JSON), or `/message?sessionId=<id>` in some variants.
  - The `data` value is the relative RequestURI of the session POST endpoint. The client must resolve this against the base URL. Clients should prefer the emitted shape (e.g., `http://localhost:7999/message?sessionId=<id>`) and also compute the canonical fallback (`http://localhost:7999/sse?sessionid=<id>`).
  - Source: `vendor/.../mcp/sse.go::SSEServerTransport.Connect()` writes the event.

- __Message events__
  - Subsequent events are:
    - `event: message`
    - `data: <raw JSON-RPC bytes>`
  - The payload is direct JSON-RPC (no outer envelope), e.g. `{"jsonrpc":"2.0","id":1,"result":...}`.
  - Source: `vendor/.../mcp/sse.go::sseServerConn.Write()`.

## Required headers

- __GET `/sse`__
  - Request: `Accept: text/event-stream`.
  - Response: Server sets `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`.

- __POST session endpoint__
  - Request: `Content-Type: application/json`.

## Query parameter name

- The canonical session parameter is lowercase: `sessionid`.
- Some variants emit `sessionId` (camelCase) in the `endpoint` event (e.g., `/message?sessionId=<id>`). Clients should parse both and normalize as needed.
- The upstream handler uses `req.URL.Query().Get("sessionid")`.
- Source: `vendor/.../mcp/sse.go::SSEHandler.ServeHTTP()`.

## HTTP status codes

- `202 Accepted` on successful POST of a JSON-RPC message to the session endpoint.
- `400 Bad Request` when:
  - Body is not valid JSON-RPC; or
  - `sessionid` is missing on POST; or
  - Request method is invalid.
- `404 Not Found` when posting to a non-existent session `sessionid`.
- `307 Temporary Redirect` from `/` to `/sse`.

## Minimal client flow (SSE)

1. Issue `GET {base}/sse` with `Accept: text/event-stream`.
2. Read the first SSE event: `event: endpoint`, `data: ?sessionid=<id>` or `/message?sessionId=<id>`.
3. Resolve to the absolute session endpoint. Prefer the emitted shape (e.g., `{base}/message?sessionId=<id>`), compute canonical fallback `{base}/sse?sessionid=<id>`.
4. POST JSON-RPC initialize to the session endpoint with `Content-Type: application/json`. Avoid double JSON encoding.
   - Expect `202 Accepted` (no body required).
5. Read SSE `message` events and decode JSON-RPC responses; match by `id`.
6. POST further requests (e.g., `tools/list`) to the same session endpoint; read results via SSE.

## Alignment checklist for our Flutter client

- __SSE parsing__
  - Accumulate multi-line `data:` segments per SSE spec until a blank line.
  - Detect the first event name (`endpoint`) and treat its `data` as a string URI.
  - Detect subsequent event name (`message`) and parse `data` as raw JSON-RPC.

- __Session sync__
  - Wait until the session endpoint is extracted from the first `endpoint` event.
  - Store the absolute `Uri` (resolved from the base URI and the RequestURI string), tracking both the preferred emitted endpoint and the canonical fallback.

- __POST behavior__
  - Prefer the emitted endpoint (may be `/message?sessionId=<id>`); fallback to `/sse?sessionid=<id>`; header `Content-Type: application/json`.
  - Accept `202` as success (no JSON body required from server).

- __Query casing__
  - Use `sessionid` (lowercase) everywhere when reading/building URLs.

- __Error handling__
  - On `400`/`404`, log the body and confirm the `sessionid` and JSON-RPC payload.
  - If `initialize` seems to time out, capture the raw SSE `message` event payload around the response to validate JSON shape.

## References (source code)

- `cmd/docker-mcp/internal/gateway/transport.go`
  - `startSseServer()` mounts `/sse`, `/health`, and `/` redirect.
- `vendor/github.com/modelcontextprotocol/go-sdk/mcp/sse.go`
  - `SSEHandler` (server-side HTTP handler)
  - `SSEServerTransport.Connect()` (writes `endpoint` event)
  - `sseServerConn.Write()` (writes `message` events)
  - `SSEServerTransport.ServeHTTP()` (accepts POSTs to the session endpoint)

## Alternative: streaming transport

- When run with `--transport streaming`, the gateway serves `NewStreamableHTTPHandler` at `/mcp`.
- SSE remains simpler and is what our client targets for now. See `docs/mcp-gateway.md` for CLI flags.

## Expected tool listing flow

- After `initialize` succeeds, send `tools/list` via the same session endpoint.
- The response arrives as an SSE `message` with a JSON-RPC result containing the tools from all enabled servers (aggregated by the gateway).
