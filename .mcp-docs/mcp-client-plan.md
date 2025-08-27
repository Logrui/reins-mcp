# Reins MCP Client and Tools Support — Living Document

This document tracks the plan, design, and implementation steps to turn Reins into an MCP (Model Context Protocol) client with tool-calling support. It is structured as phased milestones: a Minimum Viable Product (MVP) and Production polish.


## Architecture Overview (Flutter + Reins)

- __Flutter cross-platform__: One Dart codebase targeting iOS, Android, macOS, Windows, Linux, and Web. UI built with Flutter widgets; business logic and services are pure Dart where possible.
- __Current services & state__:
  - `lib/Services/ollama_service.dart`: HTTP/streaming to model server.
  - `lib/Providers/chat_provider.dart`: orchestrates chat, streaming, and state.
  - Hive-backed settings and local DB in `lib/Services/database_service.dart`.
- __Planned MCP integration__: Add `McpService` (WebSocket + JSON-RPC 2.0). Intercept tool calls in `ChatProvider` during token stream and resume generation after injecting results.
- __Feasibility summary__:
  - Using the current architecture is viable. Provider-based orchestration is a good fit for intercepting `TOOL_CALL:` mid-stream.
  - `web_socket_channel` works across mobile/desktop/web. On Web, ensure WS endpoints use `wss://` when app is served over HTTPS to avoid mixed content.
  - Hive: supported across platforms; verify box schemas for `mcpServers` on Web and Desktop.
  - Platform caveats: network permissions (Android/iOS), self-signed certs in dev, and CORS/Mixed Content for Web. All manageable at app config level.

### Platform constraints overview
- __Web__: Current codebase uses `dart:io` (`main.dart`, `database_service.dart`, `ollama_message.dart`) and `sqflite`; these block web builds. Web requires HTTPS + WSS and no stdio or port scanning.
- __Mobile__: Network permissions and ATS for HTTP to localhost; no stdio on iOS; limited on Android.
- __Desktop__: Easiest environment. Full WS and optional stdio in Production.


## Current App Architecture (Reference)

- Core entry: `lib/main.dart`
- Chat orchestration: `lib/Providers/chat_provider.dart`
- Model/API integration: `lib/Services/ollama_service.dart`
- Persistence: `lib/Services/database_service.dart`
- Message model: `lib/Models/ollama_message.dart`
- Path utility: `lib/Constants/path_manager.dart`
- Pages/UI: `lib/Pages/`

Today, chat flows through `ChatProvider._streamOllamaMessage()` which calls `OllamaService.chatStream()` to stream tokens from an Ollama server.


## Goal

Enable Reins to act as an MCP client and execute tools exposed by connected MCP servers during chat. The model will request a tool; Reins will execute it via MCP and feed the result back into the ongoing conversation.


## Plan Overview and Reading Guide

- __Architecture & Design__: `Current App Architecture`, `High-Level Design`.
- __Technical details__: `Technical Design Details` (API sketches, touch points, persistence).
- __Implementation__: `MVP Implementation Stages` then `Production Implementation Stages`.
- __Roadmap__: Mid/Long-term ideas beyond staged delivery.
- __Milestones & Next__: Success criteria and immediate next actions.


## High-Level Design

- Add an MCP service layer to connect to MCP servers (initially WebSocket transport) and expose methods to list tools and call tools.
- Use a simple, reliable tool-call protocol with the LLM via text sentinel lines (MVP), since Ollama’s REST API does not natively accept a `tools` parameter:
  - Model emits: `TOOL_CALL: {"server":"<srv>","name":"<tool>","args":{...}}`
  - App replies: `TOOL_RESULT: {"name":"<tool>","result":<any>}`
- Inject tool awareness into the system prompt (list tools, usage rules) so the model knows how to request tools.
- Intercept tool calls in the streaming loop, execute via MCP, append the result, and continue the chat.

### Feasibility notes
- __Protocol__: Text sentinels are transport-agnostic and compatible with current Ollama REST streaming model. Low risk.
- __Service layering__: A dedicated `McpService` cleanly composes with `ChatProvider`. No architectural refactor required.
- __Resumption__: Restarting generation with appended `TOOL_RESULT:` mirrors existing retry logic; feasible with current `OllamaService.chatStream()`.
 - __LLM adherence__: Risk that models deviate from exact `TOOL_CALL:` JSON. Mitigate via prompt appendix, examples, and tolerant parsing with clear error paths.


## New Files to Add (MVP)

- `lib/Services/mcp_service.dart`
  - Manages connections to MCP servers (WebSocket first), JSON-RPC 2.0 messaging, `initialize`, `listTools`, `callTool`.
- `lib/Models/mcp.dart`
  - Data classes for `McpServerConfig`, `McpTool`, `McpToolCall`, `McpToolResult`.
- `lib/Utils/tool_call_parser.dart`
  - Parse `TOOL_CALL:` sentinel JSON and format `TOOL_RESULT:` payloads.
- `lib/Constants/tool_system_prompt.dart`
  - Renders a tool-aware system prompt appendix from a tool list.

### Feasibility notes
- __Pure Dart__: All four files are platform-agnostic Dart; safe across iOS/Android/Desktop/Web.
- __WebSocket__: `web_socket_channel` supports required features; JSON-RPC 2.0 can be implemented atop it without extra deps.
- __Testing__: These units are testable with mock channels and pure functions.


## Existing Files to Update (MVP)

- `lib/main.dart`
  - Add `Provider(create: (_) => McpService())` and connect/load tools at startup.
- `lib/Providers/chat_provider.dart`
  - Before calling `OllamaService.chatStream()`, enrich the effective system prompt with the tool appendix.
  - In `_streamOllamaMessage()`, detect `TOOL_CALL:` lines, execute tool via `McpService`, inject `TOOL_RESULT:` as a message, then resume generation with updated history.
- `lib/Pages/settings_page/subwidgets/server_settings.dart` (optional for MVP)
  - Add text fields to manage MCP server endpoints (store in Hive `settings` as `mcpServers`).

### Additional feasibility notes
- __Stream orchestration__: Implement cancellation + restart to avoid duplicate tokens when pausing for a tool call.
- __Web build goal__: If targeting web, add `kIsWeb` guards and conditional imports in files that use `dart:io` and `sqflite`.


## MVP: Detailed Scope (Feature Checklist)

- __MCP transport__
  - WebSocket client (`web_socket_channel`).
  - JSON-RPC 2.0 request/response with id routing and error handling.
- __MCP methods__
  - `initialize` (capabilities negotiation minimal viable).
  - `tools/list` (list available tools with schemas if available).
  - `tools/call` (invoke a tool by name with args; return result or error).
- __Tool-call protocol (model-facing)__
  - System prompt appendix listing tools and strict instructions for outputting exactly one `TOOL_CALL:` JSON line when a tool is needed.
  - Parser that detects and parses `TOOL_CALL:` in streamed content (supports mid-stream detection; buffer a line until valid JSON parses).
  - After execution, inject `TOOL_RESULT:` line as a new assistant message to context; resume generation to let the model craft the final user-facing response.
- __State & persistence__
  - Cache tool list in memory within `McpService`. Persist server endpoints in Hive `settings`.
- __UI__
  - Minimal: render `TOOL_CALL:` and `TOOL_RESULT:` as plain assistant text (MVP avoids new roles/UI until later).
- __Errors__
  - If MCP call fails, return a `TOOL_RESULT:` with an error field and let the model handle it.


## Production: Enhancements and Polish

- __UX/UI__
  - Distinct visual style for tool requests/results (monospace blocks, icons, compact cards).
  - Show an inline spinner while a tool is executing; allow cancel.
  - Per-chat tool visibility/enable/disable controls.
- __Roles & structure__
  - Introduce a dedicated `tool` role in the message model and renderer.
  - Maintain a structured transcript (separate from display text) for `tool_call` and `tool_result` segments.
- __Transport & security__
  - Add stdio transport (spawn processes on desktop) with sandboxing.
  - Authentication support (API keys, tokens) per server.
- __Schema & validation__
  - Use tool input JSON Schemas to validate and assist argument building.
  - Optional UI to preview/confirm arguments before execution.
- __Reliability__
  - Robust JSON streaming parser across partial lines and multiple tool calls.
  - Backoff/retry policy for MCP calls; deadline and budget controls per call.
- __Observability__
  - Structured logs for tool lifecycle (requested → executing → result/error).
  - Dev panel to inspect MCP traffic (toggle via debug settings).
- __Testing__
  - Integration tests covering tool loops, error paths, cancellations.
  - Snapshot tests for UI rendering of tool cards/rows.


## Technical Design Details

### API Sketches (MVP)

#### Models (`lib/Models/mcp.dart`)

```dart
class McpServerConfig {
  final String name; // e.g., "local"
  final Uri endpoint; // e.g., ws://localhost:3001
  final String? authToken;
  McpServerConfig({required this.name, required this.endpoint, this.authToken});
}

class McpTool {
  final String server;
  final String name;
  final String? description;
  final Map<String, dynamic>? inputSchema;
  McpTool({required this.server, required this.name, this.description, this.inputSchema});
}

class McpToolCall {
  final String server;
  final String name;
  final Map<String, dynamic> args;
  McpToolCall({required this.server, required this.name, required this.args});
}

class McpToolResult {
  final dynamic result;
  final String? error;
  McpToolResult({this.result, this.error});
}
```

#### MCP Service (`lib/Services/mcp_service.dart`)

```dart
enum McpConnectionState { disconnected, connecting, connected, error }

abstract class McpService {
  Future<void> connectAll(List<McpServerConfig> servers);
  Future<void> disconnectAll();

  // Connection state changes per server (optional to observe in UI)
  Stream<Map<String, McpConnectionState>> connectionStates();

  // List tools for all servers or a specific server
  Future<List<McpTool>> listTools({String? server});

  // Invoke tool with optional timeout. Errors mapped into McpToolResult.error
  Future<McpToolResult> call(
    String server,
    String tool,
    Map<String, dynamic> args, {
    Duration? timeout,
  });
}
```

#### Tool Call Protocol Utilities (`lib/Utils/tool_call_parser.dart`)

```dart
const String kToolCallPrefix = 'TOOL_CALL:';
const String kToolResultPrefix = 'TOOL_RESULT:';

// Detects and parses the first TOOL_CALL in the provided text buffer.
// Returns null if not found or invalid JSON.
McpToolCall? parseToolCall(String text);

// Formats a tool result line for the transcript
String formatToolResult(String toolName, dynamic result, {String? error});
```

#### System Prompt Appendix (`lib/Constants/tool_system_prompt.dart`)

- Function that renders a concise list of tools with usage instructions and the exact sentinel format to use.


### Touch Points in `ChatProvider`

- When preparing the chat request:
  - Compute `effectiveSystemPrompt = currentChat.systemPrompt + toolSystemPrompt(tools)`
- In `_streamOllamaMessage()` loop:
  - Accumulate streamed content; when a line starts with `TOOL_CALL:`, attempt JSON parse.
  - On success: cancel current stream; run MCP call; append `TOOL_RESULT:` as a new assistant message; then start a new `chatStream` using the updated transcript so the model can finalize the answer.
  - Add guard flags to prevent re-entrancy and ensure the first stream is fully cancelled before starting the next.


### Data Persistence

- Hive settings (`Hive.box('settings')`):
  - `serverAddress` (existing)
  - `mcpServers` (new): list of objects `{name, endpoint, authToken?}`
- No schema migration required for settings; default to empty list if missing.
- For Production P2 (`tool` role), plan a DB migration step to extend the role enum or remove the CHECK constraint and enforce in app logic.


## Risks and Mitigations

- __LLM adherence to protocol__: It might not always emit perfect `TOOL_CALL:` JSON.
  - Mitigate with clear prompt instructions and strict examples.
  - Parser tolerates whitespace and buffers incomplete lines.
- __Transport variability__: Some MCP servers require stdio.
  - Start with WebSocket; add stdio in Production phases.
- __Latency__: Tool calls can increase round-trip time.
  - Show spinner; consider timeouts; allow cancel.
 - __Web constraints__: HTTPS + WSS required; no stdio; no port scanning. Document dev reverse-proxy with valid certs.
 - __Large tool outputs__: Truncate or summarize `TOOL_RESULT:` to avoid blowing model context; provide expandable UI later.
 - __Stream orchestration__: Risk of duplicate/interleaved tokens. Use explicit cancellation and state machine in `ChatProvider`; add tests.


## MVP Implementation Stages and Actionable Steps

### Progress Update — 2025-08-25
- [x] Stage 0 — Scaffolding: created `mcp.dart`, `mcp_service.dart`, `tool_call_parser.dart`, `tool_system_prompt.dart`; dependency `web_socket_channel` present in `pubspec.yaml`.
- [x] Stage 1 — MCP Service: WebSocket JSON-RPC skeleton implemented; `tools/list` and `tools/call` wired; connection state stream exposed; reconnection/backoff TBD.
- [x] Stage 2 — Prompt + Parser: system prompt appendix and strict sentinel parsing/formatting added.
- [~] Stage 3 — ChatProvider orchestration: TOOL_CALL interception, cancel/resume, TOOL_RESULT injection implemented; guard flags/TODOs pending.
- [ ] Stage 4 — Settings wiring: `mcpServers` UI + persistence not added yet.
- [ ] Stage 5 — Tests: pending.

### Progress Update — 2025-08-26
- [x] Settings: Added MCP Server Name field and wired persistence in `lib/Pages/settings_page/subwidgets/mcp_settings.dart`.
- [x] Settings Save: Now constructs `McpServerConfig(name, endpoint, authToken?)` and triggers disconnectAll → connectAll → listTools warmup.
- [x] Back-compat: Made `McpServerConfig.fromJson(...)` tolerant to missing `name` by deriving it from endpoint (host or trimmed URL).
- [x] Fixed compile error: "The named parameter 'name' is required" by supplying it where `McpServerConfig` is constructed.

- [x] Settings UI: Added per-row connection status chip using `McpService.connectionStates()` and a live tools count + "View" dialog pulling from `McpService.getTools(serverUrl)`.
- [ ] Tools Page: Create an "Available Tools" page aggregating tools across all servers with search/filter and copyable schemas.

- [x] Transport: Added MCP `initialize` handshake before `tools/list`.
- [x] Desktop WS: Use `IOWebSocketChannel` with `Sec-WebSocket-Protocol: jsonrpc` on desktop (keep default on Web). Added error logging for `tools/list`.
- [ ] Transport: Support optional headers/subprotocols from `McpServerConfig` (auth, custom proto) if required by gateways.

- [x] Startup Resilience: Defer MCP `connectAll` until after first frame; wrap in try/catch to avoid window crash on handshake errors.
- [x] Global Guard: Set `FlutterError.onError` to log errors during startup.
- [x] Endpoint Normalization: Convert `http`→`ws`, `https`→`wss`, and auto-try `/ws` path fallback.

- [x] Create files: `mcp_service.dart`, `mcp.dart`, `tool_call_parser.dart`, `tool_system_prompt.dart`.
- [x] Add dependency: `web_socket_channel` (and `uuid` already present) in `pubspec.yaml`.

### Progress Update — 2025-08-27
- [x] Initialize protocol: include `protocolVersion: "2024-11-05"` in `initialize` params and send `initialized` JSON-RPC notification after success.
- [x] Diagnostics: log unexpected `tools/list` result shapes for easier debugging.
- [x] Robust parsing: handle binary WebSocket messages by decoding UTF-8 before JSON parsing.
- [x] Schema tolerance: make `McpTool.fromJson` accept `parameters`, `input_schema`, or `inputSchema`; default empty description/parameters.
- [x] Auth headers & subprotocols: McpService now supports per-server Authorization Bearer header and configurable subprotocol preference; `connectAll` forwards `authToken`.
- [x] Connection gating: do not mark as connected unless `initialize` succeeds; send `initialized` notification after success.
- [x] Diagnostics: added verbose logs for connection attempts (URI, subprotocols, headers keys) and last-error caching per server.
- [ ] UI: expose `lastErrors[server]` as tooltip in Settings (pending).
- [x] Settings: ensure endpoint uses `/ws` path by default in UI to avoid 200 handshake.

#### Addendum — 2025-08-27 (later)
- [x] JSON-RPC batch handling: `_handleMessage()` now supports array responses by iterating each item.
- [x] Initialize logging: log `MCP initialize OK` on success for clearer diagnostics.
- [x] Tools list tolerance: accept result shapes `Map{tools|items|data}` or bare `List`; accept alt pagination keys `nextCursor|next|cursor|next_cursor`.
- [x] Per-server fallback: when `tools/list` returns empty, try `servers/list` then call `tools/list` with `{server: <name>}` per server, with pagination.
- [x] Timeouts: add 15s timeout to `tools/list` and 10s to `servers/list`, logging timeouts to `_lastErrors`.
- [x] Extra logging: log request pages/cursors and first-page result keys; log final total tools count per server.

### Progress Update — 2025-08-27 (Transports status)
- [x] WebSocket + json_rpc_2: Wrapped WS channel with `json_rpc_2.Peer`; `initialize`, `tools/list`, `tools/call` flow via `peer.sendRequest()`.
- [x] HTTP/SSE for Gateway: Implemented `HttpMessageChannel` and `HttpMessageSink` with SSE parsing, session endpoint discovery, and POST routing.
  - Prefer emitted `/message?sessionId=<id>`; fallback to canonical `/sse?sessionid=<id>`; then `/message`, `/rpc`, base URL.
  - Avoid double JSON encoding on POST; `Content-Type: application/json`; handle 307/302 redirects.
- [x] Error handling and logging: Detailed SSE framing, session extraction logs, and response diagnostics.
- [x] Platform coverage: Web, iOS, Windows Desktop supported for WS and HTTP/SSE.

### Progress Update — 2025-08-27 (HTTP/SSE session + parsing fixes)
- [x] SSE event framing: accumulate multi-line `data:` chunks and parse on blank line terminator per SSE spec.
- [x] JSON unwrapping: handle envelopes `{event,data}`, `{data:{message:{...}}}`, `{payload:...}`, and stringified inner JSON; support batch arrays.
- [x] Session sync: continue waiting on `sessionId` from SSE; accept bare lines with `sessionId=`.
- [x] Timeouts: increase `initialize` await timeout to 20s.
  - [x] Logging: add clear logs for extracted session endpoint and forwarded JSON-RPC objects.
  - [x] Gateway alignment: handle lowercase `sessionid` and resolve endpoint event RequestURI `?sessionid=...` to `/sse?sessionid=...`.

### Progress Update — 2025-08-27 (json_rpc_2 integration plan)

- [x] Dependency: added `json_rpc_2: ^3.0.2` to `pubspec.yaml`.
- [x] WebSocket path (Phase A): wrap WS channel with `json_rpc_2.Peer` (or `Client`) to manage ids, requests, notifications, and errors.
  - Use `web_socket_channel` to obtain a `StreamChannel<String>`; pass to Peer.
  - Route `initialize`, `tools/list`, and `tools/call` via `peer.sendRequest()`.
  - Listen for `notification` (e.g., `initialized`).
- [ ] HTTP/SSE path (Phase B): build a custom `StreamChannel<String>`:
  - Stream: SSE incoming JSON lines/messages.
  - Sink: HTTP POST to the discovered session endpoint (`/message` or `/sse?sessionid=...`).
  - Wrap this channel with `json_rpc_2.Peer` for uniform handling.
- [ ] Reconnect/backoff: adopt `retry` for WS reconnects and SSE re-subscribe with exponential backoff.
- [ ] Heartbeat: send `$/ping` (custom) or a benign request periodically; drop/reconnect on timeout.

Immediate next actions
- [x] Refactor `lib/Services/mcp_service.dart` WS transport to construct `Peer` and route `_rpc()` through it. (done)
- [ ] Keep current HTTP/SSE implementation as-is temporarily; add the custom `StreamChannel` wrapper next.
- [ ] Verify end-to-end: initialize → tools/list → tools/call over WS using `Peer`.
- [ ] Then swap HTTP/SSE to `Peer` once the custom channel is in place.

Immediate next steps
- [ ] Implement `StreamChannel<String>` wrapper for HTTP/SSE and wrap with `json_rpc_2.Peer` to unify transports.
- [ ] Add reconnect/backoff and optional heartbeat for SSE + POST.
- [ ] Reduce verbose logging in release builds; keep debug switches.
- [ ] Add tests for SSE parsing and endpoint handling.

### Progress Update — 2025-08-27 (Phase B alignment)

- [x] Endpoint handling: prefer emitted `/message?sessionId=<id>`; fallback to canonical `{base}/sse?sessionid=<id>`; then `/message`, `/rpc`, base URL.
- [x] Event-aware SSE parsing: track `event:` name; treat `endpoint` to set session, `message` for JSON-RPC, ignore others.
- [x] Enhanced logging: print SSE event names, first 200 chars of payload, and ids/methods forwarded to client.
- [ ] Build custom `StreamChannel<String>` for HTTP/SSE and wrap with `json_rpc_2.Peer`.

### What worked — Gateway SSE integration

- __Endpoint preference__: The gateway emits `endpoint` data like `/message?sessionId=<id>`. We now prefer posting to that exact endpoint, with a fallback to the canonical `{base}/sse?sessionid=<id>`.
- __JSON body handling__: `HttpMessageSink._sendMessage()` avoids double-encoding. If the request is already a JSON string (e.g., `McpRequest.toJson()`), we send it as-is; otherwise we `jsonEncode` the object. This resolved gateway `-32700 Failed to parse message`.
- __Verified flow__: Initialize succeeded and `tools/list` returned 44 tools. Logs: `MCP HTTP POST success to: .../message?sessionId=...` then SSE `message` with matching `id`.

### Next steps

- __Unify transports with json_rpc_2__: Implement a `StreamChannel<String>` wrapper for HTTP/SSE and back it with `json_rpc_2.Peer`, like the WebSocket path, to centralize RPC logic and retries.
- __Resilience__: Add reconnect/backoff for SSE and POST, and optional heartbeat.
- __Logging hygiene__: Reduce verbose logs for release profiles.

## Cross-Platform Transport Support Plan

Based on `MCP-Transport-Platform-Compatibility.md`, ensure each platform uses fully compatible transports and configs.

- __Web (Flutter Web)__
  - Implement native browser SSE using `dart:html` `EventSource` when `kIsWeb` is true. [t51, t59]
  - Provide proxy/CORS configuration (proxy base URL), detect and log blocked requests. Docs in `.mcp-docs`. [t52, t58]
  - Prefer SSE for Gateway; WebSocket for direct WS servers.

- __Android__
  - Ensure `INTERNET` permission; add Debug Network Security Config for cleartext localhost during dev; document HTTPS for prod. [t53, t58]
  - Use current HTTP/SSE and WebSocket; add reconnect with backoff. [t55, t56]
  - Expose TLS options (pinning hooks). [t57]

- __iOS__
  - Add ATS exceptions for dev localhost; document HTTPS/cert pinning for prod. [t54, t58]
  - Ensure URLSession-based SSE stays alive within background constraints; implement reconnect + backoff. [t55, t56]
  - Expose TLS options (pinning hooks). [t57]

- __Desktop (Windows/macOS/Linux)__
  - Verify HTTP/SSE and WebSocket paths; add reconnect with exponential backoff. [t55, t56]
  - Expose TLS options (pinning hooks). [t57]

- __Testing__
  - Integration tests per platform where feasible to validate `initialize` and `tools/list` over WS and Gateway SSE. [t60]

Deliverables will include code changes, platform-specific setup docs, and logging improvements to diagnose transport issues across targets.

### Stage 1 — MCP Service (wire transport)

- [x] Implement connection manager and JSON-RPC request/response with ids.
- [x] Cache `McpTool` list in memory.
- [x] Implement `initialize`, `tools/list` (with pagination), and `tools/call` for each connected server. Handle binary WS frames.

### Stage 2 — Prompt Protocol & Parser integration

- [x] Implement parser/formatter utilities for `TOOL_CALL:` and `TOOL_RESULT:`.
- [x] Build system prompt appendix renderer from the cached tool list.

### Stage 3 — ChatProvider Integration
- [x] Inject prompt appendix at send time (do not permanently mutate DB-stored prompt).
- [x] Intercept tool calls mid-stream; cancel current stream; perform MCP call; inject result; resume model generation with a new stream.
- [x] Handle errors by returning a `TOOL_RESULT` with an `error` field.
 - [x] Add guard flags and ensure `_activeChatStreams` is cleared before resuming.

### Stage 4 — Settings Wiring (MVP minimal)
- [x] Persist `mcpServers` to Hive; seed with empty list (works cross-platform). Save triggers disconnectAll -> connectAll -> listTools warmup.
- [x] In `main.dart`, create `McpService`, read configs, `connectAll`, `listTools`.
 - [ ] Auto-discovery UI: desktop/mobile only. Not feasible on web due to browser restrictions.
 - [ ] Per-chat toggles to enable/disable discovered servers/tools for a given chat.
 - [ ] Configure Chat popup: allow selecting tools based on tools available at specified addresses.
 - [ ] Agent Profile Config page (JSON): basic page to define tool selections via JSON (scaffold; profiles selectable UX comes later).

### Stage 5 — Tests (MVP)
- [ ] Unit tests for `tool_call_parser.dart`.
- [ ] Unit tests for `mcp_service.dart` (mock WebSocket) covering list/call and error paths.
- [ ] Provider test: simulate a tool call streamed from the model and verify orchestration.


## MVP: File-by-File Implementation Plan (lib/)

### Stage 0 — Scaffolding (create new files)

- [x] __Create__ `lib/Services/mcp_service.dart`
  - Implemented interface and transports: WebSocket + HTTP/SSE (Gateway).
  - Exposes: `connectAll(List<McpServerConfig>)`, `connectionStates()`, `listTools({server})`, `call(server, tool, args)`.
  - WebSocket path wrapped with `json_rpc_2.Peer`; HTTP/SSE uses custom channel and sink.

- [x] __Create__ `lib/Models/mcp.dart`
  - `McpServerConfig { name, endpoint, authToken? }`
  - `McpTool { server, name, description?, inputSchema? }`
  - `McpToolCall { server, name, args }`
  - `McpToolResult { result, error? }`

- [x] __Create__ `lib/Utils/tool_call_parser.dart`
  - `parseToolCall(String)` detects `TOOL_CALL:` line, parses JSON -> `McpToolCall?`.
  - `formatToolResult(String toolName, dynamic result, {String? error})`.

- [x] __Create__ `lib/Constants/tool_system_prompt.dart`
  - `String toolSystemPrompt(List<McpTool> tools)` to render tool list + exact sentinel usage instructions.

- __Feasibility__: Straightforward scaffolding; no platform constraints. Pure Dart data/models and helpers.
  - __Note__: Add `web_socket_channel` to `pubspec.yaml`. Consider `flutter_secure_storage` later for tokens (Production).

### Stage 1 — MCP Service (wire transport)

- [x] __Edit__ `lib/Services/mcp_service.dart`
  - Implemented WebSocket client (via `web_socket_channel`) and HTTP/SSE channel.
  - WebSocket path uses `json_rpc_2.Peer` for ids, requests, notifications, and errors.
  - Methods: `initialize`, `tools/list`, `tools/call`, with id routing and error mapping.

- [x] __Edit__ `lib/main.dart`
  - Provides `McpService` in `MultiProvider` and wires startup to read `mcpServers` from Hive and `connectAll` then warm `listTools`.

- __Feasibility__: High. WS and HTTP/SSE confirmed working against Gateway; add reconnect/backoff next.

### Stage 2 — Prompt Protocol & Parser integration

- [x] __Edit__ `lib/Constants/tool_system_prompt.dart`
  - Implemented prompt appendix including strict format for `TOOL_CALL:` and example JSON.

- [x] __Edit__ `lib/Providers/chat_provider.dart`
  - Injects tool appendix at send time (do not mutate DB-stored prompt).
  - Detects `TOOL_CALL:` mid-stream using `parseToolCall`; cancels, calls MCP, injects `TOOL_RESULT:`, resumes stream.

- __Feasibility__: High. Completed and verified in app flows.

### Stage 3 — ChatProvider Orchestration

- [x] __Edit__ `lib/Providers/chat_provider.dart`
  - On detecting a `McpToolCall`, pause streaming, call MCP, inject `TOOL_RESULT:`, then resume generation with updated transcript. Guard flags added.

- __Feasibility__: Completed. Provider integration working; tests pending.

### Stage 4 — Settings Wiring (Servers + Discovery)

- [x] __Edit__ `lib/Pages/settings_page/subwidgets/mcp_settings.dart`
  - Added MCP Servers section with fields: Name, Endpoint, optional Auth Token.
  - Persists to Hive `settings['mcpServers']` as a list of `{ name, endpoint, authToken? }`.
  - On Save: triggers `disconnectAll → connectAll → listTools` warmup.
  - Shows per-row connection status chip using `McpService.connectionStates()`.
  - Shows live tools count and a "View" dialog pulling from `McpService.getTools(serverUrl)`.

- [x] __Edit__ `lib/main.dart`
  - Reads `mcpServers` on startup, constructs `McpServerConfig`, wires `connectAll` and tools warmup.

- [ ] Auto-discovery UI: desktop/mobile only. Not feasible on Web due to browser restrictions.
- [ ] Per-chat toggles to enable/disable servers/tools for a given chat.
- [ ] Configure Chat popup: allow selecting tools based on available addresses.
- [ ] Agent Profile Config page (JSON): define tool selections via JSON (profiles selectable UX later).

- __Edit__ `lib/main.dart`
  - After Hive open, ensure `settings.putIfAbsent('mcpServers', () => <Map<String, dynamic>>[])`.
  - On provider creation, read configs and invoke `connectAll`, then optionally `listTools` to warm cache.

- __Feasibility__: High. Settings UI and Hive persistence already exist for Ollama server. Adding a parallel section for MCP servers is routine. Network scan is best-effort and may be desktop/mobile only (skip on Web or restrict to user-provided endpoints).
  - __Notes__: For web, only allow manual WSS endpoints; document mixed content constraints.

### Stage 5 — Tests

- __Create__ `test/tool_call_parser_test.dart`
  - Cases: valid call, extra whitespace, invalid JSON, partial lines.

- __Create__ `test/mcp_service_test.dart`
  - Mock WebSocket server; cover `initialize`, `tools/list`, `tools/call`, error mapping.

- __Create__ `test/chat_provider_tool_call_test.dart`
  - Simulate stream containing a `TOOL_CALL:` line; assert `TOOL_RESULT:` insertion and resumed generation.

- __Feasibility__: High. Use mock channels and injected dependencies. Web platform tests run on VM; no UI needed.


## Production Implementation Stages and Steps

### Stage P1 — UI/UX Polish
- [ ] Distinct visual treatment for tool calls/results (cards, icons, monospace, collapsible).
- [ ] Inline spinner while executing; allow cancel.
 - [ ] Agent Profiles: preconfigured tool selections/custom sets that can be selected per chat.
 - [ ] Tasks page: agent automations with preselected profile and prompts (create/run/schedule tasks).

__Feasibility notes__
- High. Pure Flutter UI changes; no platform blockers. Agent Profiles need a small config schema and per-chat persistence.

### Stage P2 — Roles and Structure
- [ ] Add `tool` role to `OllamaMessage` (new enum value) and support in DB mapping.

__Feasibility notes__
- Medium. Touches models, DB migrations, and rendering. Backward compatibility required for stored transcripts.
- [ ] Display tool messages differently and exclude them from user-visible text if desired.
 - __DB migration__: Extend role enum or remove CHECK; provide `onUpgrade` path and data backfill where necessary.

### Stage P3 — Transport & Auth
- [ ] Add stdio transport for local MCP servers (desktop first).
- [ ] Add per-server auth (headers/tokens) and secure storage.
 - [ ] OAuth and other authentication flows for authenticated MCP servers (e.g., Zapier, Google); token storage/refresh.
 - [ ] Remote access helpers: Tailscale/MagicDNS support for remote local-network access.
 - [ ] Ability to launch/manage selected MCP servers locally at runtime (desktop-first), similar to advanced IDE clients.
 - __Notes__: Stdio is desktop-first. Use `flutter_secure_storage` for tokens on mobile/desktop; web requires alternative storage strategy.

### Stage P4 — Schema & Validation
- [ ] Validate tool args against JSON Schema; show UI form for argument building (optional).
- [ ] Pre-exec confirmation for sensitive tools.

### Stage P5 — Observability
- [ ] Add structured logging and diagnostics view.
 - [ ] Status page or overlay to visualize connection status/health for each MCP server and tool (latency, last error).

### Stage P6 — Reliability
- [ ] Add retries/backoff; circuit breakers; per-call timeouts and budgets.

### Stage P7 — Testing & QA
- [ ] Integration tests across transports and multiple servers.
- [ ] Snapshot tests for tool UI; performance tests for large tool outputs.

## Roadmap: Mid-term and Long-term Goals

### Near-term (MVP)

- __Auto-discovery & zero manual config__
  - UI to scan one or more user-provided hosts for MCP servers and present a selectable list.
  - Per-chat toggles to enable/disable discovered servers/tools.
   - __Platform note__: Not supported on web; desktop/mobile only.

- __Agent Profile Config Page via JSON__
  - Dedicated page to configure tools per agent profile using JSON (with validation and examples).

- __Configure Chat panel integration__
  - Extend the existing "Configure the Chat" popup to select tools based on the tools available at specified addresses.

### Mid-term

- __Agent Profiles__
  - Preconfigured tool selections and behaviors that can be chosen per chat.
  - Support custom profiles created by users.

- __Tasks Page__
  - Agent automations with preselected profiles and prompts; runnable and schedulable tasks.

### Long-term

- __Authenticated MCP servers__
  - OAuth and other authentication flows for providers such as Zapier or Google.
  - Token storage and refresh handling.

- __Status Page/Overlay__
  - Visualize connection status/health for each MCP server and tool; include last error and latency.

- __Remote network access helpers__
  - Integration or automatic support for Tailscale for remote local-network access when not covered by MagicDNS.

- __Run local MCP servers at runtime__
  - Ability to launch/manage selected MCP servers locally from the client (desktop first), similar to advanced IDE clients.

## Milestones and Success Criteria

- __MVP Complete__: Model can request at least one tool from a connected MCP server; Reins executes it and the model uses the result to produce a final answer.
- __Production Ready__: Stable tool loop with clear UI, tests in place, error handling, and support for multiple transports.

## Immediate Next Actions (Week 1)

1) Stage 0: Scaffold files and add dependency `web_socket_channel`.
2) Stage 1: Implement `McpService` (connect/list/call) against a local WebSocket-based MCP server.
3) Stage 2: Implement `tool_call_parser` and `tool_system_prompt` with 1–2 tool examples.
4) Stage 3: Minimal changes in `ChatProvider` to intercept `TOOL_CALL:` and resume with `TOOL_RESULT:`.

### Next Steps (short)
- Ensure the Docker MCP Gateway is running with `--transport streaming` at `http://localhost:7999`.
- Reconnect and check logs for `MCP HTTP(streaming) connect ->`, `MCP initialize OK`, and `MCP tools/list` totals.
- If no initialize logs appear, perform a full app restart (not hot reload).
- Wire Settings UI tooltip to show `McpService.getLastError(serverUrl)` for quick diagnosis.
- If tools remain empty, verify whether the gateway requires a server selector param in `tools/list`; add if necessary.

### Optional track: Web Compatibility
- Add `kIsWeb` guards and conditional imports to files that use `dart:io` (`main.dart`, `database_service.dart`, `ollama_message.dart`).
  - Implemented: guarded `Platform` checks in `lib/main.dart`; disabled PathManager initialization on web; disabled local-network search button on web.
- Swap/guard `sqflite` for a web-compatible persistence (e.g., Hive-only for chats) on web builds.
  - Implemented: guarded all `DatabaseService` calls in `lib/Providers/chat_provider.dart`; chats/messages stored in-memory on web for now.
  - Implemented: guarded `deleteMessage()` path too, preventing web-side deletes.
- Replace `File` handling with `XFile`/`Uint8List` abstractions on web.
  - Implemented partial: attachments flow disabled on web with snackbar notice in `lib/Pages/chat_page/chat_page.dart`.
  - Implemented: guarded all file/path access in `lib/Models/ollama_message.dart` (base64 encode, construct paths, relative paths) using `kIsWeb`.
- Ensure `wss://` endpoints when served over HTTPS; document local dev reverse proxy.
  - TODO: verify/document wss configuration and reverse proxy for web.

Additional fixes:
- Guarded `PathManager.initialize()` against Web (`lib/Constants/path_manager.dart`) to avoid `getApplicationDocumentsDirectory` on Web.
- Removed `dart:io Platform` usage in settings page (`lib/Pages/settings_page/subwidgets/reins_settings.dart`) with `kIsWeb` and `defaultTargetPlatform`.

## References

- Key code paths:
  - `ChatProvider._streamOllamaMessage()` in `lib/Providers/chat_provider.dart`
  - `OllamaService.chatStream()` in `lib/Services/ollama_service.dart`
- Settings storage: `Hive.box('settings')` in `lib/main.dart`
