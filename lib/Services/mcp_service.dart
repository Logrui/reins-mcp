import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart' as io;
import 'package:http/http.dart' as http;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;

import 'package:reins/Models/mcp.dart';
import 'package:reins/Services/http_sse_channel.dart';
import 'package:reins/Utils/json_schema_validator.dart';

enum McpConnectionState { disconnected, connecting, connected, error }

/// Log levels for developer observability
enum McpLogLevel { debug, info, warn, error }

/// Structured log event for MCP activity
class McpLogEvent {
  final DateTime timestamp;
  final String? serverUrl;
  final McpLogLevel level;
  final String category; // e.g., 'connect','rpc','tools','sse','chat'
  final String message;
  final Map<String, dynamic>? data;
  final String? requestId;
  final String? sessionId;

  McpLogEvent({
    DateTime? timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.serverUrl,
    this.data,
    this.requestId,
    this.sessionId,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Public logging interface exposed by McpService
abstract class McpLogs {
  Stream<McpLogEvent> stream();
  List<McpLogEvent> recent({String? serverUrl});
  void clear({String? serverUrl});
  bool get devLoggingEnabled;
  void enableDevLogging(bool enabled);
}

/// In-memory log controller with per-server ring buffers and a broadcast stream
class _McpLogController implements McpLogs {
  final _controller = StreamController<McpLogEvent>.broadcast();
  final Map<String, List<McpLogEvent>> _byServer = {};
  final List<McpLogEvent> _global = [];
  final int _capacity;
  bool _devEnabled;

  _McpLogController({int capacity = 1000, bool devEnabled = kDebugMode})
      : _capacity = capacity,
        _devEnabled = devEnabled;

  void add(McpLogEvent e) {
    // Gate verbose logs when dev disabled
    if (!_devEnabled && e.level == McpLogLevel.debug) return;
    // Store globally
    _push(_global, e);
    // Store per server (null -> use 'global' bucket)
    final key = e.serverUrl ?? '_global';
    _push(_byServer.putIfAbsent(key, () => <McpLogEvent>[]), e);
    // Broadcast
    if (!_controller.isClosed) {
      _controller.add(e);
    }
  }

  void _push(List<McpLogEvent> buf, McpLogEvent e) {
    buf.add(e);
    final overflow = buf.length - _capacity;
    if (overflow > 0) {
      buf.removeRange(0, overflow);
    }
  }

  @override
  Stream<McpLogEvent> stream() => _controller.stream;

  @override
  List<McpLogEvent> recent({String? serverUrl}) {
    if (serverUrl == null) return List.unmodifiable(_global);
    return List.unmodifiable(_byServer[serverUrl] ?? const <McpLogEvent>[]);
  }

  @override
  void clear({String? serverUrl}) {
    if (serverUrl == null) {
      _global.clear();
      _byServer.clear();
      return;
    }
    _byServer.remove(serverUrl);
  }

  @override
  bool get devLoggingEnabled => _devEnabled;

  @override
  void enableDevLogging(bool enabled) {
    _devEnabled = enabled;
  }
}

/// Lightweight MessageChannel wrapper around HttpSseStreamChannel for lifecycle management
class HttpPeerChannel implements MessageChannel {
  final HttpSseStreamChannel _sse;
  HttpPeerChannel(this._sse);

  @override
  Stream<dynamic> get stream => _sse.stream;

  @override
  MessageSink get sink => _HttpPeerSink(_sse);

  @override
  Future<void> close() async {
    await _sse.dispose();
  }
}

class _HttpPeerSink implements MessageSink {
  final HttpSseStreamChannel _sse;
  _HttpPeerSink(this._sse);

  @override
  void add(dynamic data) {
    // Not used when routing via Peer; keep as a fallback.
    final String payload = data is String ? data : jsonEncode(data);
    _sse.sink.add(payload);
  }

  @override
  Future<void> close() async {
    // sink lifecycle handled by channel dispose
  }
}

/// Simplified MCP Service supporting only HTTP and WebSocket transports
/// Compatible with Web, iOS, and Windows Desktop platforms
class McpService extends ChangeNotifier {
  final Map<String, MessageChannel> _channels = {};
  final Map<String, McpConnectionState> _states = {};
  final Map<String, List<McpTool>> _serverTools = {};
  final Map<String, Completer<McpResponse>> _pendingRequests = {};
  final Map<String, String> _requestServerById = {};
  final Map<String, String> _lastErrors = {};
  final Map<String, rpc.Peer> _wsPeers = {};
  final Uuid _uuid = const Uuid();
  final StreamController<Map<String, McpConnectionState>> _stateController = StreamController.broadcast();
  // Heartbeat and reconnect state
  final Map<String, Timer> _heartbeatTimers = {};
  final Map<String, int> _wsRetryCounts = {};
  final Map<String, Uri> _endpointByServer = {};
  final Map<String, String?> _authByServer = {};

  // --- Dev Observability Logs ---
  final _McpLogController _logs = _McpLogController();

  McpLogs get logs => _logs;

  // Emit a structured developer log event
  void logDev({
    required McpLogLevel level,
    String? serverUrl,
    required String category,
    required String message,
    Map<String, dynamic>? data,
    String? requestId,
    String? sessionId,
  }) {
    try {
      _logs.add(McpLogEvent(
        level: level,
        serverUrl: serverUrl,
        category: category,
        message: message,
        data: data,
        requestId: requestId,
        sessionId: sessionId,
      ));
    } catch (_) {
      // Swallow logging errors; never break runtime due to logging
    }
  }

  // --- Heartbeat & Reconnect ---
  void _startHeartbeat(String serverUrl, {Duration period = const Duration(seconds: 30)}) {
    // Heartbeat only applies to WebSocket transports. HTTP/SSE uses server-initiated
    // events and does not support $/ping in many gateways.
    final uri = _endpointByServer[serverUrl];
    if (uri == null || !(uri.scheme == 'ws' || uri.scheme == 'wss')) {
      return;
    }
    _heartbeatTimers[serverUrl]?.cancel();
    _heartbeatTimers[serverUrl] = Timer.periodic(period, (_) async {
      await _heartbeat(serverUrl);
    });
  }

  Future<void> _heartbeat(String serverUrl) async {
    // Only WS needs explicit heartbeat; HTTP/SSE path uses persistent SSE
    final uri = _endpointByServer[serverUrl];
    if (uri == null || !(uri.scheme == 'ws' || uri.scheme == 'wss')) return;
    final peer = _wsPeers[serverUrl];
    if (peer == null) return;
    try {
      // Use a benign ping; if method unsupported, it's still a live connection
      await peer.sendRequest(r'$/ping', {}).timeout(const Duration(seconds: 10));
      // success: reset retry counter
      _wsRetryCounts[serverUrl] = 0;
      logDev(level: McpLogLevel.debug, serverUrl: serverUrl, category: 'heartbeat', message: 'Ping ok');
    } on TimeoutException {
      if (kDebugMode) debugPrint('MCP heartbeat timeout for $serverUrl');
      logDev(level: McpLogLevel.warn, serverUrl: serverUrl, category: 'heartbeat', message: 'Ping timeout');
      _scheduleWsReconnect(serverUrl);
    } on rpc.RpcException catch (e) {
      if (e.code == -32601) {
        // Method not found -> treat as alive
        _wsRetryCounts[serverUrl] = 0;
      } else {
        logDev(level: McpLogLevel.warn, serverUrl: serverUrl, category: 'heartbeat', message: 'Ping rpc error', data: {'code': e.code, 'message': e.message});
        _scheduleWsReconnect(serverUrl);
      }
    } catch (e) {
      logDev(level: McpLogLevel.warn, serverUrl: serverUrl, category: 'heartbeat', message: 'Ping error', data: {'error': e.toString()});
      _scheduleWsReconnect(serverUrl);
    }
  }

  void _scheduleWsReconnect(String serverUrl) {
    final uri = _endpointByServer[serverUrl];
    if (uri == null) return;
    if (!(['ws', 'wss'].contains(uri.scheme))) return;
    // Avoid duplicate reconnect floods
    if (_states[serverUrl] == McpConnectionState.connecting) return;
    _setState(serverUrl, McpConnectionState.connecting);
    final attempt = (_wsRetryCounts[serverUrl] ?? 0).clamp(0, 5);
    final delay = Duration(seconds: [1, 2, 4, 8, 16, 32][attempt]);
    _wsRetryCounts[serverUrl] = attempt + 1;
    if (kDebugMode) debugPrint('MCP WS reconnect to $serverUrl in ${delay.inSeconds}s');
    logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'reconnect', message: 'Scheduling WS reconnect', data: {'attempt': attempt + 1, 'delaySec': delay.inSeconds});
    Timer(delay, () async {
      try {
        // tear down old channel if any
        await _channels[serverUrl]?.close();
        final channel = await _connectWebSocket(uri, _authByServer[serverUrl]);
        _channels[serverUrl] = channel;
        if (channel is WebSocketMessageChannel) {
          final ws = channel.channel;
          final peer = rpc.Peer(ws.cast<String>());
          _wsPeers[serverUrl] = peer;
          peer.listen();
          peer.done.whenComplete(() {
            if (_channels[serverUrl] is WebSocketMessageChannel) {
              logDev(level: McpLogLevel.warn, serverUrl: serverUrl, category: 'reconnect', message: 'Peer closed, scheduling reconnect');
              _scheduleWsReconnect(serverUrl);
            }
          });
        }
        final ok = await _initialize(serverUrl);
        if (!ok) throw Exception('Initialize failed after reconnect');
        _setState(serverUrl, McpConnectionState.connected);
        _wsRetryCounts[serverUrl] = 0;
        _startHeartbeat(serverUrl);
        await _listToolsForServer(serverUrl);
        logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'reconnect', message: 'Reconnected successfully');
      } catch (e) {
        if (kDebugMode) debugPrint('MCP WS reconnect failed for $serverUrl: $e');
        logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'reconnect', message: 'Reconnect failed', data: {'error': e.toString()});
        _scheduleWsReconnect(serverUrl);
      }
    });
  }

  McpConnectionState getState(String serverUrl) => _states[serverUrl] ?? McpConnectionState.disconnected;
  bool isConnected(String serverUrl) => getState(serverUrl) == McpConnectionState.connected;
  String? getLastError(String serverUrl) => _lastErrors[serverUrl];
  List<McpTool> getTools(String serverUrl) => _serverTools[serverUrl] ?? [];
  List<McpTool> get allTools => _serverTools.values.expand((tools) => tools).toList();

  /// Lookup a tool by fully-qualified name (e.g., "server.tool") or by name within a specific server.
  McpTool? findTool({String? serverUrl, required String toolName}) {
    if (serverUrl != null) {
      final tools = _serverTools[serverUrl] ?? const <McpTool>[];
      return tools.firstWhere(
        (t) => t.name == toolName,
        orElse: () => tools.firstWhere(
          (t) => t.name.endsWith('.$toolName'),
          orElse: () => McpTool(name: '', description: '', parameters: const {}),
        ),
      ).name.isEmpty
          ? null
          : tools.firstWhere((t) => t.name == toolName || t.name.endsWith('.$toolName'));
    }
    final all = allTools;
    try {
      return all.firstWhere((t) => t.name == toolName || t.name.endsWith('.$toolName'));
    } catch (_) {
      return null;
    }
  }

  /// Validate tool arguments against the tool's JSON Schema (if provided).
  /// Returns a list of human-readable validation errors; empty means valid.
  List<String> validateToolArguments(String serverUrl, String toolName, Map<String, dynamic> arguments) {
    final tool = findTool(serverUrl: serverUrl, toolName: toolName);
    if (tool == null) return ['Unknown tool: $toolName'];
    final schema = tool.parameters;
    if (schema.isEmpty) return const <String>[]; // no schema -> accept
    // Some gateways wrap schema under { type: 'object', properties: {...} }
    Map<String, dynamic> effectiveSchema;
    if (schema.containsKey('type')) {
      effectiveSchema = schema;
    } else if (schema.containsKey('properties') || schema.containsKey('required')) {
      effectiveSchema = {
        'type': 'object',
        ...schema,
      };
    } else {
      // Unknown shape, accept to avoid false negatives
      return const <String>[];
    }

    final validator = JsonSchemaValidator();
    return validator.validate(effectiveSchema, arguments, path: 'args');
  }

  void _setState(String serverUrl, McpConnectionState state) {
    _states[serverUrl] = state;
    _stateController.add(Map.from(_states));
    notifyListeners();
  }

  /// Stream of connection state changes for UI updates
  Stream<Map<String, McpConnectionState>> connectionStates() => _stateController.stream;

  /// Connect to multiple MCP servers
  Future<void> connectAll(List<McpServerConfig> servers) async {
    for (final server in servers) {
      await connect(server.endpoint, authToken: server.authToken);
    }
  }

  /// Test-only: attach an in-memory Peer and initialize/list tools without real network.
  ///
  /// This allows unit tests to simulate an MCP server using a json_rpc_2.Server
  /// paired to [peer] via an in-memory StreamChannel.
  @visibleForTesting
  Future<void> attachPeerAndInitialize(String serverUrl, rpc.Peer peer) async {
    // attach a dummy channel to satisfy _rpc()'s channel presence check
    _channels[serverUrl] = DummyMessageChannel();
    _wsPeers[serverUrl] = peer;
    peer.listen();
    _setState(serverUrl, McpConnectionState.connecting);
    final ok = await _initialize(serverUrl);
    if (!ok) {
      _setState(serverUrl, McpConnectionState.error);
      return;
    }
    await _listToolsForServer(serverUrl);
    _setState(serverUrl, McpConnectionState.connected);
  }

  /// Connect to MCP server using HTTP or WebSocket transport
  Future<void> connect(String serverUrl, {String? authToken}) async {
    if (isConnected(serverUrl)) return;

    _setState(serverUrl, McpConnectionState.connecting);
    _lastErrors.remove(serverUrl);
    // keep endpoint and auth for reconnects
    try {
      _endpointByServer[serverUrl] = Uri.parse(serverUrl);
      _authByServer[serverUrl] = authToken;
    } catch (_) {}

    try {
      final uri = Uri.parse(serverUrl);
      MessageChannel channel;

      logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'connect', message: 'Connecting', data: {'scheme': uri.scheme});
      if (uri.scheme == 'ws' || uri.scheme == 'wss') {
        // WebSocket transport
        channel = await _connectWebSocket(uri, authToken);
        logDev(level: McpLogLevel.debug, serverUrl: serverUrl, category: 'connect', message: 'WebSocket channel created');
      } else if (uri.scheme == 'http' || uri.scheme == 'https') {
        // HTTP transport
        channel = await _connectHttp(uri, authToken, serverUrl);
        logDev(level: McpLogLevel.debug, serverUrl: serverUrl, category: 'connect', message: 'HTTP/SSE channel created');
      } else {
        throw Exception('Unsupported protocol: ${uri.scheme}. Only HTTP and WebSocket are supported.');
      }

      _channels[serverUrl] = channel;

      // For WebSocket channels, create a JSON-RPC Peer.
      if (channel is WebSocketMessageChannel) {
        final ws = channel.channel;
        final peer = rpc.Peer(ws.cast<String>());
        _wsPeers[serverUrl] = peer;
        peer.listen();
        // Reconnect on peer completion/close
        peer.done.whenComplete(() {
          if (_channels[serverUrl] is WebSocketMessageChannel) {
            logDev(level: McpLogLevel.warn, serverUrl: serverUrl, category: 'connect', message: 'Peer closed');
            _scheduleWsReconnect(serverUrl);
          }
        });
      }

      // Initialize MCP connection
      final initialized = await _initialize(serverUrl);
      if (!initialized) {
        _setState(serverUrl, McpConnectionState.error);
        disconnect(serverUrl);
        return;
      }

      _setState(serverUrl, McpConnectionState.connected);
      _startHeartbeat(serverUrl);
      await _listToolsForServer(serverUrl);
      notifyListeners();
      logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'connect', message: 'Connected');
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to connect to MCP server at $serverUrl: $e');
      _lastErrors[serverUrl] = e.toString();
      _setState(serverUrl, McpConnectionState.error);
      disconnect(serverUrl);
      logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'connect', message: 'Connect failed', data: {'error': e.toString()});
    }
  }

  /// Connect via WebSocket
  Future<MessageChannel> _connectWebSocket(Uri uri, String? authToken) async {
    final headers = <String, dynamic>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    if (kIsWeb) {
      if (kDebugMode) debugPrint('MCP WebSocket connect (web) -> $uri');
      logDev(level: McpLogLevel.debug, serverUrl: uri.toString(), category: 'ws', message: 'Connecting (web)');
      return WebSocketMessageChannel(WebSocketChannel.connect(uri));
    } else {
      if (kDebugMode) debugPrint('MCP WebSocket connect -> $uri');
      logDev(level: McpLogLevel.debug, serverUrl: uri.toString(), category: 'ws', message: 'Connecting');
      final ws = io.IOWebSocketChannel.connect(
        uri,
        protocols: ['jsonrpc-2.0'],
        headers: headers.isEmpty ? null : headers,
      );
      return WebSocketMessageChannel(ws);
    }
  }

  /// Connect via HTTP
  Future<MessageChannel> _connectHttp(Uri uri, String? authToken, String serverUrl) async {
    final headers = <String, String>{};
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    if (kDebugMode) debugPrint('MCP HTTP connect -> $uri');
    logDev(level: McpLogLevel.debug, serverUrl: serverUrl, category: 'http', message: 'HTTP/SSE connect');
    final client = http.Client();
    // Use StreamChannel-based HTTP/SSE channel and wrap with json_rpc_2.Peer
    final sse = HttpSseStreamChannel(client, uri, headers);
    final peer = rpc.Peer(sse);
    _wsPeers[serverUrl] = peer; // unified path uses Peer for HTTP as well
    peer.listen();
    return HttpPeerChannel(sse);
  }

  void disconnect(String serverUrl) {
    // Close WS peer if present
    final peer = _wsPeers.remove(serverUrl);
    if (peer != null) {
      try {
        peer.close();
      } catch (_) {}
    }
    // Stop heartbeat
    _heartbeatTimers.remove(serverUrl)?.cancel();
    _channels[serverUrl]?.close();
    _channels.remove(serverUrl);
    _serverTools.remove(serverUrl);
    _setState(serverUrl, McpConnectionState.disconnected);
    logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'connect', message: 'Disconnected');
    
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
      logDev(level: McpLogLevel.debug, serverUrl: serverUrl, category: 'rpc', message: 'initialize');
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
      }).timeout(const Duration(seconds: 20));

      if (response.error != null) {
        if (kDebugMode) debugPrint('MCP initialize error: ${response.error}');
        _lastErrors[serverUrl] = 'Initialize failed: ${response.error}';
        logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'rpc', message: 'initialize error', data: {'error': response.error.toString()});
        return false;
      }

      if (kDebugMode) debugPrint('MCP initialized successfully for $serverUrl');
      logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'rpc', message: 'initialize ok');
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('MCP initialize timeout/error for $serverUrl: $e');
      _lastErrors[serverUrl] = 'Initialize failed: $e';
       logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'rpc', message: 'initialize exception', data: {'error': e.toString()});
      return false;
    }
  }

  /// List tools from server
  Future<void> _listToolsForServer(String serverUrl) async {
    try {
      logDev(level: McpLogLevel.debug, serverUrl: serverUrl, category: 'tools', message: 'tools/list');
      final response = await _rpc(serverUrl, 'tools/list', {})
          .timeout(const Duration(seconds: 15));

      if (response.error != null) {
        if (kDebugMode) debugPrint('MCP tools/list error: ${response.error}');
        _lastErrors[serverUrl] = response.error.toString();
        logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'tools', message: 'tools/list error', data: {'error': response.error.toString()});
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
      if (kDebugMode) debugPrint('MCP loaded ${tools.length} tools from $serverUrl');
      logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'tools', message: 'Loaded tools', data: {'count': tools.length});
    } catch (e) {
      if (kDebugMode) debugPrint('MCP tools/list failed for $serverUrl: $e');
      _lastErrors[serverUrl] = 'Failed to list tools: $e';
      logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'tools', message: 'tools/list exception', data: {'error': e.toString()});
    }
  }

  /// Send JSON-RPC request
  Future<McpResponse> _rpc(String serverUrl, String method, Map<String, dynamic> params) async {
    final channel = _channels[serverUrl];
    if (channel == null) {
      throw Exception('Not connected to server: $serverUrl');
    }

    // If this server uses WebSocket with a json_rpc_2 Peer, route via Peer.
    final peer = _wsPeers[serverUrl];
    if (peer != null) {
      try {
        final reqId = _uuid.v4();
        if (kDebugMode) debugPrint('MCP(WS Peer) -> $method');
        logDev(level: McpLogLevel.debug, serverUrl: serverUrl, category: 'rpc', message: 'request', data: {'method': method, 'requestId': reqId});
        final result = await peer.sendRequest(method, params);
        logDev(level: McpLogLevel.debug, serverUrl: serverUrl, category: 'rpc', message: 'response', data: {'method': method, 'requestId': reqId});
        return McpResponse(result: result, error: null, id: 'peer');
      } on rpc.RpcException catch (e) {
        logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'rpc', message: 'rpc error', data: {'method': method, 'code': e.code, 'message': e.message});
        return McpResponse(
          result: null,
          error: McpError(code: e.code, message: e.message, data: e.data),
          id: 'peer',
        );
      } catch (e) {
        logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'rpc', message: 'exception', data: {'method': method, 'error': e.toString()});
        return McpResponse(
          result: null,
          error: McpError(code: -32000, message: e.toString(), data: null),
          id: 'peer',
        );
      }
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

    if (kDebugMode) debugPrint('MCP -> $method id=$id');
    channel.sink.add(request.toJson());

    return completer.future;
  }

  

  /// Call a tool
  Future<McpToolResult> call(String serverUrl, String toolName, Map<String, dynamic> arguments, {Duration? timeout}) async {
    try {
      logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'tool', message: 'call start', data: {'name': toolName});
      final response = await _rpc(serverUrl, 'tools/call', {
        'name': toolName,
        'arguments': arguments,
      }).timeout(timeout ?? const Duration(seconds: 30));

      if (response.error != null) {
        logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'tool', message: 'call error', data: {'name': toolName, 'error': response.error.toString()});
        return McpToolResult(
          result: null,
          error: response.error.toString(),
        );
      }

      logDev(level: McpLogLevel.info, serverUrl: serverUrl, category: 'tool', message: 'call ok', data: {'name': toolName});
      return McpToolResult(
        result: response.result,
        error: null,
      );
    } catch (e) {
      logDev(level: McpLogLevel.error, serverUrl: serverUrl, category: 'tool', message: 'call exception', data: {'name': toolName, 'error': e.toString()});
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

  // Expose underlying channel for json_rpc_2 Peer
  WebSocketChannel get channel => _channel;

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

/// HTTP/SSE message channel implementation for Docker MCP Gateway
class HttpMessageChannel implements MessageChannel {
  final http.Client _client;
  final Uri _baseUri;
  final Map<String, String> _headers;
  final StreamController<dynamic> _controller = StreamController.broadcast();
  late final HttpMessageSink _sink;
  StreamSubscription<List<int>>? _sseSubscription;
  final StringBuffer _buffer = StringBuffer();
  // Preferred endpoint to POST JSON-RPC to (as emitted by server)
  Uri? _sessionEndpoint;
  // Alternative form (canonical fallback)
  Uri? _sessionEndpointAlt;
  String? _sessionId;
  Completer<Uri>? _sessionReady;
  // Accumulate multi-line SSE event data
  final StringBuffer _eventDataBuffer = StringBuffer();
  String _currentEvent = '';

  HttpMessageChannel(this._client, this._baseUri, this._headers) {
    _sink = HttpMessageSink(_client, _baseUri, _headers, this);
    _startSSEConnection();
  }

  Uri? get sessionEndpoint => _sessionEndpoint;
  Uri? get sessionEndpointAlt => _sessionEndpointAlt;
  String? get sessionId => _sessionId;

  Future<Uri?> waitForSession({Duration timeout = const Duration(seconds: 3)}) async {
    if (_sessionEndpoint != null) return _sessionEndpoint;
    _sessionReady ??= Completer<Uri>();
    try {
      final uri = await _sessionReady!.future.timeout(timeout);
      return uri;
    } catch (_) {
      return _sessionEndpoint; // may still be null
    }
  }

  // Parse and set the session endpoint from an SSE payload that may be either:
  //  - a full/relative path like '/sse?sessionid=abcd' or '/message?sessionId=abcd'
  //  - a RequestURI string like '?sessionid=abcd' (from gateway's endpoint event)
  // Prefer the exact endpoint shape provided by the gateway. If it looks like
  // '/message?sessionId=...' prefer that; also compute canonical fallback '/sse?sessionid=...'.
  void _setSessionEndpointFromData(String data) {
    final trimmed = data.trim();
    if (trimmed.isEmpty) return;

    // Extract session id from any of the following forms:
    // - ?sessionid=abcd
    // - ?sessionId=abcd
    // - /sse?sessionid=abcd
    // - /message?sessionId=abcd
    // - full URL variants
    String? sessionId;
    try {
      Uri parsed;
      if (trimmed.startsWith('?')) {
        parsed = Uri.parse('http://dummy$trimmed');
      } else if (trimmed.startsWith('/')) {
        parsed = Uri.parse('http://dummy$trimmed');
      } else if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        parsed = Uri.parse(trimmed);
      } else {
        // unknown string; try as query
        parsed = Uri.parse('http://dummy?$trimmed');
      }
      // Case-insensitive fetch: check both keys
      final q = parsed.queryParameters;
      sessionId = q['sessionid'] ?? q['sessionId'];
      // If not found, attempt manual parse
      sessionId ??= RegExp(r'[?&](sessionid|sessionId)=([^&#\s]+)')
          .firstMatch(parsed.toString())
          ?.group(2);
    } catch (e) {
      if (kDebugMode) debugPrint('MCP session parse error for "$data": $e');
    }

    if (sessionId == null || sessionId.isEmpty) {
      if (kDebugMode) debugPrint('MCP could not extract session id from: $data');
      return;
    }

    // Build both forms: preferred (as-gateway) and canonical fallback
    final canonical = Uri(
      scheme: _baseUri.scheme,
      host: _baseUri.host,
      port: _baseUri.hasPort ? _baseUri.port : null,
      path: '/sse',
      queryParameters: {'sessionid': sessionId},
    );

    Uri preferred;
    if (trimmed.contains('/message') || trimmed.contains('sessionId=')) {
      preferred = Uri(
        scheme: _baseUri.scheme,
        host: _baseUri.host,
        port: _baseUri.hasPort ? _baseUri.port : null,
        path: '/message',
        queryParameters: {'sessionId': sessionId},
      );
    } else {
      preferred = canonical;
    }

    _sessionId = sessionId;
    _sessionEndpoint = preferred;
    _sessionEndpointAlt = canonical == preferred ? null : canonical;
    if (kDebugMode) debugPrint('MCP preferred session endpoint: $_sessionEndpoint');
    if (_sessionEndpointAlt != null) {
      if (kDebugMode) debugPrint('MCP alt session endpoint: $_sessionEndpointAlt');
    }
    if (_sessionReady != null && !(_sessionReady!.isCompleted)) {
      _sessionReady!.complete(_sessionEndpoint!);
    }
  }

  void _startSSEConnection() async {
    try {
      // Connect to SSE endpoint for receiving messages
      final sseUri = _baseUri.resolve('/sse');
      final sseRequest = http.Request('GET', sseUri);
      sseRequest.headers.addAll({
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        ..._headers,
      });

      if (kDebugMode) debugPrint('MCP HTTP/SSE connecting to: $sseUri');
      final sseResponse = await _client.send(sseRequest);
      
      if (sseResponse.statusCode != 200) {
        throw Exception('SSE connection failed: ${sseResponse.statusCode}');
      }

      // Listen to SSE stream
      _sseSubscription = sseResponse.stream.listen(
        (chunk) {
          try {
            final text = utf8.decode(chunk);
            _buffer.write(text);
            
            final lines = _buffer.toString().split('\n');
            _buffer.clear();
            
            // Keep incomplete line in buffer
            if (lines.isNotEmpty && !text.endsWith('\n')) {
              _buffer.write(lines.removeLast());
            }
            
            // Process complete lines
            for (final line in lines) {
              final raw = line;
              final trimmed = raw.trimRight();
              // Empty line denotes end of one SSE event
              if (trimmed.isEmpty) {
                _processSSEEvent();
                continue;
              }
              _processSSELine(trimmed);
            }
          } catch (e) {
            if (kDebugMode) debugPrint('MCP HTTP/SSE decode error: $e');
          }
        },
        onError: (error) {
          if (kDebugMode) debugPrint('MCP HTTP/SSE stream error: $error');
          _controller.addError(error);
        },
        onDone: () {
          if (kDebugMode) debugPrint('MCP HTTP/SSE stream closed');
          _controller.close();
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint('MCP HTTP/SSE connection failed: $e');
    }
  }

  // Process a single SSE line: track event name, accumulate data lines, and capture non-standard session endpoints
  void _processSSELine(String line) {
    if (line.startsWith('event:')) {
      _currentEvent = line.substring(6).trim();
      if (kDebugMode) debugPrint('MCP SSE event: $_currentEvent');
      return;
    }

    if (line.startsWith('data:')) {
      final data = line.length >= 5 ? line.substring(5).replaceFirst(RegExp('^ '), '') : '';
      if (data.isNotEmpty && data != '[DONE]') {
        if (_eventDataBuffer.isNotEmpty) _eventDataBuffer.write('\n');
        _eventDataBuffer.write(data);
      }
      return;
    }

    if (line.startsWith('id:')) {
      return; // ignore metadata for now
    }

    // Non-standard: session endpoint given as bare line
    final trimmed = line.trim();
    if (
      trimmed.startsWith('/sse?sessionid=') ||
      trimmed.startsWith('/message?sessionId=') ||
      trimmed.contains('sessionid=') ||
      trimmed.contains('sessionId=')
    ) {
      _setSessionEndpointFromData(trimmed);
      return;
    }

    // Unknown non-empty line
    if (trimmed.isNotEmpty) {
      if (kDebugMode) debugPrint('MCP HTTP/SSE unknown line: $line');
    }
  }

  // When a blank line ends an SSE event, parse accumulated data as one message, using current event name
  void _processSSEEvent() {
    if (_eventDataBuffer.isEmpty) return;
    final blob = _eventDataBuffer.toString();
    _eventDataBuffer.clear();
    final eventName = _currentEvent;
    _currentEvent = '';

    final data = blob.trim();
    if (data.isEmpty || data == '[DONE]') return;

    if (eventName == 'endpoint') {
      // endpoint handshake: normalize session endpoint
      if (kDebugMode) debugPrint('MCP SSE endpoint data: $data');
      _setSessionEndpointFromData(data);
      return;
    }

    if (data.startsWith('{') || data.startsWith('[')) {
      try {
        if (kDebugMode) debugPrint('MCP SSE message payload (first 200): ${data.substring(0, data.length > 200 ? 200 : data.length)}');
        final decoded = jsonDecode(data);

        void forward(dynamic obj) {
          try {
            if (obj is Map && obj.containsKey('id')) {
              if (kDebugMode) debugPrint('MCP SSE forward response id=${obj['id']}');
            } else if (obj is Map && obj.containsKey('method')) {
              if (kDebugMode) debugPrint('MCP SSE forward notification method=${obj['method']}');
            } else {
              if (kDebugMode) debugPrint('MCP SSE forward untyped object');
            }
            _controller.add(obj);
          } catch (e) {
            if (kDebugMode) debugPrint('MCP HTTP/SSE forward error: $e');
          }
        }

        dynamic tryUnwrap(dynamic obj) {
          if (obj is Map<String, dynamic> && obj.containsKey('jsonrpc')) return obj;

          if (obj is Map<String, dynamic>) {
            if (obj.containsKey('data')) {
              final inner = obj['data'];
              final unwrapped = tryUnwrap(inner);
              if (unwrapped != null) return unwrapped;
            }
            if (obj.containsKey('message')) {
              final inner = obj['message'];
              final unwrapped = tryUnwrap(inner);
              if (unwrapped != null) return unwrapped;
            }
            if (obj.containsKey('payload')) {
              final inner = obj['payload'];
              final unwrapped = tryUnwrap(inner);
              if (unwrapped != null) return unwrapped;
            }
          }

          if (obj is String) {
            final s = obj.trim();
            if (s.isNotEmpty && (s.startsWith('{') || s.startsWith('['))) {
              try {
                final innerDecoded = jsonDecode(s);
                return tryUnwrap(innerDecoded) ?? innerDecoded;
              } catch (_) {
                return null;
              }
            }
          }

          if (obj is List) {
            return obj;
          }

          return null;
        }

        final unwrapped = tryUnwrap(decoded);
        if (unwrapped is List) {
          for (final item in unwrapped) {
            final single = tryUnwrap(item) ?? item;
            forward(single);
          }
        } else if (unwrapped != null) {
          forward(unwrapped);
        } else {
          forward(decoded);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('MCP HTTP/SSE JSON parse error: $e');
      }
    } else {
      // Non-JSON payload may carry session endpoint
      if (kDebugMode) debugPrint('MCP HTTP/SSE received non-JSON data (event=$eventName): $data');
      if (
        data.startsWith('?sessionid=') ||
        data.startsWith('?sessionId=') ||
        data.startsWith('/sse?sessionid=') ||
        data.startsWith('/message?sessionId=') ||
        data.contains('sessionid=') ||
        data.contains('sessionId=')
      ) {
        _setSessionEndpointFromData(data);
      }
    }
  }

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  MessageSink get sink => _sink;

  @override
  Future<void> close() async {
    await _sseSubscription?.cancel();
    await _controller.close();
    _client.close();
  }
}

class HttpMessageSink implements MessageSink {
  final http.Client _client;
  final Uri _baseUri;
  final Map<String, String> _headers;
  final HttpMessageChannel _channel;

  HttpMessageSink(this._client, this._baseUri, this._headers, this._channel);

  @override
  void add(dynamic data) {
    _sendMessage(data);
  }

  void _sendMessage(dynamic data) async {
    try {
      // If data is already a JSON string (e.g., McpRequest.toJson()), don't re-encode.
      final String message = data is String ? data : jsonEncode(data);
      if (kDebugMode) debugPrint('MCP HTTP sending message: $message');
      
      // Build endpoint list with session endpoint first if available
      final endpoints = <Uri>[];
      // Wait briefly for session endpoint if not yet available
      final session = await _channel.waitForSession(timeout: const Duration(seconds: 3));
      if (session != null) {
        if (!endpoints.contains(session)) endpoints.add(session);
      } else if (_channel.sessionEndpoint != null) {
        if (!endpoints.contains(_channel.sessionEndpoint!)) endpoints.add(_channel.sessionEndpoint!);
      }
      // Add alternate canonical endpoint if available
      if (_channel.sessionEndpointAlt != null) {
        final alt = _channel.sessionEndpointAlt!;
        if (!endpoints.contains(alt)) endpoints.add(alt);
      }
      endpoints.addAll([
        _baseUri.resolve('/message'),  // Common MCP gateway endpoint
        _baseUri.resolve('/rpc'),      // Alternative RPC endpoint
        _baseUri,                      // Base endpoint
      ]);

      http.Response? response;
      
      for (final endpoint in endpoints) {
        try {
          if (kDebugMode) debugPrint('MCP HTTP trying POST to: $endpoint');
          response = await _postWithRedirects(endpoint, message);

          // Success - break out of loop
          if (response.statusCode >= 200 && response.statusCode < 300) {
            if (kDebugMode) debugPrint('MCP HTTP POST success to: $endpoint');
            break;
          } else if (response.statusCode == 400) {
            // Bad Request - log the response body for debugging
            if (kDebugMode) debugPrint('MCP HTTP POST 400 Bad Request to $endpoint: ${response.reasonPhrase}');
            if (kDebugMode) debugPrint('Response body: ${response.body}');
          } else if (response.statusCode != 404 && response.statusCode != 405) {
            // Not a "not found" or "method not allowed" - might be other error worth reporting
            if (kDebugMode) debugPrint('MCP HTTP POST failed to $endpoint: ${response.statusCode} ${response.reasonPhrase}');
            if (response.body.isNotEmpty) {
              if (kDebugMode) debugPrint('Response body: ${response.body}');
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('MCP HTTP POST error to $endpoint: $e');
          continue;
        }
      }

      if (response != null && response.statusCode >= 200 && response.statusCode < 300) {
        // Success - process response if there's content
        if (response.body.isNotEmpty) {
          try {
            final responseJson = jsonDecode(response.body);
            // Don't add to stream - SSE handles incoming messages
            if (kDebugMode) debugPrint('MCP HTTP POST response: $responseJson');
          } catch (e) {
            if (kDebugMode) debugPrint('MCP HTTP response parse error: $e');
          }
        }
      } else {
        if (kDebugMode) debugPrint('MCP HTTP send failed to all endpoints');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('MCP HTTP send error: $e');
    }
  }

  Future<http.Response> _postWithRedirects(Uri uri, String body, {int maxRedirects = 5}) async {
    var currentUri = uri;
    var redirectCount = 0;

    while (redirectCount < maxRedirects) {
      if (kDebugMode) debugPrint('MCP HTTP POST attempt ${redirectCount + 1} to: $currentUri');
      
      final response = await _client.post(
        currentUri,
        headers: {
          'Content-Type': 'application/json',
          ..._headers,
        },
        body: body,
      );

      if (kDebugMode) debugPrint('MCP HTTP response: ${response.statusCode} ${response.reasonPhrase}');

      if (response.statusCode == 307 || response.statusCode == 302 || response.statusCode == 301) {
        final location = response.headers['location'];
        if (kDebugMode) debugPrint('MCP HTTP redirect location header: $location');
        
        if (location != null && location.isNotEmpty) {
          Uri nextUri;
          
          if (location.startsWith('http://') || location.startsWith('https://')) {
            // Absolute URL
            nextUri = Uri.parse(location);
          } else if (location.startsWith('/')) {
            // Absolute path - use same scheme and host
            nextUri = Uri(
              scheme: currentUri.scheme,
              host: currentUri.host,
              port: currentUri.port,
              path: location,
            );
          } else {
            // Relative path
            nextUri = currentUri.resolve(location);
          }
          
          if (kDebugMode) debugPrint('MCP HTTP redirect ${redirectCount + 1}: $currentUri -> $nextUri');
          currentUri = nextUri;
          redirectCount++;
          continue;
        } else {
          if (kDebugMode) debugPrint('MCP HTTP redirect without location header');
          return response;
        }
      }

      return response;
    }

    throw Exception('Too many redirects (max: $maxRedirects)');
  }

  @override
  Future<void> close() async {
    // HTTP client will be closed by the channel
  }
}

/// Minimal no-op message channel useful for tests.
class DummyMessageChannel implements MessageChannel {
  final StreamController<dynamic> _controller = StreamController<dynamic>.broadcast();

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  MessageSink get sink => _DummySink();

  @override
  Future<void> close() async {
    await _controller.close();
  }
}

class _DummySink implements MessageSink {
  @override
  void add(dynamic data) {}

  @override
  Future<void> close() async {}
}
