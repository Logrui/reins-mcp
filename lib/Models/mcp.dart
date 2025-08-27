import 'dart:convert';

// Represents a tool available on an MCP server.
class McpTool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  McpTool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  factory McpTool.fromJson(Map<String, dynamic> json) {
    final desc = (json['description'] ?? '').toString();
    // Accept multiple possible keys per MCP variants/gateways
    final params = (json['parameters'] ?? json['input_schema'] ?? json['inputSchema'] ?? const {})
        as Map?;
    return McpTool(
      name: json['name']?.toString() ?? 'unknown',
      description: desc,
      parameters: params?.cast<String, dynamic>() ?? const {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'parameters': parameters,
    };
  }
}

// Represents a configured MCP server endpoint.
class McpServerConfig {
  final String name; // display name e.g. "local"
  final String endpoint; // ws:// or wss:// URL
  final String? authToken; // optional auth token/header

  McpServerConfig({
    required this.name,
    required this.endpoint,
    this.authToken,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'endpoint': endpoint,
        if (authToken != null) 'authToken': authToken,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final endpoint = json['endpoint'] as String;
    final rawName = json['name'] as String?;
    final name = (rawName == null || rawName.trim().isEmpty)
        ? _deriveNameFromEndpoint(endpoint)
        : rawName;
    return McpServerConfig(
      name: name,
      endpoint: endpoint,
      authToken: json['authToken'],
    );
  }

  static String _deriveNameFromEndpoint(String endpoint) {
    try {
      final uri = Uri.parse(endpoint);
      if (uri.host.isNotEmpty) return uri.host;
    } catch (_) {}
    return endpoint
        .replaceFirst(RegExp(r'^wss?://'), '')
        .split('/')
        .first;
  }
}

// Represents a JSON-RPC 2.0 request.
class McpRequest {
  final String jsonrpc = '2.0';
  final String method;
  final Map<String, dynamic> params;
  final String id;

  McpRequest({
    required this.method,
    required this.params,
    required this.id,
  });

  String toJson() {
    return jsonEncode({
      'jsonrpc': jsonrpc,
      'method': method,
      'params': params,
      'id': id,
    });
  }
}

// Represents a JSON-RPC 2.0 response.
class McpResponse {
  final String jsonrpc = '2.0';
  final dynamic result;
  final McpError? error;
  final String id;

  McpResponse({
    this.result,
    this.error,
    required this.id,
  });

  factory McpResponse.fromJson(Map<String, dynamic> json) {
    return McpResponse(
      result: json['result'],
      error: json['error'] != null ? McpError.fromJson(json['error']) : null,
      id: json['id'],
    );
  }
}

// Represents a JSON-RPC 2.0 error.
class McpError {
  final int code;
  final String message;
  final dynamic data;

  McpError({
    required this.code,
    required this.message,
    this.data,
  });

  factory McpError.fromJson(Map<String, dynamic> json) {
    return McpError(
      code: json['code'],
      message: json['message'],
      data: json['data'],
    );
  }

  @override
  String toString() {
    return 'McpError(code: $code, message: $message, data: $data)';
  }
}

// Represents a tool call request emitted by the LLM via sentinel.
class McpToolCall {
  final String server; // server name or endpoint key
  final String name; // tool name
  final Map<String, dynamic> args; // arguments

  McpToolCall({
    required this.server,
    required this.name,
    required this.args,
  });

  factory McpToolCall.fromJson(Map<String, dynamic> json) => McpToolCall(
        server: json['server'],
        name: json['name'],
        args: (json['args'] as Map).cast<String, dynamic>(),
      );

  Map<String, dynamic> toJson() => {
        'server': server,
        'name': name,
        'args': args,
      };
}

// Represents a tool result that will be injected back into the transcript.
class McpToolResult {
  final dynamic result;
  final String? error;

  McpToolResult({this.result, this.error});

  Map<String, dynamic> toJson() => {
        if (result != null) 'result': result,
        if (error != null) 'error': error,
      };
}
