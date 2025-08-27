# Feasibility Analysis — Claude

This document captures a critical analysis of the plan to add MCP client functionality to the Flutter app (Reins) and evaluates viability across MVP and Production phases.

## Executive Summary

- The plan is technically sound and staged appropriately. MVP is achievable with low-to-moderate risk using a text-sentinel tool protocol and a dedicated `McpService` over WebSocket.
- Biggest risks center on stream interruption/resumption in `ChatProvider`, LLM adherence to the `TOOL_CALL:` format, and platform nuances (Web CORS/mixed content, mobile permissions). These are manageable with the mitigations outlined below.
- Production-level polish (structured tool roles, stdio transport, authentication, schema/validation, observability) is feasible but will require platform-specific handling and additional engineering time.

## Context: Current App Architecture

- Core entry: `lib/main.dart`
- Chat orchestration: `lib/Providers/chat_provider.dart`
- Model/API integration: `lib/Services/ollama_service.dart` (HTTP/streaming)
- Persistence: `lib/Services/database_service.dart` (Hive/SQLite)
- Message model: `lib/Models/ollama_message.dart`

The current design uses Provider for state and already streams tokens from an Ollama server. This is a good fit for intercepting tool calls mid-stream.

## High-Level Design Review

- Add `McpService` (WebSocket + JSON-RPC 2.0) to connect/list/call tools from MCP servers.
- Use a text-sentinel protocol with the LLM:
  - Model emits: `TOOL_CALL: {"server":"<srv>","name":"<tool>","args":{...}}`
  - App replies: `TOOL_RESULT: {"name":"<tool>","result":<any>}`
- Inject a tool-aware appendix into the system prompt so the model knows available tools and how to request them.
- Intercept `TOOL_CALL:` lines during the streaming loop, execute MCP call, inject `TOOL_RESULT:`, and resume generation.

Feasibility: High. This approach avoids changes to Ollama’s API and leverages plain-text parsing, which is compatible with current streaming.

## MVP Stages — Feasibility and Risks

- Stage 0 — Scaffolding
  - Feasibility: High. Pure Dart files (`mcp_service.dart`, `mcp.dart`, `tool_call_parser.dart`, `tool_system_prompt.dart`) and dependency add (`web_socket_channel`).

- Stage 1 — MCP Service (WebSocket)
  - Feasibility: High. `web_socket_channel` is cross-platform. Implement JSON-RPC id routing, minimal methods (`initialize`, `tools/list`, `tools/call`).
  - Risks: Web requires `wss://` under HTTPS; handle TLS and certs. Add reconnect/backoff to improve reliability.

- Stage 2 — Prompt Protocol & Parser
  - Feasibility: High. Straightforward string/JSON handling. Provide strict examples in prompt appendix.
  - Risks: LLM adherence to exact format. Mitigate with clear instructions, examples, and tolerant parser (whitespace, line buffering, partial JSON).

- Stage 3 — ChatProvider Integration
  - Feasibility: Medium-High. Core complexity lies in pausing the token stream, executing tool, and resuming without duplicate tokens or lost context.
  - Recommendations: Guard flags to prevent concurrent restarts; explicit state transitions (requesting → executing tool → injecting result → resuming); restart the stream with updated transcript.

- Stage 4 — Settings Wiring (MVP minimal)
  - Feasibility: High for manual entry of servers; Medium for auto-discovery.
  - Recommendation: Defer auto-discovery to Production. Start with manual endpoints stored in Hive (`settings['mcpServers']`).

- Stage 5 — Tests (MVP)
  - Feasibility: High. Unit tests for parser; mock WebSocket for `McpService`; provider test simulating a streamed `TOOL_CALL:` and verifying `TOOL_RESULT:` injection + resume.

## Production Enhancements — Notes

- UI/UX Polish: Distinct tool cards, monospace blocks, inline spinner, cancel. Feasible and valuable for UX clarity.
- Roles & Structure: Add `tool` role to `OllamaMessage` and support in DB and renderer. Medium complexity due to migration/back-compat.
- Transport & Auth: Add stdio (desktop-first), per-server auth, OAuth flows, secure storage. Platform-specific work; schedule accordingly.
- Schema & Validation: Validate args against JSON Schema; optional UI form-building and confirmation flows.
- Observability: Structured logs; diagnostics panel; status overlay per server/tool (latency, last error).
- Reliability: Retries/backoff, timeouts, budgets, circuit breakers.
- Testing & QA: Cross-transport integration tests; snapshot/perf tests for large tool outputs.

## Risks and Mitigations

- LLM does not produce valid `TOOL_CALL:` JSON.
  - Mitigate with strong prompt appendix, explicit examples, and tolerant parsing.
- WebSocket variability across platforms (Web CORS/mixed content; mobile network perms; self-signed certs in dev).
  - Mitigate with `wss://` under HTTPS, platform permissions, and dev cert guidance.
- Stream interruption/resumption bugs leading to duplicate or truncated output.
  - Mitigate with guard flags, state machine in `ChatProvider`, and thorough provider tests.
- Stdio/Process spawning (Production)
  - Desktop-only initially; design with feature flags; fall back to WebSocket servers on mobile/web.

## Recommendations and Next Steps

1. Prototype the stream pause/resume path in `ChatProvider` before full integration to validate UX and correctness.
2. Defer auto-discovery from MVP to Production to keep scope tight.
3. Invest time in the system prompt appendix and examples to maximize LLM adherence and reduce parser error handling.
4. Add structured logging around the tool lifecycle early to speed up debugging during MVP.

## Viability Verdict

- MVP: Medium-High likelihood of success with manageable risks.
- Production: Achievable with additional platform-specific engineering for transports, auth, and reliability.
