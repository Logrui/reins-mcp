# Reins MCP Client — Living Plan

This document tracks the plan, design, and implementation of MCP (Model Context Protocol) client and tool-calling support in Reins. 

---

## 1. Project Overview & Status

### Goal

Enable Reins to act as an MCP client, allowing LLMs to execute tools exposed by connected MCP servers. The model will request a tool, Reins will execute it via MCP, and the result will be fed back into the conversation to generate a final answer.

### Current Status

- __MVP Complete__: The core tool-calling loop is functional across WS and HTTP/SSE. Structured tool-calls are primary with sentinel fallback. Chat stream interception and Hive persistence are in place.
- __UI/UX Enhancements__: "Thinking" UI for tool calls shipped. Data model uses structured objects (`McpToolCall`, `McpToolResult`). Dedicated `tool` role is supported end-to-end (model, provider, persistence).
- __Streaming Lifecycle Fixes__: Implemented thinking re-enable per loop, `supportsTools` cache, and explicit cancellation flags to stabilize multi-turn flows.
- __Deterministic Transcript__: `ChatProvider` now appends assistant messages independent of UI state and fixes null-safety around tool-call handling.
- __Tests Passing__: Multi-turn tool flow regression test now passes (two sequential tool calls + final answer).
- __Dev Observability Logs__: Instrumented `ChatProvider` with `McpService.logDev()` around tool-call detection, execution, validation, cancellation, and stream restarts. Structured events include `requestId` from `McpToolCall.id` for log linkage.
- __Settings Logs Console (Settings UI)__: Added live-tail logs console with filters, search, live-tail toggle, and clear in `lib/Pages/settings_page/subwidgets/mcp_settings.dart`, consuming `McpService.logs`. Levels color-coded; expandable JSON details.
 - __Chat Dev Drawer__: Added a debug panel on the chat page in `lib/Pages/chat_page/subwidgets/chat_dev_drawer.dart` with server/level/category/search filters, live-tail auto-scroll, and a RequestId filter linked to tool-call IDs. On small screens it opens as an end-drawer overlay; on large screens it renders as a sibling right-side panel next to the chat and can be toggled from both the Chat AppBar bug button and the floating bug FAB.
- __Focus__: Schema validation integrated; next priorities: Chat Dev panel, last-error tooltip + status badges, provider logging tests.

### Immediate Next Actions

- [x] __Implement "Thinking" UI (HIGH)__: The chat now visualizes in-progress tool calls.
- [x] __Enhance Data Model (MED)__: The data model now uses structured `McpToolCall` and `McpToolResult` objects, eliminating raw string parsing for tool calls.
- [x] __Tests (MED)__: Added a provider-level test to validate the new tool-call orchestration flow.
- [x] __Step 1 — Provider deterministic transcript & persist-before-call__: Implemented in `ChatProvider._streamOllamaMessage()`; assistant messages are always appended for the associated chat, tool-call assistant messages are persisted before execution, and null-safety/logging improved. Validated by passing multi-turn test (2025-08-29).

### Next Steps (short)

- __Run Gateway streaming path__: Ensure Docker MCP Gateway is running with `--transport streaming` at `http://localhost:7999`.
- __Reconnect + verify logs__: Look for `transport/rpc/tool` categories in logs and linkage by `requestId`.
- __Full restart if needed__: If no initialize logs appear, perform a full app restart (not hot reload).
- __Diagnose quickly__: Wire Settings tooltip to show `McpService.getLastError(serverUrl)` for last connection error.
  
- __Provider logging tests__: Add integration tests to assert `ChatProvider` emits lifecycle logs with `requestId` on intercept/execute/validate/cancel.
- __Add more regressions__: Cover timeout path for tool calls to complement the passing cancellation and server error tests.

---

## 2. Roadmap

### Short-Term: UI Polish & Data Model

- [x] __Logging Hygiene__: Gated verbose logs behind a debug flag and scrubbed secrets from output.
- [x] __Settings UI Polish__: Improved validation, error surfacing, and added tooltips in `lib/Pages/settings_page/subwidgets/mcp_settings.dart`.
- [x] __Spinner/Cancel__: Show an inline spinner while a tool is executing and provide a mechanism to cancel the operation.

### Long-Term: Protocol & Architecture Refactoring

- [x] __Adopt Structured Tool-Call Protocol__: Transitioned from `TOOL_CALL:`/`TOOL_RESULT:` sentinels to structured `tool_calls`/`tool_results` where supported; fallback retained for non-capable models. System prompt and `OllamaService` updated accordingly.

- [x] __Refactor ChatProvider for Recursive Dispatch__: Provider now completes a generation, executes tools, appends results, and starts a new generation with updated history. Improves reliability over mid-stream resumption.

- [ ] __Introduce `tool` Role__: Add a dedicated `tool` role to the `OllamaMessage` model and database for a fully structured transcript and distinct UI rendering.

### Future Enhancements

- __Advanced Transports__: Add stdio transport for managing local MCP servers on desktop.
- __Authentication__: Support per-server authentication (API keys, tokens) with secure storage.
- __Schema & Validation__: Use tool input JSON Schemas to validate arguments and optionally build a UI for argument entry.
- __Observability__: Create a developer panel or status page to inspect MCP traffic and connection health.

### Gaps to Fully Fledged Support

- __Multi-turn stability__: Harden recursive tool-call orchestration for two-or-more sequential tool calls; eliminate timeouts in tests and in real flows.
- __Structured transcript fidelity__: Introduce a dedicated `tool` role in `OllamaMessage` and persist it so tool calls/results render distinctly from assistant messages.
- __Schema-aware validation__: Validate tool arguments against MCP JSON Schemas; show inline validation errors and prevent bad calls.
- __Observability & diagnostics__: Add a Dev panel to show initialize/logs, tools/list, tools/call traffic and last errors per server.
- __Settings polish & auth__: Last-error tooltip wired to `McpService`, per-server auth tokens, connection status badges.
- __Web transport hardening__: Prefer native EventSource for SSE on web, enforce WSS under HTTPS; document CORS/proxy setup.
 - __HTTP/SSE hardening__: Client now tries multiple SSE endpoints, follows redirects, propagates cookies, and sets dual Accept header for JSON POSTs.
- __Desktop stdio roadmap__: Plan stdio transport for local servers (Windows/macOS/Linux), feature-gated.
- __UX improvements__: Expandable tool results, copy/export, truncation with “show more”, compact “Tools used” summary per turn.

### Concrete Next Actions

- [x] __Fix multi-turn test & add regression__: `chat_provider_tool_flow_test.dart` stabilized to simulate two sequential tool calls before final answer; deterministic fakes and consistent DB naming verified. (Completed 2025-08-29)
- [x] __Step 1 — Provider deterministic transcript & persist-before-call__: Landed and verified by tests. (Completed 2025-08-29)
- [x] __Add `tool` role & persistence__: `OllamaMessage` supports `tool` role; `DatabaseService` schema (v3) persists `role` including `tool`, plus `tool_call` and `tool_result`. `ChatProvider` creates tool-role messages for calls/results. (Completed 2025-08-29)
- [x] __Implement schema validation__: `JsonSchemaValidator` (subset) added; `McpService.validateToolArguments()` exposed; `ChatProvider._executeToolCall()` short-circuits invalid args with inline error.
- [x] __Instrument ChatProvider MCP logging__: Added `logDev()` around tool-call detection, execution start/done, validation failures, cancellations, and restart-generation with `requestId` linkage. (Completed 2025-08-29)
- [ ] __Observability panel__: Build a developer panel showing recent MCP traffic and last errors; add log toggles.
- [ ] __Settings polish__: Last-error tooltip from `McpService.getLastError(serverUrl)`, per-server auth tokens, status badges.
- [ ] __Web SSE path__: Use `dart:html EventSource` under web builds; enforce WSS; add CORS/proxy notes to README.
- [x] __HTTP/SSE transport hardening__: Endpoint fallbacks (`/sse`, base, `/events`, `/stream`, etc.), GET/POST attempts, redirect-follow, cookie propagation, and `Accept: application/json, text/event-stream` on POSTs.
- [ ] __Make SSE path configurable__: Add custom SSE path in Settings; try this first when connecting.
- [ ] __Toggle for POST-to-open__: Some gateways require POST to establish SSE; surface a setting to force POST-first.
- [ ] __Plan desktop stdio__: Spike a prototype behind a feature flag; scope OS-specific constraints and packaging.
- [ ] __Add cancellation & error-path tests__: Server error and user-cancel tests implemented; add timeout regression next.

### iOS (Windows) Deployment via AltStore

- [x] __CI to produce unsigned IPA__: Added GitHub Actions workflow `/.github/workflows/ios-ips.yml` building `flutter build ipa --no-codesign` and uploading `reins-mcp-ipa` artifact.
- [x] __Docs__: Created `/.mcp-docs/ios-altstore-deploy.md` with step-by-step instructions to download IPA and sideload via AltStore on Windows.

 - [ ] __Dev Observability & Logging Console__: Add a developer observability panel in chat and a multi-tab logging console in MCP Settings (details in Section 7).

#### Action Items — Stabilize Multi‑Turn Tool Flow Test

1. __Override model capability in test fake__
   - File: `test/chat_provider_tool_flow_test.dart`
   - In `_FakeOllamaService`, override `getModel(String name)` to return an `OllamaModel` with `supportsTools: true` (matching `listModelsWithCaps()`).

2. __(Optional) Add provider test seam__
   - File: `lib/Providers/chat_provider.dart`
   - Add `@visibleForTesting void setSupportsToolsForModel(String model, bool value)` that writes into `_supportsToolsCache`.
   - Use it in the test to avoid any capability lookup flakiness.

3. __Use seam in test (if added)__
   - After creating the chat and before `sendPrompt()`, call `provider.setSupportsToolsForModel('llama3.2:latest', true)`.

4. __Run the single test__
   - Command: `dart test test/chat_provider_tool_flow_test.dart -p vm`
   - Expect `ollama.chatStreamCalls == 3` and final message `"Final response: second"`.

5. __Add a regression variant__
   - Duplicate the test with two sequential tool calls using different args; assert order and results.

6. __Timeout hygiene__
   - If needed, increase the completer wait from 5s to 8–10s; keep overall test timeout at ~10–15s.

---

## 3. Architecture & Design Reference

### Architecture Overview (Flutter + Reins)

- __Flutter cross-platform__: One Dart codebase targeting iOS, Android, macOS, Windows, Linux, and Web. UI built with Flutter widgets; business logic and services are pure Dart where possible.
- __Core Services & State__:
  - `lib/Services/ollama_service.dart`: Handles HTTP/streaming communication with the model server.
  - `lib/Providers/chat_provider.dart`: Orchestrates the entire chat lifecycle, including streaming, state management, and tool-call interception.
  - `lib/Services/database_service.dart`: Manages persistence with Hive and SQLite.
  - `lib/Services/mcp_service.dart`: A dedicated service for MCP communication (WebSocket + JSON-RPC 2.0).

### High-Level Design

- __MCP Service Layer__: The `McpService` connects to MCP servers (via WebSocket or HTTP/SSE) and exposes methods to list and call tools.
- __Tool-Call Protocol (Current)__:
  - __Primary (Structured)__: When the model supports tools, we use structured `tool_calls` from the model and inject `tool_results` back into the transcript via `OllamaMessage` fields (`toolCall`, `toolResult`).
  - __Fallback (Sentinel)__: If structured tools are not supported, we fall back to text sentinels:
    - Model emits: `TOOL_CALL: {"server":"<srv>","name":"<tool>","args":{...}}`
    - App replies: `TOOL_RESULT: {"name":"<tool>","result":<any>}`
- __Prompt Injection__: The system prompt is dynamically augmented with a list of available tools and usage instructions.
- __Orchestration__: `ChatProvider` runs a clean loop per generation: complete stream, execute any tool calls via `McpService`, append results, then start a new generation with updated history (recursive dispatch). This replaces brittle mid-stream resumption.

### Touch Points in `ChatProvider`

- __Prepare request__: `effectiveSystemPrompt = chat.systemPrompt + toolSystemPrompt(availableTools)`.
- __Stream loop__: Accumulate streamed content; when structured `tool_calls` appear or a `TOOL_CALL:` line is detected, stop the stream.
- __Execute tool__: Call `McpService.call(server, tool, args)`; capture result/error.
- __Inject result__: Append a `tool` result message (structured) or a `TOOL_RESULT:` assistant line (fallback).
- __Restart generation__: Start a new generation with updated history (guard against re-entrancy; ensure prior stream cancelled).

### Tool Usage Testing Plan

Validate end-to-end tool calling with both structured tools and the sentinel fallback.

- __Prerequisites__:
  - `McpService` connected to at least one server exposing a simple tool (e.g., `echo`, `time.now`).
  - System prompt includes the tool appendix from `lib/Constants/tool_system_prompt.dart`.
- __Manual E2E Checklist__:
  1. Start a new chat and verify tools are reflected in the system prompt (dev logs).
  2. Ask a query that requires a tool, e.g., “What’s the current UTC time? Use a tool if needed.”
  3. Structured path: model emits a `tool_calls` entry; fallback path: emits a `TOOL_CALL:` JSON line.
  4. Execute MCP call; inject result (structured `tool_results` or `TOOL_RESULT:` line).
  5. Start a new generation with the updated history; confirm assistant references the tool result.
  6. Error path: break args or network; verify error result is injected and the model handles it gracefully.

### Ollama Model Compatibility

- __Detection__: We enrich models via `ollama.show` and compute `supportsTools` from `metadata.capabilities`. This is implemented in `lib/Services/ollama_service.dart` and surfaced through `listModelsWithCaps()`.
- __Adherence__: Instruct-tuned models follow `TOOL_CALL:`/`TOOL_RESULT:` sentinels best. Best practice is to keep the temperature low (0.1–0.3) and include exemplars in the system prompt appendix.

### Data Persistence

- __Hive Settings__ (`Hive.box('settings')`):
  - `serverAddress` (existing for Ollama)
  - `mcpServers` (new): A list of objects `{name, endpoint, authToken?}`.
- No schema migration is required for settings; the app defaults to an empty list if the key is missing.



#### Tool Call Utilities (`lib/Constants/tool_system_prompt.dart`, `lib/Utils/tool_call_parser.dart`)

- Prompt appendix renders a concise list of tools and usage rules for structured and fallback modes.
- Fallback parser utilities expose `kToolCallPrefix`, `kToolResultPrefix`, `parseToolCall(String)`, and `formatToolResult(...)`.

### Key Implementation Files

- __Orchestration__: `lib/Providers/chat_provider.dart`
- __MCP Service__: `lib/Services/mcp_service.dart`
- __Models__: `lib/Models/mcp.dart`, `lib/Models/ollama_message.dart`
- __System Prompt__: `lib/Constants/tool_system_prompt.dart`
  

### Platform Constraints

- __Web__: Browser environment lacks `dart:io` and `sqflite`. Use `kIsWeb` guards to disable DB/file operations; prefer Hive-only persistence on web. Require `wss://` when served over HTTPS to avoid mixed content. Consider native browser SSE via `dart:html` for Gateway paths.
- __Mobile (iOS/Android)__: Network permissions required. Allow cleartext to `localhost` in dev (ATS/iOS, Network Security Config/Android). No stdio transport on iOS; limited on Android.
- __Desktop (Windows/macOS/Linux)__: Most flexible; full WS/HTTP support and candidates for future stdio transport.

### Transport Details (WS + HTTP/SSE)

- __WebSocket__: Wrap channel with `json_rpc_2.Peer`; support binary frames (UTF-8 decode) and heartbeat + reconnect with backoff.
- __HTTP/SSE (Gateway)__: Use a custom `HttpSseStreamChannel` bridging SSE (incoming) and POST (outgoing), wrapped with `json_rpc_2.Peer`.
- __Session discovery__: Prefer emitted `/message?sessionId=...`; fallback to `/sse?sessionid=...`, `/message`, `/rpc`, or base URL.
- __Envelope tolerance__: Accept `{event,data}`, `{data:{message:{...}}}`, `{payload:...}`, and batch arrays.
- __Diagnostics__: Log first-page keys, pages/cursors, totals per server; cache last error per server for Settings tooltip.

### Cross-Platform Transport Support Plan

- __Web__: Prefer native browser SSE via `dart:html EventSource` for Gateway; ensure `wss://` under HTTPS; document proxy/CORS.
- __Android/iOS__: INTERNET/ATS config for dev; maintain reconnect/backoff; expose TLS hooks.
- __Desktop__: Full WS+SSE; candidates for future stdio transport; TLS hooks.
- See `.mcp-docs/MCP-Transport-Platform-Compatibility.md` for details.

### Risks and Mitigations

- __LLM adherence__: Sentinel fallback can be brittle; mitigate with clear prompt appendix, examples, tolerant parsing, and prefer structured tools when available.
- __Latency__: Tool calls add round trips; show spinner/"Thinking" UI; support cancellation and reasonable timeouts.
- __Large outputs__: Truncate/summarize tool results before injection; allow expand-on-demand UI later.
- __Transport variability__: Some servers require stdio; start with WS/SSE; plan stdio on desktop in production.
- __Web constraints__: HTTPS + WSS requirement and CORS; document reverse proxy; avoid port scanning; use `dart:html` EventSource for SSE.
- __Stream orchestration risk__: Duplicate/interleaved tokens; always cancel before restart; use guard flags and tests.

---

## 4. Milestones and Success Criteria

- __MVP Complete__: Model can request a tool from a connected MCP server; Reins executes it; model uses the result to produce a final answer.
- __Production Ready__: Stable tool loop with clear UI, tests, error handling, and multiple transports supported.

## 4.1 MVP Implementation Stages (Condensed)

- __Stage 0 — Scaffolding__: Models, service, parser, prompt appendix.
- __Stage 1 — MCP Service__: `initialize`, `tools/list`, `tools/call` over WS+SSE via `json_rpc_2.Peer`; reconnect/heartbeat.
- __Stage 2 — Prompt & Parser__: Tool appendix; sentinel parser/formatter (fallback path).
- __Stage 3 — Chat Orchestration__: Intercept → cancel → MCP call → inject result → restart generation (recursive dispatch).
- __Stage 4 — Settings__: Hive persistence for `mcpServers`; minimal UI; last-error tooltip.
- __Stage 5 — Tests__: Service, parser (fallback), provider orchestration, and SSE parsing basics.

## 4.2 MVP: File-by-File Plan (lib/)

- __Create__ `lib/Services/mcp_service.dart` and `lib/Models/mcp.dart` (done); unify WS+SSE via `json_rpc_2.Peer`.
- __Create__ `lib/Services/http_sse_channel.dart` for Gateway SSE path.
- __Create__ `lib/Constants/tool_system_prompt.dart`; __(fallback)__ `lib/Utils/tool_call_parser.dart`.
- __Edit__ `lib/main.dart`: provide `McpService`, read `mcpServers`, `connectAll` then warm `listTools`.
- __Edit__ `lib/Providers/chat_provider.dart`: inject prompt appendix; structured tools primary; sentinel fallback.
- __Edit__ Settings subwidgets: list/edit servers; show connection state and last error.

## 5. Archive

<details>
<summary>Progress Update — 2025-08-28 (Architectural Refactor: Structured Tool-Calls)</summary>

- **Objective**: Replace the brittle text-based tool-call protocol (`TOOL_CALL:`/`TOOL_RESULT:`) with a structured JSON protocol natively supported by newer Ollama models.
- **`OllamaMessage` & `McpToolCall` Models**:
  - Updated `McpToolCall` to include an `id` field and a `function` object wrapper (`{name, arguments}`) to match the Ollama API schema.
  - Modified `McpToolCall.fromJson` to be backward-compatible, handling both the new structured format and the old sentinel format during the transition.
  - Enhanced `OllamaMessage` to deserialize the `tool_calls` array from the API response into an `McpToolCall` object.
  - Updated `OllamaMessage.toChatJson` to serialize `tool_results` into the format expected by the Ollama API, including the tool call `id`.
- **`ChatProvider` Refactor**:
  - Removed all dependencies on `tool_call_parser.dart`.
  - Replaced text sentinel detection with structured `message.toolCall != null` checks.
  - Adopted a recursive dispatch loop: finish a generation, process tool calls, append results, then start a new generation.
- **`OllamaService` Enhancements**:
  - Added a `supportsTools` flag to the `chatStream` method.
  - When `supportsTools` is true, the service now includes a `"tools": [...]` array in the `/api/chat` request payload, signaling structured tool support to the model.
  - Implemented `getModel()` to fetch a single model's capabilities.
- **System Prompt & Testing**:
  - Simplified `generateToolSystemPrompt` to produce a clean JSON description of available tools for models that support the new protocol.
  - Deleted the obsolete `tool_call_parser.dart` and its associated test file.
  - Rewrote `chat_provider_tool_flow_test.dart` to validate the new end-to-end flow using structured `McpToolCall` and `McpToolResult` objects instead of string parsing.

</details>
<details>
<summary>Progress Update — 2025-08-29 (ChatProvider MCP logging instrumentation)</summary>

- Added structured developer logging in `lib/Providers/chat_provider.dart` using `McpService.logDev()` with categories `chat` and `tool`.
- Emission points: loop start, prompt prepared, supportsTools resolved, stream start, intercept tool call, execute start/done, validation failed, cancelled before/after call, result saved, and return-to-stream.
- Logs include `requestId` from `McpToolCall.id` and `serverUrl` when available; kept payloads concise to avoid leaking sensitive data.
- Prepares for Settings/Chat Dev panels to live-tail MCP traffic and annotate turns.

</details>
<details>
<summary>Progress Update — 2025-08-29 (Settings Logs UI fixes)</summary>

- Fixed a runtime assertion in the logs server filter: deduplicated server options and guarded the selected value with an effective fallback when not present.
- Doubled the logs panel height constraints from 160–320 to 320–640 for better vertical space.

</details>
<details>
<summary>Progress Update — 2025-08-29 (HTTP/SSE connection fixes)</summary>

- Prevented POSTs to `/message`, `/rpc`, or base before session is established; now queue requests until the SSE `endpoint` provides a `sessionid`, then flush to the emitted endpoint with canonical fallback.
- Disabled `$\/ping` heartbeats for HTTP/SSE transports; heartbeats now only run for WebSocket connections.

</details>
<details>
<summary>Progress Update — 2025-08-28 (Streaming Lifecycle Fix & Stability)</summary>

- Fixed a critical issue where the second generation after a tool call was misinterpreted as cancelled. We now re-enable the thinking indicator at the start of each iteration in `ChatProvider._streamOllamaMessage()`.
- Added `_supportsToolsCache` to avoid repeated `getModel()` calls inside the tool loop.
- Introduced `_cancelledChatIds` to explicitly mark stream cancellations, reducing race conditions and improving reliability.
- Updated tests to ensure deterministic tool-call streaming in fakes and aligned DB naming (`ollama_chat.db`).

</details>

---

## 6. Appendix — Notes merged from backup

- __Files changed (Stage 2)__
  - `lib/Providers/chat_provider.dart`: `fetchAvailableModels()` now calls `listModelsWithCaps()`.
  - `lib/Widgets/selection_bottom_sheet.dart`: added `itemBuilder`, `valueSelector`, `currentSelectionValue`; selection returns `Future<T?>`.
  - `lib/Widgets/chat_app_bar.dart`: model picker shows `OllamaModel` list with a “Tools” Chip when `supportsTools` is true.

- __Optional tracks & web compatibility__
  - Add `kIsWeb` guards and prefer Hive-only persistence on web; document `wss://` with HTTPS.
  - Consider native browser SSE (`dart:html`) for Gateway.

- __Testing progress (t73)__
  - In-memory `json_rpc_2.Peer` seam for `McpService` tests.
  - Basic unit tests for MCP list/call flows and parser (historical, now replaced by structured path).

<details>
<summary>Expand to see archived progress logs</summary>

### UI Polish & Spinner/Cancel Implementation (Completed 2025-08-28)

- __Logging Hygiene__: Wrapped all `debugPrint` calls in `mcp_service.dart` with `kDebugMode` checks to ensure verbose logs are stripped from release builds.
- __MCP Settings UI Polish__: Implemented live URI validation for server endpoints, added tooltips for connection error statuses, included a confirmation dialog before server deletion, and made the "Save & Reconnect" button state-aware (disabled on error or no changes).
- __Spinner & Cancellation__: Enhanced the `ToolCallMessage` widget to display a `CircularProgressIndicator` during execution and a "Cancel" button. Updated `ChatProvider` to handle cancellation requests, mark the corresponding tool call message as cancelled, and prevent the result from being processed.


### MVP Stages Summary (Completed)

- __Stage 0 — Scaffolding__: Models, service stubs, parser, prompt appendix.
- __Stage 1 — MCP Service__: `initialize`, `tools/list`, `tools/call` over WS+SSE, with reconnect/heartbeat.
- __Stage 2 — Prompt & Parser__: `TOOL_CALL` / `TOOL_RESULT` parser and prompt injection.
- __Stage 3 — Chat Orchestration__: Stream intercept, cancel, call, and resume logic.
- __Stage 4 — Settings__: Minimal UI and Hive persistence for MCP servers.
- __Stage 5 — Tests__: Unit tests for parser and mock service behavior completed.

### Detailed Development Logs

#### Data Model & "Thinking" UI (Completed 2025-08-28)

- __Data Model__: Enhanced `OllamaMessage` to include optional `McpToolCall` and `McpToolResult` fields. This moves the system away from brittle string parsing and toward a more robust, structured data approach.
- __"Thinking" UI__: Implemented a new `ToolCallMessage` widget that renders a special "Thinking" state when a tool call is initiated. `ChatProvider` was updated to create a message with a `tool` role, which is then updated with the result upon completion. This provides users with clear feedback and visibility into the tool execution process.

#### Testing Progress (t73)

- Added a test seam to `McpService`: `attachPeerAndInitialize(serverUrl, rpc.Peer)` marked `@visibleForTesting` to attach an in-memory `json_rpc_2.Peer` and run `initialize` + `tools/list` without real network.
- Introduced `DummyMessageChannel` to satisfy internal channel checks during tests.
- Created unit tests for `tool_call_parser.dart` and `mcp_service_test.dart` using `StreamChannelController<String>` + `json_rpc_2.Server` to simulate `initialize`, `tools/list`, `tools/call` (echo) and validate service behaviors.
- Added `meta` dependency for `@visibleForTesting`.


#### Progress Update — 2025-08-28 (Transport & Resilience)

- Implemented `HttpSseStreamChannel` at `lib/Services/http_sse_channel.dart` bridging SSE (incoming) and POST (outgoing) under `StreamChannel<String>`.
- Wired both WebSocket and HTTP/SSE transports through `json_rpc_2.Peer` for consistent RPC handling.
- Added resilience features: WebSocket heartbeat with reconnect on timeout, and exponential backoff for both WS and SSE connections.
- Refactored heartbeat/reconnect helpers into `McpService` as private instance methods to fix scope errors and access class state consistently.
- Performed extensive analyzer cleanup, removing unused code, redundant imports, and improving documentation.

#### Progress Update — 2025-08-27 (Transport Unification & SSE Enhancements)

- Unified WebSocket and HTTP/SSE transports to use `json_rpc_2.Peer`, simplifying the `McpService` logic.
- Improved SSE event framing to correctly handle multi-line `data:` chunks and various JSON envelope formats.
- Enhanced logging for SSE session extraction and JSON-RPC diagnostics.
- Aligned with gateway contracts by handling lowercase `sessionid` and resolving `RequestURI` correctly.

</details>

---

## 7. Dev Observability & Logging Console Plan

### 7.1 Objectives

- Provide real-time visibility into MCP connectivity, RPC traffic, tool discovery/calls, and errors.
- Enable per-server diagnostics in Settings with live logs, filters, and export.
- Keep production builds lean; guard verbose logs behind debug flags and a Dev toggle.

### 7.2 Logging Architecture

- __Model__: `McpLogEvent` with fields `{timestamp, serverUrl, level (debug|info|warn|error), category (transport|rpc|service|tool|ui), message, data? (Map), requestId?, sessionId?}`.
- __Buffer__: Per-server ring buffer (default 500–1000 events). Global aggregate for the Dev panel. Oldest events drop.
- __Streams__:
  - `Stream<McpLogEvent>` per server and a global `BroadcastStream` for all.
  - Convenience `ValueNotifier<List<McpLogEvent>>` for UI snapshots.
- __Controller__: `McpLogController` inside `McpService` manages buffers and emits events. Expose via a lightweight interface `McpLogs` with:
  - `listen(serverUrl?)`, `events(serverUrl?)`, `clear(serverUrl?)`, `export(serverUrl?, {range, level, category})`, `lastError(serverUrl)`.
- __Emission points__ (instrumentation):
  - WS/SSE connect/disconnect/retry, heartbeat timeouts, session discovery.
  - `initialize`, `tools/list`, `tools/call` requests/responses, durations, payload sizes (summarized), errors.
  - Schema validation results, argument short-circuit errors.
  - Chat orchestration markers: intercept-tool-call, restart-generation, cancellation.
  - Settings actions: add/edit/remove server, reconnect.
- __Levels & filtering__: Gate debug-level emission with `kDebugMode || settings.devLoggingEnabled`.

### 7.3 Settings: Logging Console (per-server tabs)

- __Placement__: In `lib/Pages/settings_page/subwidgets/mcp_settings.dart`, add a new section “MCP Logs (Developer)” below server configuration.
- __UI Structure__:
  - TabBar with one tab per configured MCP server (by `name`), plus an “All” tab.
  - AppBar row: level filter (All/Info/Warn/Error), category filter chips, search box, actions: Clear, Copy, Export, Pause/Resume live tail.
  - Log list: virtualized `ListView.builder`, monospace lines like `[12:34:56.789] [WARN] [transport] connect retry in 2s — http://localhost:7999`.
  - Expandable row: tap to expand and view structured JSON payloads (pretty-printed) for `data`.
- __Behaviors__:
  - Live tail follows unless paused; resume scroll when unpaused.
  - Persist the last 100 events per server into Hive (optional) to show recent logs after app restart.
  - Show last error badge in the tab label if present via `McpService.getLastError(serverUrl)`.

### 7.4 Main Chat: Dev Observability Panel

- __Placement (Implemented)__:
  - Small screens: right-side end-drawer overlay.
  - Large screens: fixed right-side sibling panel (420px) alongside the chat; toggled via the Chat AppBar bug button and the floating bug FAB. Panel exposes a close button and supports the same filters/live-tail as the drawer.
- __What it shows__:
  - Timeline of recent events across all servers with filters identical to Settings console.
  - Per-turn annotations: when a tool call is intercepted/executed, show an inline marker with requestId linking to the log timeline.
  - Connection status badges for each server (OK / Connecting / Error) with tooltip showing last error.
  - Quick actions: Reconnect servers, toggle verbose logs, copy last error.
- __Implementation__:
  - New widget `DevObservabilityPanel` under `lib/Widgets/dev/` consuming `McpLogs` via Provider.
  - Small status pill component `McpServerStatusBadge` used in Chat AppBar.
  - Link tool-call messages to log entries by `requestId` (set in `ChatProvider` when dispatching MCP calls).

### 7.5 Providers & Wiring

- Provide `McpLogs` from `main.dart` next to `McpService` so both Settings and Chat can subscribe.
- Add a `devLoggingEnabled` flag to settings; reflect it in a simple toggle in Settings.
- On platform Web, ensure logs avoid large payloads; show summarized sizes and allow expand-on-demand.

### 7.6 Minimal API Surface (draft)

 ```
 class McpLogs {
   Stream<McpLogEvent> listen({String? serverUrl});
   List<McpLogEvent> events({String? serverUrl});
   void clear({String? serverUrl});
   Future<String> export({String? serverUrl, DateTimeRange? range, Set<String>? levels, Set<String>? categories});
   McpLastError? lastError(String serverUrl);
 }
 ```

 ### 7.7 Testing Plan

 - Service tests: verify events are emitted on connect, initialize, tools/list, tools/call (success and error), and that ring buffer trims as expected.
 - Widget tests: Settings console shows tabs per server, filters work, live tail updates; Dev panel toggles and displays statuses and timeline markers.
 - Chat provider integration: ensure `requestId` propagation links tool-call messages to log entries.

 ### 7.8 Rollout & Safeguards

 - Feature flag the Dev panel; disabled by default in release builds.
 - Redact secrets from payloads; cap logged payload size and provide expand-to-view.
 - Document known limitations (Web CORS, mixed content) and link to transport compatibility doc.

## 8. MCPJam API Integration Contract (Flutter)
 
 This section defines the concrete contract between Reins and MCPJam `/api/mcp` endpoints with minimal payload examples and SSE event types.
 
 ### 8.1 Connect & Server Management
 
 - POST `/api/mcp/connect`
   - Body:
     ```json
     {
       "serverId": "asana",
       "serverConfig": {
         "name": "asana",
         "url": "https://your-mcp-gateway.example.com/sse",
         "requestInit": { "headers": { "Authorization": "Bearer YOUR_TOKEN" } },
         "eventSourceInit": { "withCredentials": false }
       }
     }
     ```
   - Success: `{ "success": true, "status": "connected" }`
 
 - GET `/api/mcp/servers`
   - Success: `{ "success": true, "servers": [{ "id": "asana", "name": "asana", "status": "connected", "config": { ... } }] }`
 
 - GET `/api/mcp/servers/status/:serverId`
   - Success: `{ "success": true, "serverId": "asana", "status": "connected" }`
 
 - DELETE `/api/mcp/servers/:serverId`
   - Success: `{ "success": true, "message": "Disconnected from server: asana" }`
 
 - POST `/api/mcp/servers/reconnect`
   - Body: `{ "serverId": "asana", "serverConfig": { ... } }`
   - Success: `{ "success": true, "serverId": "asana", "status": "connected" }`
 
 Notes:
 - `serverConfig` accepts HTTP/SSE or CLI transports; validated in `server/utils/mcp-utils.ts`.
 - For web, prefer SSE URL under HTTPS and WSS if using WS.
 
 ### 8.2 Tools API (SSE)
 
 - POST `/api/mcp/tools` with `action: "list"`
   - Body:
     ```json
     {
       "action": "list",
       "serverConfig": { "name": "asana", "url": "https://.../sse" }
     }
     ```
   - SSE events:
     - `{"type":"tools_list","tools":{"search":{"description":"...","inputSchema":{...}}}}`
     - `[DONE]`
 
 - POST `/api/mcp/tools` with `action: "execute"`
   - Body:
     ```json
     {
       "action": "execute",
       "serverConfig": { "name": "asana", "url": "https://.../sse" },
       "toolName": "search",
       "parameters": { "query": "foo" }
     }
     ```
   - SSE events sequence:
     - `{"type":"tool_executing","toolName":"search","parameters":{...}}`
     - Optional elicitation: `{"type":"elicitation_request","requestId":"elicit_...","message":"...","schema":{...}}`
     - Client responds via POST `/api/mcp/tools` with `action:"respond"`:
       ```json
       { "action":"respond", "requestId":"elicit_...", "response": { "action":"accept", "content": {"...": "..."} } }
       ```
     - `{"type":"tool_result","toolName":"search","result":{...}}`
     - `{"type":"elicitation_complete","toolName":"search"}`
     - `[DONE]`
 
 - Errors emit: `{"type":"tool_error","error":"..."}`
 
 ### 8.3 Resources API
 
 - POST `/api/mcp/resources/list`
   - Body: `{ "serverId": "asana" }`
   - Success: `{ "resources": { "asana": [{"uri":"res://...","name":"...","mimeType":"..."}] } }`
 
 - POST `/api/mcp/resources/read`
   - Body: `{ "serverId": "asana", "uri": "res://path" }`
   - Success: `{ "content": { "contents": [ {"type":"text","text":"..."} ] } }`
 
 ### 8.4 Prompts API
 
 - POST `/api/mcp/prompts/list`
   - Body: `{ "serverId": "asana" }`
   - Success: `{ "prompts": { "asana": [{"name":"summarize","description":"...","arguments":{...}}] } }`
 
 - POST `/api/mcp/prompts/get`
   - Body: `{ "serverId":"asana", "name":"summarize", "args": {"doc":"..."} }`
   - Success: `{ "content": { "content": {"role":"system","parts":[...]} } }`
 
 ### 8.5 Chat API (SSE)
 
 - POST `/api/mcp/chat`
   - Body:
     ```json
     {
       "serverConfigs": {
         "asana": { "name": "asana", "url": "https://.../sse" },
         "github": { "name": "github", "url": "https://.../sse" }
       },
       "model": { "id": "gpt-4o-mini", "provider": "openai" },
       "provider": "openai",
       "apiKey": "sk-...",
       "systemPrompt": "You are a helpful assistant.",
       "temperature": 0.2,
       "messages": [
         { "role": "user", "content": "Find recent tasks and summarize." }
       ]
     }
     ```
   - SSE events (order may interleave):
     - Text chunks: `{"type":"text","content":"..."}`
     - Tool calls: `{"type":"tool_call","toolCall":{"id":1,"name":"search","parameters":{...},"status":"executing"}}`
     - Tool results: `{"type":"tool_result","toolResult":{"id":1,"toolCallId":1,"result":{...}}}`
     - Trace steps: `{"type":"trace_step","step":1,"text":"...","toolCalls":[...],"toolResults":[...]}`
     - Elicitation request: `{"type":"elicitation_request","requestId":"elicit_...","message":"...","schema":{...}}`
       - Respond via POST `/api/mcp/chat`:
         ```json
         { "action":"elicitation_response", "requestId":"elicit_...", "response": { "action":"accept", "content": {"...":"..."} } }
         ```
     - Elicitation complete: `{"type":"elicitation_complete"}`
     - End: `[DONE]`
   - Errors emit: `{"type":"error","error":"..."}`
 
 ### 8.6 Flutter Client Notes
 
 - Web: use `dart:html EventSource` for SSE endpoints; ensure HTTPS → WSS and CORS proxy if needed.
 - Mobile/Desktop: use an SSE client that reads lines beginning with `data:` and parse JSON after the prefix.
 - Always handle `[DONE]` to close streams and clear elicitation callbacks.
 - Tool argument schemas are JSON Schema (Zod converted where applicable); validate before calls when possible.
