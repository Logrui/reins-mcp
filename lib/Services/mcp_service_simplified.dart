import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb, debugPrint;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart' as io;
import 'package:http/http.dart' as http;

import 'package:reins/Models/mcp.dart';

enum McpConnectionState { disconnected, connecting, connected, error }

/// Simplified MCP Service supporting only HTTP and WebSocket transports
/// Compatible with Web, iOS, and Windows Desktop platforms
class McpService extends ChangeNotifier {
  final Map<String, MessageChannel> _channels = {};
  final Map<String, McpConnectionState> _states = {};
  final Map<String, List<McpTool>> _serverTools = {};
  final Map<String, Completer<McpResponse>> _pendingRequests = {};
  final Map<String, String> _requestServerById = {};
  final Map<String, String> _lastErrors = {};
  final Uuid _uuid = const Uuid();

  McpConnectionState getState(String serverUrl) => _states[serverUrl] ?? McpConnectionState.disconnected;
  bool isConnected(String serverUrl) => getState(serverUrl) == McpConnectionState.connected;
  String? getLastError(String serverUrl) => _lastErrors[serverUrl];
  List<McpTool> getTools(String serverUrl) => _serverTools[serverUrl] ?? [];
  List<McpTool> get allTools => _serverTools.values.expand((tools) => tools).toList();

  void _setState(String serverUrl, McpConnectionState state) {
    _states[serverUrl] = state;
    notifyListeners();
  }

  /// Connect to MCP server using HTTP or WebSocket transport
  Future<void> connect(String serverUrl, {String? authToken}) async {
    if (isConnected(serverUrl)) return;

    _setState(serverUrl, McpConnectionState.connecting);
    _lastErrors.remove(serverUrl);

    try {
      final uri = Uri.parse(serverUrl);
      MessageChannel channel;

      if (uri.scheme == 'ws' || uri.scheme == 'wss') {
        // WebSocket transport
        channel = await _connectWebSocket(uri, authToken);
      } else if (uri.scheme == 'http' || uri.scheme == 'https') {
        // HTTP transport
        channel = await _connectHttp(uri, authToken);
      } else {
        throw Exception('Unsupported protocol: ${uri.scheme}. Only HTTP and WebSocket are supported.');
      }

      _channels[serverUrl] = channel;

      // Listen for incoming messages
      channel.stream.listen(
        (message) => _handleMessage(serverUrl, message),
        onError: (error) {
          debugPrint('MCP connection error for $serverUrl: $error');
          _lastErrors[serverUrl] = error.toString();
          _setState(serverUrl, McpConnectionState.error);
          disconnect(serverUrl);
        },
        onDone: () {
          debugPrint('MCP connection closed for $serverUrl');
          disconnect(serverUrl);
        },
      );

      // Initialize MCP connection
      final initialized = await _initialize(serverUrl);
      if (!initialized) {
        _setState(serverUrl, McpConnectionState.error);
        disconnect(serverUrl);
        return;
      }

      _setState(serverUrl, McpConnectionState.connected);
      await _listToolsForServer(serverUrl);
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to connect to MCP server at $serverUrl: $e');
      _lastErrors[serverUrl] = e.toString();
      _setState(serverUrl, McpConnectionState.error);
      disconnect(serverUrl);
    }
  }

  /// Connect via WebSocket
  Future<MessageChannel> _connectWebSocket(Uri uri, String? authToken) async {
    final headers = <String, dynamic>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    if (kIsWeb) {
      debugPrint('MCP WebSocket connect (web) -> $uri');
      return WebSocketMessageChannel(WebSocketChannel.connect(uri));
    } else {
      debugPrint('MCP WebSocket connect -> $uri');
      final ws = io.IOWebSocketChannel.connect(
        uri,
        protocols: ['jsonrpc-2.0'],
        headers: headers.isEmpty ? null : headers,
      );
      return WebSocketMessageChannel(ws);
    }
  }

  /// Connect via HTTP
  Future<MessageChannel> _connectHttp(Uri uri, String? authToken) async {
    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    debugPrint('MCP HTTP connect -> $uri');
    final client = http.Client();
    return HttpMessageChannel(client, uri, headers);
  }

  void disconnect(String serverUrl) {
    _channels[serverUrl]?.close();
    _channels.remove(serverUrl);
    _serverTools.remove(serverUrl);
    _setState(serverUrl, McpConnectionState.disconnected);
    
    // Fail pending requests
    final idsToFail = _pendingRequests.keys
        .where((id) => _requestServerById[id] == serverUrl)
        .toList();
    for (final id in idsToFail) {
      final completer = _pendingRequests.remove(id);
      _requestServerById.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(Exception('Disconnected from server'));
      }
    }
    notifyListeners();
  }

  Future<void> disconnectAll() async {
    final urls = _channels.keys.toList();
    for (final url in urls) {
      disconnect(url);
    }
  }

  /// Initialize MCP connection
  Future<bool> _initialize(String serverUrl) async {
    try {
      final response = await _rpc(serverUrl, 'initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {
          'roots': {'listChanged': true},
          'sampling': {},
        },
        'clientInfo': {
          'name': 'Reins',
          'version': '1.0.0',
        },
      }).timeout(const Duration(seconds: 10));

      if (response.error != null) {
        debugPrint('MCP initialize error: ${response.error}');
        _lastErrors[serverUrl] = 'Initialize failed: ${response.error}';
        return false;
      }

      debugPrint('MCP initialized successfully for $serverUrl');
      return true;
    } catch (e) {
      debugPrint('MCP initialize timeout/error for $serverUrl: $e');
      _lastErrors[serverUrl] = 'Initialize failed: $e';
      return false;
    }
  }

  /// List tools from server
  Future<void> _listToolsForServer(String serverUrl) async {
    try {
      final response = await _rpc(serverUrl, 'tools/list', {})
          .timeout(const Duration(seconds: 15));

      if (response.error != null) {
        debugPrint('MCP tools/list error: ${response.error}');
        _lastErrors[serverUrl] = response.error.toString();
        return;
      }

      final result = response.result;
      final List<McpTool> tools = [];

      if (result is Map && result['tools'] is List) {
        final toolsList = result['tools'] as List;
        for (final toolJson in toolsList) {
          if (toolJson is Map<String, dynamic>) {
            tools.add(McpTool.fromJson(toolJson));
          }
        }
      }

      _serverTools[serverUrl] = tools;
      debugPrint('MCP loaded ${tools.length} tools from $serverUrl');
    } catch (e) {
      debugPrint('MCP tools/list failed for $serverUrl: $e');
      _lastErrors[serverUrl] = 'Failed to list tools: $e';
    }
  }

  /// Send JSON-RPC request
  Future<McpResponse> _rpc(String serverUrl, String method, Map<String, dynamic> params) async {
    final channel = _channels[serverUrl];
    if (channel == null) {
      throw Exception('Not connected to server: $serverUrl');
    }

    final id = _uuid.v4();
    final request = McpRequest(
      id: id,
      method: method,
      params: params,
    );

    final completer = Completer<McpResponse>();
    _pendingRequests[id] = completer;
    _requestServerById[id] = serverUrl;

    debugPrint('MCP -> $method id=$id');
    channel.sink.add(request.toJson());

    return completer.future;
  }

  /// Handle incoming messages
  void _handleMessage(String serverUrl, dynamic message) {
    try {
      final Map<String, dynamic> json;
      if (message is String) {
        json = jsonDecode(message);
      } else if (message is Map<String, dynamic>) {
        json = message;
      } else {
        debugPrint('MCP received unexpected message type: ${message.runtimeType}');
        return;
      }

      final id = json['id']?.toString();
      if (id != null && _pendingRequests.containsKey(id)) {
        // Response to our request
        final completer = _pendingRequests.remove(id);
        _requestServerById.remove(id);
        
        if (completer != null && !completer.isCompleted) {
          final response = McpResponse.fromJson(json);
          completer.complete(response);
        }
      } else {
        // Notification or other message
        debugPrint('MCP notification: ${json['method']}');
      }
    } catch (e) {
      debugPrint('Failed to handle MCP message: $e');
    }
  }

  /// Call a tool
  Future<McpToolResult> call(String serverUrl, String toolName, Map<String, dynamic> arguments, {Duration? timeout}) async {
    try {
      final response = await _rpc(serverUrl, 'tools/call', {
        'name': toolName,
        'arguments': arguments,
      }).timeout(timeout ?? const Duration(seconds: 30));

      if (response.error != null) {
        return McpToolResult(
          result: null,
          error: response.error.toString(),
        );
      }

      return McpToolResult(
        result: response.result,
        error: null,
      );
    } catch (e) {
      return McpToolResult(
        result: null,
        error: e.toString(),
      );
    }
  }

  /// List all tools from all connected servers
  Future<List<McpTool>> listTools({String? server}) async {
    if (server != null) {
      return getTools(server);
    }
    return allTools;
  }
}

/// Abstract message channel interface
abstract class MessageChannel {
  Stream<dynamic> get stream;
  MessageSink get sink;
  Future<void> close();
}

/// Abstract message sink interface
abstract class MessageSink {
  void add(dynamic data);
  Future<void> close();
}

/// WebSocket message channel implementation
class WebSocketMessageChannel implements MessageChannel {
  final WebSocketChannel _channel;

  WebSocketMessageChannel(this._channel);

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  MessageSink get sink => WebSocketMessageSink(_channel.sink);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}

class WebSocketMessageSink implements MessageSink {
  final WebSocketSink _sink;

  WebSocketMessageSink(this._sink);

  @override
  void add(dynamic data) {
    _sink.add(jsonEncode(data));
  }

  @override
  Future<void> close() async {
    await _sink.close();
  }
}

/// HTTP message channel implementation
class HttpMessageChannel implements MessageChannel {
  final http.Client _client;
  final StreamController<dynamic> _controller = StreamController.broadcast();
  final HttpMessageSink _sink;

  HttpMessageChannel(this._client, Uri uri, Map<String, String> headers)
      : _sink = HttpMessageSink(_client, uri, headers);

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  MessageSink get sink => _sink;

  @override
  Future<void> close() async {
    await _controller.close();
    _client.close();
  }
}

class HttpMessageSink implements MessageSink {
  final http.Client _client;
  final Uri _uri;
  final Map<String, String> _headers;

  HttpMessageSink(this._client, this._uri, this._headers);

  @override
  void add(dynamic data) {
    _sendMessage(data);
  }

  void _sendMessage(dynamic data) async {
    try {
      final message = jsonEncode(data);
      final response = await _client.post(
        _uri,
        headers: {
          'Content-Type': 'application/json',
          ..._headers,
        },
        body: message,
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('MCP HTTP send failed: ${response.statusCode} ${response.reasonPhrase}');
      }
    } catch (e) {
      debugPrint('MCP HTTP send error: $e');
    }
  }

  @override
  Future<void> close() async {
    // HTTP client will be closed by the channel
  }
}
