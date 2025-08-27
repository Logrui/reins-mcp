# MCP Transport Platform Compatibility Guide

This document outlines which MCP transport methods work with different platform modalities and application types.

## Transport Methods Overview

| Transport | Description | Protocol | Connection Type |
|-----------|-------------|----------|-----------------|
| `stdio` | Standard input/output | JSON-RPC | Process pipes |
| `streaming` | Custom streaming protocol | JSON-RPC | TCP socket |
| `sse` | Server-Sent Events | HTTP/SSE | HTTP stream |
| `http` | Standard HTTP | JSON-RPC | HTTP request/response |
| `websocket` | WebSocket protocol | JSON-RPC | WebSocket connection |

## Platform Compatibility Matrix

### Windows Desktop Applications

**✅ Fully Supported:**
- **`stdio`** - Direct process spawning and pipe communication
- **`streaming`** - TCP socket connections via WinSock
- **`http`** - HTTP client libraries (HttpClient, WinHTTP)
- **`websocket`** - WebSocket client libraries

**⚠️ With Proxy:**
- **`sse`** - Via HTTP client with EventSource-like implementation

**Examples:**
- .NET applications: All transports supported
- Electron apps: All transports via Node.js APIs
- Native C++ apps: stdio, streaming, http, websocket

### Mac Desktop Applications

**✅ Fully Supported:**
- **`stdio`** - POSIX process spawning and pipes
- **`streaming`** - BSD socket connections
- **`http`** - URLSession, libcurl, or HTTP frameworks
- **`websocket`** - Native WebSocket libraries

**⚠️ With Proxy:**
- **`sse`** - Via HTTP client with custom SSE parsing

**Examples:**
- Swift/Objective-C apps: All transports supported
- Electron apps: All transports via Node.js APIs
- Native C++ apps: stdio, streaming, http, websocket

### Web Browser Applications

**✅ Fully Supported:**
- **`sse`** - Native EventSource API
- **`websocket`** - Native WebSocket API

**❌ Not Supported:**
- **`stdio`** - Browsers cannot spawn processes
- **`streaming`** - No direct TCP socket access
- **`http`** - Limited by CORS and same-origin policy

**⚠️ Requires Proxy:**
- All MCP servers must be accessed through a proxy that converts:
  - MCP protocols → Browser-compatible protocols (SSE/WebSocket)
  - Handles CORS and authentication

**Examples:**
- React/Vue/Angular apps: SSE + WebSocket only
- Browser extensions: SSE + WebSocket only
- Progressive Web Apps: SSE + WebSocket only

### iOS Applications

**✅ Fully Supported:**
- **`http`** - URLSession with JSON-RPC
- **`websocket`** - URLSessionWebSocketTask or third-party libraries

**⚠️ Limited Support:**
- **`sse`** - Manual implementation using URLSession streaming
- **`streaming`** - TCP sockets via Network.framework (iOS 12+)

**❌ Not Supported:**
- **`stdio`** - iOS sandboxing prevents process spawning

**App Store Considerations:**
- Network usage must be declared in Info.plist
- Background processing limitations may affect persistent connections

**Examples:**
- Native iOS apps: http, websocket, custom streaming
- React Native: http, websocket via JavaScript bridge
- Flutter: http, websocket via platform channels

### Android Applications

**✅ Fully Supported:**
- **`http`** - OkHttp, Retrofit, or HttpURLConnection
- **`websocket`** - OkHttp WebSocket or Java-WebSocket

**⚠️ Limited Support:**
- **`sse`** - Manual implementation using HTTP streaming
- **`streaming`** - Raw TCP sockets via java.net.Socket

**❌ Not Supported:**
- **`stdio`** - Android security model prevents process spawning

**Permissions Required:**
- `INTERNET` permission for network access
- `NETWORK_STATE` for connection monitoring

**Examples:**
- Native Android apps: http, websocket, custom streaming
- React Native: http, websocket via JavaScript bridge
- Flutter: http, websocket via platform channels
- Xamarin: http, websocket via .NET libraries

## Recommended Transport by Platform

### Desktop Applications (Windows/Mac)
**Primary:** `stdio` - Most direct and efficient
**Secondary:** `streaming` - For high-performance scenarios
**Fallback:** `http` - For simple request/response patterns

### Web Applications
**Primary:** `sse` - Best for real-time streaming
**Secondary:** `websocket` - For bidirectional communication
**Required:** Proxy server for MCP protocol translation

### Mobile Applications (iOS/Android)
**Primary:** `websocket` - Best mobile network handling
**Secondary:** `http` - For simple operations
**Considerations:** Handle network interruptions and background states

## Implementation Examples

### Windows Desktop (.NET)
```csharp
// stdio transport
var process = new Process {
    StartInfo = new ProcessStartInfo {
        FileName = "mcp-server.exe",
        RedirectStandardInput = true,
        RedirectStandardOutput = true,
        UseShellExecute = false
    }
};
```

### Web Browser (JavaScript)
```javascript
// SSE transport via proxy
const eventSource = new EventSource('http://localhost:3006/sse');
eventSource.onmessage = (event) => {
    const mcpMessage = JSON.parse(event.data);
    // Handle MCP message
};
```

### iOS (Swift)
```swift
// WebSocket transport
let webSocketTask = URLSession.shared.webSocketTask(
    with: URL(string: "ws://localhost:8080")!
)
webSocketTask.resume()
```

### Android (Kotlin)
```kotlin
// HTTP transport
val client = OkHttpClient()
val request = Request.Builder()
    .url("http://localhost:8080/mcp")
    .post(jsonBody)
    .build()
```

## Security Considerations

### Desktop Applications
- `stdio`: Secure within process boundaries
- `streaming`: Requires proper authentication
- `http`: Standard HTTPS/TLS encryption

### Web Applications
- Must use HTTPS in production
- Proxy handles authentication and CORS
- Content Security Policy restrictions apply

### Mobile Applications
- Network Security Config (Android) / App Transport Security (iOS)
- Certificate pinning recommended
- Handle network permission requests

---

*Last Updated: 2025-08-27*
*Covers MCP transport compatibility across major platforms*
