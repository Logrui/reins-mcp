# Tome Tool Integration Analysis and Recommendations for Reins

This document analyzes the tool usage implementation in the `.tome` reference application and provides a comparative analysis with the current capabilities of Reins. It concludes with a set of recommendations for enhancing Reins to support a more robust and user-friendly tool integration.

## 1. Tome: Deep Dive into Tool Integration

`.tome` is a SvelteKit and Tauri-based application that demonstrates a sophisticated, structured approach to LLM tool calling.

### Core Architecture

- **Framework**: SvelteKit (TypeScript) for the frontend, with Rust (via Tauri) for backend operations.
- **Communication**: The frontend `invoke`s Rust functions for all heavy lifting, including making HTTP requests (`fetch`) and calling MCP tools (`call_mcp_tool`).
- **State Management**: Reactive Svelte stores manage UI state, while a `Session` model holds chat history and configuration.

### Key Files for Tool Logic

- **`src/lib/dispatch.ts`**: The central orchestrator for chat interactions.
- **`src/components/Message.svelte`**: A router component that selects the correct view based on message role and content.
- **`src/components/Messages/Tool.svelte`**: A dedicated component for rendering the LLM's "thinking" process and tool results.
- **`src/lib/mcp.ts`**: Handles fetching and transforming tools from MCP servers.

### Tool Call Workflow

`.tome`'s workflow is event-driven and relies on structured data from the LLM, not string parsing.

1.  **Dispatch**: The `dispatch` function in `dispatch.ts` sends the current message history and available tools to the LLM engine.
2.  **Structured Response**: It expects the LLM to respond with a message object that contains a `toolCalls` array if it decides to use a tool. This is a standard feature of APIs like OpenAI's.
3.  **Tool Call Interception**: If `message.toolCalls` is present, the `dispatch` function intercepts the flow.
4.  **Add "Thinking" Message**: For each tool call, it adds a new `assistant` message to the chat history. This message has an **empty `content` string** but contains the `toolCalls` data. This is the key to rendering the `Tool.svelte` component.
5.  **Execute Tool**: It `invoke`s the backend `call_mcp_tool` function with the tool name and arguments.
6.  **Add Tool Result Message**: It adds a `tool` message to the history, containing the JSON result from the tool execution.
7.  **Recursive Dispatch**: It calls `dispatch` again, sending the updated history (including the tool result) back to the LLM. The LLM then uses this result to formulate its final text response.

### UI Implementation

`.tome` provides a superior user experience by visualizing the tool call process.

- **`Message.svelte`** acts as a router. Its logic is simple:
  ```svelte
  {:else if message.role == 'assistant' && message.content === '' && message.toolCalls.length}
      <Tool {message} />
  ```
- **`Tool.svelte`** renders a collapsible UI that shows:
  - The name of the tool being called (`call.function.name`).
  - A summary of the arguments.
  - When expanded, it shows the full arguments and the complete JSON response from the tool.

This makes it clear to the user that the model is performing an action.

## 2. Comparison with Reins

| Feature | Tome | Reins |
| :--- | :--- | :--- |
| **Tool Protocol** | Structured `tool_calls` object from LLM | Custom string sentinel (`TOOL_CALL:`) |
| **Reliability** | High (based on a standard API contract) | Low (brittle, depends on LLM formatting) |
| **UI for "Thinking"** | Yes (dedicated `Tool.svelte` component) | No (goes directly from prompt to result) |
| **Data Model** | `Message` object with `toolCalls` list | `OllamaMessage` with string `content` |
| **Execution Flow** | Recursive, adds separate thinking/result messages | Stream interruption, injects single result message |

### Gaps in Reins' Current Implementation

1.  **No Visualization of Tool Usage**: Reins currently jumps from a user's prompt to a `TOOL_RESULT:` message. The user has no visibility into *what* tool was called or *why*.
2.  **Brittle Sentinel-Based Protocol**: The `TOOL_CALL:` prefix is unreliable and requires the LLM to be perfectly prompted. It's not a scalable or standard approach.
3.  **Inflexible Data Model**: Storing everything in a string `content` field forces parsing at the UI layer and prevents the clean separation of concerns seen in `.tome`.

## 3. Recommendations for Reins

### Short-Term: Improve the Existing System

These changes can be implemented without a full protocol rewrite.

1.  **Implement a "Thinking" UI**:
    -   In `ChatProvider._executeToolCall`, instead of just adding one `TOOL_RESULT` message, add **two** messages:
        1.  An `OllamaMessage` with the role `assistant` and content that represents the tool call (e.g., `Thinking: Using tool 'echo' with arguments...`). You can format this nicely.
        2.  The existing `OllamaMessage` with the `TOOL_RESULT:` prefix.
    -   Create a new widget in Flutter (`ToolCallMessage.dart`) that specifically parses and displays the "Thinking" message, perhaps with an icon and a summary of the call.
    -   Update your `ListView` builder in the chat page to use this new widget for such messages.

2.  **Enhance the Data Model**:
    -   Modify the `OllamaMessage` class in `lib/Models/ollama_chat.dart` to include optional `McpToolCall` and `McpToolResult` fields.
    -   When parsing the `TOOL_CALL:` sentinel in `ChatProvider`, populate an `McpToolCall` object on the message instead of just using the raw string. This moves parsing logic out of the UI.

### Long-Term: Adopt a Structured Protocol

For a truly robust solution, Reins should move away from the string sentinel and adopt a structured format similar to Tome.

1.  **Standardize on a Tool Call Format**:
    -   Update your system prompts and/or `OllamaService` to instruct the Ollama model to output JSON that matches OpenAI's tool calling format (a `tool_calls` array in the response).
    -   This may require using a model fine-tuned for function calling.

2.  **Refactor `ChatProvider`**:
    -   Remove the stream-interruption logic based on the `TOOL_CALL:` prefix.
    -   Instead, after the stream completes, check if the final `OllamaMessage` object contains the `tool_calls` data.
    -   If it does, implement the recursive logic from `.tome`'s `dispatch.ts`:
        -   Execute the tool call via `McpService`.
        -   Add the "thinking" and "tool result" messages.
        -   Call the chat stream method again with the updated history.

By adopting these changes, Reins can achieve a tool integration that is not only more reliable but also provides a much richer and more transparent user experience.
