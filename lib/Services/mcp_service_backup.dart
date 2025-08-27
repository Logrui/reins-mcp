import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart' as io;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'package:reins/Models/mcp.dart';

enum McpConnectionState { disconnected, connecting, connected, error }

// Minimal sink/channel abstraction to support both WebSocket and HTTP streaming
abstract class MessageSink {
  void add(dynamic data);
  Future<void> close();
}

abstract class MessageChannel {
  Stream<dynamic> get stream;
  MessageSink get sink;
  Future<void> close();
}

class WebSocketMessageSink implements MessageSink {
  final WebSocketChannel _inner;
  WebSocketMessageSink(this._inner);
  @override
  void add(dynamic data) => _inner.sink.add(data);
  @override
  Future<void> close() async => _inner.sink.close();
}

class WebSocketMessageChannel implements MessageChannel {
  final WebSocketChannel _inner;
  WebSocketMessageChannel(this._inner);
  @override
  Stream get stream => _inner.stream;
  @override
  MessageSink get sink => WebSocketMessageSink(_inner);
  @override
  Future<void> close() async {
    await _inner.sink.close();
  }
}

class HttpStreamingMessageSink implements MessageSink {
  final http.Client _client;
  final HttpStreamingMessageChannel _channel;
  final Map<String, String> _headers;
  HttpStreamingMessageSink(this._client, this._channel, this._headers);
  
  @override
  void add(dynamic data) {
    _sendMessage(data);
  }
  
  void _sendMessage(dynamic data) async {
    try {
      final rpcUri = await _channel._discoverRpcUri();
      final message = jsonEncode(data);
      
      var response = await _client.post(
        rpcUri,
        headers: {
          'Content-Type': 'application/json',
          ..._headers,
        },
        body: message,
      );
      
      // Handle redirects
      if (response.statusCode == 307 || response.statusCode == 302) {
        final location = response.headers['location'];
        if (location != null) {
          Uri redirectUri;
          if (location.startsWith('http')) {
            redirectUri = Uri.parse(location);
          } else {
            // Relative redirect - resolve against the original URI
            redirectUri = rpcUri.resolve(location);
          }
          debugPrint('MCP HTTP(streaming) following redirect to: $redirectUri');
          response = await _client.post(
            redirectUri,
            headers: {
              'Content-Type': 'application/json',
              ..._headers,
            },
            body: message,
          );
        }
      }
      
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('MCP HTTP(streaming) send got HTTP ${response.statusCode} ${response.reasonPhrase}');
        throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
      }
    } catch (e) {
      debugPrint('MCP HTTP(streaming) send error: $e');
    }
  }
  
  @override
  Future<void> close() async {
    // No persistent send connection to close.
  }
}

class HttpStreamingMessageChannel implements MessageChannel {
  final http.Client _client;
  final Uri _streamUri;  // For SSE/streaming
  Uri? _rpcUri;          // For JSON-RPC calls (discovered dynamically)
  final Map<String, String> _headers;
  final StreamController<dynamic> _controller = StreamController.broadcast();
  StreamSubscription<List<int>>? _sub;
  final StringBuffer _buffer = StringBuffer();
  String? _sessionId;

  HttpStreamingMessageChannel(this._client, this._streamUri, this._headers);
  
  Future<Uri> _discoverRpcUri() async {
    if (_rpcUri != null) return _rpcUri!;
    
    // Wait for session ID to be discovered from streaming response
    if (_sessionId != null) {
      final baseUrl = '${_streamUri.scheme}://${_streamUri.host}:${_streamUri.port}';
      _rpcUri = Uri.parse('$baseUrl/message?sessionId=$_sessionId');
      debugPrint('MCP using discovered session RPC endpoint: $_rpcUri');
      return _rpcUri!;
    }
    
    // Fallback to path-based derivation
    if (_streamUri.path.contains('/sse')) {
      _rpcUri = _streamUri.replace(path: _streamUri.path.replaceAll('/sse', ''));
    } else {
      _rpcUri = _streamUri;
    }
    debugPrint('MCP using fallback RPC endpoint: $_rpcUri');
    return _rpcUri!;
  }

  Future<void> start() async {
    final req = http.Request('GET', _streamUri);
    req.headers.addAll({
      'Accept': 'text/event-stream, application/x-ndjson, application/json',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      ..._headers
    });
    try {
      debugPrint('MCP HTTP(streaming) connect -> $_streamUri');
      final resp = await _client.send(req);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${{'status': resp.statusCode, 'reason': resp.reasonPhrase}}');
      }
      // Decode as NDJSON text lines; maintain buffer across chunks.
      _sub = resp.stream.listen(
        (chunk) {
          try {
            final text = utf8.decode(chunk);
            _buffer.write(text);
            String current = _buffer.toString();
            int lastNewline = current.lastIndexOf('\n');
            if (lastNewline >= 0) {
              final complete = current.substring(0, lastNewline);
              final remain = current.substring(lastNewline + 1);
              _buffer
                ..clear()
                ..write(remain);
              for (final line in complete.split('\n')) {
                final trimmed = line.trim();
                if (trimmed.isNotEmpty) {
                  // Handle SSE format properly
                  if (trimmed.startsWith('event: ')) {
                    // Skip event type lines
                    continue;
                  } else if (trimmed.startsWith('data: ')) {
                    final jsonData = trimmed.substring(6).trim();
                    if (jsonData.isNotEmpty && jsonData != '[DONE]') {
                      try {
                        // Try to parse as JSON to validate
                        jsonDecode(jsonData);
                        _controller.add(jsonData);
                      } catch (e) {
                        // If not JSON, might be session endpoint info
                        if (jsonData.startsWith('/message?sessionId=')) {
                          final sessionMatch = RegExp(r'sessionId=([a-f0-9-]+)').firstMatch(jsonData);
                          if (sessionMatch != null) {
                            _sessionId = sessionMatch.group(1);
                            final baseUrl = '${_streamUri.scheme}://${_streamUri.host}:${_streamUri.port}';
                            _rpcUri = Uri.parse('$baseUrl$jsonData');
                            debugPrint('MCP discovered session RPC endpoint from SSE: $_rpcUri');
                          }
                        }
                      }
                    }
                  } else {
                    // Plain JSON line (NDJSON format)
                    try {
                      jsonDecode(trimmed);
                      _controller.add(trimmed);
                    } catch (e) {
                      debugPrint('Failed to handle MCP message: $e');
                    }
                  }
                }
              }
            }
          } catch (e) {
            debugPrint('MCP HTTP(streaming) decode error: $e');
          }
        },
        onError: (e) {
          _controller.addError(e);
        },
        onDone: () {
          _controller.close();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _controller.addError(e);
      await _controller.close();
      rethrow;
    }
  }

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  MessageSink get sink => HttpStreamingMessageSink(_client, this, _headers);

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _controller.close();
    _client.close();
  }
}

class McpService extends ChangeNotifier {
  final Map<String, MessageChannel> _channels = {};
  final Map<String, List<McpTool>> _serverTools = {};
  final Map<String, Completer<McpResponse>> _pendingRequests = {};
  final Map<String, String> _requestServerById = {};
  final Uuid _uuid = const Uuid();
  final _stateController = StreamController<Map<String, McpConnectionState>>.broadcast();
  final Map<String, McpConnectionState> _connStates = {};
  final Map<String, String> _lastErrors = {};

  // Expose connection state changes for diagnostics/UI
  Stream<Map<String, McpConnectionState>> connectionStates() => _stateController.stream;

  bool isConnected(String serverUrl) => _channels.containsKey(serverUrl);
  List<McpTool> getTools(String serverUrl) => _serverTools[serverUrl] ?? [];
  String? getLastError(String serverUrl) => _lastErrors[serverUrl];

  Future<void> connectAll(List<McpServerConfig> servers) async {
    for (final cfg in servers) {
      await connect(cfg.endpoint, authToken: cfg.authToken);
    }
  }

  Future<MessageChannel> _openWebSocketWithFallback(
    String serverUrl, {
    String? authToken,
    List<String>? preferredProtocols,
  }) async {
    // Normalize and try multiple candidates (root and /ws)
    final primary = _normalizeWsUri(serverUrl);
    final candidates = <Uri>[primary];
    if (primary.path.isEmpty || primary.path == '/') {
      candidates.add(primary.replace(path: '/ws'));
      candidates.add(primary.replace(path: '/mcp'));
    }

    Object? lastErr;
    for (final uri in candidates) {
      try {
        if (kIsWeb) {
          debugPrint('MCP WS connect (web) -> $uri');
          return WebSocketMessageChannel(WebSocketChannel.connect(uri));
        }
        // Desktop: try preferred subprotocols first, then common fallbacks
        final baseProtos = <List<String>>[
          if (preferredProtocols != null && preferredProtocols.isNotEmpty) preferredProtocols,
          const ['jsonrpc-2.0'],
          const ['jsonrpc'],
          const <String>[],
          const ['mcp'],
        ];
        // Deduplicate lists
        final protos = <String>{};
        final protoLists = <List<String>>[];
        for (final lst in baseProtos) {
          final key = lst.join(',');
          if (protos.add(key)) protoLists.add(lst);
        }
        for (final p in protoLists) {
          try {
            final headers = <String, dynamic>{};
            if (authToken != null && authToken.isNotEmpty) {
              headers['Authorization'] = 'Bearer $authToken';
            }
            debugPrint('MCP WS connect -> $uri protos=${p.isEmpty ? 'none' : p} hdrs=${headers.keys.toList()}');
            final ws = io.IOWebSocketChannel.connect(
              uri,
              protocols: p.isEmpty ? null : p,
              headers: headers.isEmpty ? null : headers,
            );
            return WebSocketMessageChannel(ws);
          } catch (e) {
            lastErr = e;
          }
        }
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr ?? Exception('Failed to open WebSocket');
  }

  List<Uri> _generateHttpEndpointCandidates(Uri baseUri) {
    final candidates = <Uri>[];
    
    // Add the original URI first
    candidates.add(baseUri);
    
    // For Docker MCP gateways, prioritize SSE endpoints that can provide session info
    final baseWithoutPath = baseUri.replace(path: '');
    candidates.addAll([
      baseWithoutPath.replace(path: '/sse'),
      baseWithoutPath.replace(path: '/events'),
      baseWithoutPath.replace(path: '/stream'),
      baseWithoutPath.replace(path: '/mcp/sse'),
      baseWithoutPath.replace(path: '/api/sse'),
    ]);
    
    // Add traditional endpoints as fallbacks
    if (baseUri.path.contains('sse')) {
      candidates.add(baseUri.replace(path: baseUri.path.replaceAll('/sse', '')));
      candidates.add(baseUri.replace(path: baseUri.path.replaceAll('/sse', '/rpc')));
      candidates.add(baseUri.replace(path: baseUri.path.replaceAll('/sse', '/mcp')));
    }
    
    candidates.addAll([
      baseWithoutPath,
      baseWithoutPath.replace(path: '/mcp'),
      baseWithoutPath.replace(path: '/rpc'),
      baseWithoutPath.replace(path: '/api'),
      baseWithoutPath.replace(path: '/jsonrpc'),
    ]);
    
    // Remove duplicates while preserving order
    final seen = <String>{};
    return candidates.where((uri) => seen.add(uri.toString())).toList();
  }

  Uri _normalizeWsUri(String input) {
    Uri uri;
    try {
      uri = Uri.parse(input);
    } catch (_) {
      // Fall back to ws:// if parse fails
      return Uri.parse('ws://$input');
    }
    // If missing scheme, default to ws
    if (uri.scheme.isEmpty) {
      uri = uri.replace(scheme: 'ws');
    }
    // Map http/https to ws/wss
    if (uri.scheme == 'http') {
      uri = uri.replace(scheme: 'ws');
    } else if (uri.scheme == 'https') {
      uri = uri.replace(scheme: 'wss');
    }
    return uri;
  }

  Future<void> disconnectAll() async {
    final urls = _channels.keys.toList();
    for (final u in urls) {
      disconnect(u);
    }
  }

  Future<void> connect(String serverUrl, {String? authToken, List<String>? preferredProtocols}) async {
    if (isConnected(serverUrl)) return;
    _setState(serverUrl, McpConnectionState.connecting);
    try {
      MessageChannel channel;
      final uri = Uri.parse(serverUrl);
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        // Use HTTP streaming transport - preserve the full path
        // For Docker MCP gateways, try the provided endpoint first, then fallbacks
        final candidates = _generateHttpEndpointCandidates(uri);
        
        MessageChannel? workingChannel;
        for (final candidateUri in candidates) {
          try {
            final headers = <String, String>{};
            if (authToken != null && authToken.isNotEmpty) {
              headers['Authorization'] = 'Bearer $authToken';
            }
            final client = http.Client();
            final httpChan = HttpStreamingMessageChannel(client, candidateUri, headers);
            await httpChan.start();
            workingChannel = httpChan;
            debugPrint('MCP HTTP connected successfully to $candidateUri');
            break;
          } catch (e) {
            debugPrint('MCP HTTP failed to connect to $candidateUri: $e');
          }
        }
        
        if (workingChannel == null) {
          throw Exception('Failed to connect to any HTTP endpoint for $serverUrl');
        }
        channel = workingChannel;
      } else {
        // Fallback to WebSocket for ws/wss
        channel = await _openWebSocketWithFallback(
          serverUrl,
          authToken: authToken,
          preferredProtocols: preferredProtocols,
        );
      }
      _channels[serverUrl] = channel;

      channel.stream.listen(
        (message) {
          _handleMessage(serverUrl, message);
        },
        onDone: () => disconnect(serverUrl),
        onError: (error) {
          _setState(serverUrl, McpConnectionState.error);
          debugPrint('MCP Error for $serverUrl: $error');
          disconnect(serverUrl);
        },
      );

      // Perform MCP initialize handshake before using tools
      final ok = await _initialize(serverUrl);
      if (!ok) {
        _setState(serverUrl, McpConnectionState.error);
        disconnect(serverUrl);
        return;
      }
      _setState(serverUrl, McpConnectionState.connected);
      await _listToolsForServer(serverUrl);
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to connect to MCP server at $serverUrl: $e');
      _lastErrors[serverUrl] = '$e';
      _setState(serverUrl, McpConnectionState.error);
      disconnect(serverUrl);
    }
  }

  void disconnect(String serverUrl) {
    _channels[serverUrl]?.close();
    _channels.remove(serverUrl);
    _serverTools.remove(serverUrl);
    _setState(serverUrl, McpConnectionState.disconnected);
    // Fail any pending requests for this server
    final idsToFail = _pendingRequests.keys
        .where((id) => _requestServerById[id] == serverUrl)
        .toList(growable: false);
    for (final id in idsToFail) {
      final completer = _pendingRequests.remove(id);
      _requestServerById.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(Exception('Disconnected from server'));
      }
    }
    notifyListeners();
  }

  Future<void> _listToolsForServer(String serverUrl) async {
    // Fetch tools with pagination (nextCursor) per MCP spec
    final all = <McpTool>[];
    String? cursor;
    int page = 0;
    do {
      final params = <String, dynamic>{};
      if (cursor != null) params['cursor'] = cursor;
      debugPrint('MCP tools/list request $serverUrl page=$page cursor=${cursor ?? ''}');
      McpResponse resp;
      try {
        resp = await _rpc(serverUrl, 'tools/list', params).timeout(const Duration(seconds: 15));
      } on TimeoutException {
        debugPrint('MCP tools/list timeout for $serverUrl (page $page)');
        _lastErrors[serverUrl] = 'tools/list timeout (page $page)';
        break;
      }
      if (resp.error != null) {
        debugPrint('MCP tools/list error for $serverUrl (page $page): ${resp.error}');
        _lastErrors[serverUrl] = resp.error.toString();
        break;
      }
      final result = resp.result;
      if (result is Map) {
        debugPrint('MCP tools/list result keys (page $page): ${result.keys.toList()}');
        final list = result['tools'] ?? result['items'] ?? result['data'];
        if (list is List) {
          final pageTools = list
              .whereType<Map>()
              .map((toolJson) => McpTool.fromJson(toolJson.cast<String, dynamic>()))
              .toList();
          all.addAll(pageTools);
        } else {
          debugPrint('MCP tools/list unexpected tools type for $serverUrl (page $page): ${list.runtimeType}');
        }
        cursor = (result['nextCursor'] ?? result['next'] ?? result['cursor'] ?? result['next_cursor']) as String?;
      } else if (result is List) {
        final pageTools = result
            .whereType<Map>()
            .map((toolJson) => McpTool.fromJson(toolJson.cast<String, dynamic>()))
            .toList();
        all.addAll(pageTools);
        cursor = null; // no pagination when result is a bare list
      } else {
        debugPrint('MCP tools/list returned unexpected result for $serverUrl (page $page): $result');
        _lastErrors[serverUrl] = 'Unexpected tools/list result: $result';
        break;
      }
      page += 1;
    } while (cursor != null && cursor.isNotEmpty);

    // Fallback: Some gateways multiplex multiple servers and require a selector.
    if (all.isEmpty) {
      debugPrint('MCP tools/list empty for $serverUrl; trying per-server fallback');
      try {
        McpResponse listServers;
        try {
          listServers = await _rpc(serverUrl, 'servers/list', const {}).timeout(const Duration(seconds: 10));
        } on TimeoutException {
          debugPrint('MCP servers/list timeout for $serverUrl');
          listServers = McpResponse(id: 'timeout', result: null, error: McpError(code: -1, message: 'servers/list timeout'));
        }
        final names = <String>[];
        final r = listServers.result;
        if (r is Map) {
          final s = r['servers'] ?? r['items'] ?? r['data'];
          if (s is List) {
            for (final v in s) {
              if (v is String) names.add(v);
              if (v is Map && v['name'] is String) names.add(v['name'] as String);
            }
          }
        } else if (r is List) {
          for (final v in r) {
            if (v is String) names.add(v);
            if (v is Map && v['name'] is String) names.add(v['name'] as String);
          }
        }
        if (names.isEmpty) {
          debugPrint('MCP servers/list returned no names for $serverUrl; skipping per-server fetch');
        } else {
          debugPrint('MCP servers/list names for $serverUrl: $names');
          for (final name in names) {
            String? c;
            int p = 0;
            do {
              final params = <String, dynamic>{'server': name};
              if (c != null) params['cursor'] = c;
              debugPrint('MCP tools/list(server=$name) request $serverUrl page=$p cursor=${c ?? ''}');
              McpResponse resp;
              try {
                resp = await _rpc(serverUrl, 'tools/list', params).timeout(const Duration(seconds: 15));
              } on TimeoutException {
                debugPrint('MCP tools/list(server=$name) timeout for $serverUrl (page $p)');
                break;
              }
              if (resp.error != null) {
                debugPrint('MCP tools/list(server=$name) error for $serverUrl (page $p): ${resp.error}');
                break;
              }
              final result = resp.result;
              if (result is Map) {
                final list = result['tools'] ?? result['items'] ?? result['data'];
                if (list is List) {
                  final pageTools = list
                      .whereType<Map>()
                      .map((toolJson) => McpTool.fromJson(toolJson.cast<String, dynamic>()))
                      .toList();
                  all.addAll(pageTools);
                }
                c = (result['nextCursor'] ?? result['next'] ?? result['cursor'] ?? result['next_cursor']) as String?;
              } else if (result is List) {
                final pageTools = result
                    .whereType<Map>()
                    .map((toolJson) => McpTool.fromJson(toolJson.cast<String, dynamic>()))
                    .toList();
                all.addAll(pageTools);
                c = null;
              } else {
                break;
              }
              p += 1;
            } while (c != null && c.isNotEmpty);
          }
        }
      } catch (e) {
        debugPrint('MCP per-server fallback threw for $serverUrl: $e');
      }
    }

    _serverTools[serverUrl] = all;
    debugPrint('MCP tools/list total for $serverUrl: ${all.length}');
    notifyListeners();
  }

  // Minimal MCP initialize handshake. Many servers require this before other calls.
  Future<bool> _initialize(String serverUrl) async {
    try {
      final params = {
        'clientInfo': {
          'name': 'Reins',
          'version': '0.1.0',
        },
        // Per MCP spec, advertise the protocol version we speak
        'protocolVersion': '2024-11-05',
        'capabilities': {
          // TODO: declare capabilities as we add them
        },
      };
      // Try common initialize variants and frame types
      final attempts = <Map<String, dynamic>>[
        {'method': 'initialize', 'binary': false, 'label': 'text'},
        {'method': 'initialize', 'binary': true, 'label': 'binary'},
        {'method': 'server/initialize', 'binary': false, 'label': 'alt(text)'},
        {'method': 'server/initialize', 'binary': true, 'label': 'alt(binary)'},
        {'method': 'mcp/initialize', 'binary': false, 'label': 'mcp(text)'},
        {'method': 'mcp/initialize', 'binary': true, 'label': 'mcp(binary)'},
      ];
      McpResponse? resp;
      for (final a in attempts) {
        final m = a['method'] as String;
        final b = a['binary'] as bool;
        final label = a['label'];
        try {
          debugPrint('MCP trying initialize ($label) for $serverUrl');
          resp = await _rpcSend(serverUrl, m, params, sendBinary: b).timeout(const Duration(seconds: 10));
          if (resp.error == null) {
            break;
          }
          debugPrint('MCP initialize error ($label) for $serverUrl: ${resp.error}');
        } on TimeoutException {
          debugPrint('MCP initialize timeout ($label) for $serverUrl');
        } catch (e) {
          debugPrint('MCP initialize threw ($label) for $serverUrl: $e');
        }
      }
      if (resp == null) {
        _lastErrors[serverUrl] = 'initialize failed (no response)';
        return false;
      }
      if (resp.error != null) {
        _lastErrors[serverUrl] = resp.error.toString();
        return false;
      }
      debugPrint('MCP initialize OK for $serverUrl');
      // Per MCP spec, send follow-up 'notifications/initialized' notification.
      try {
        await _notify(serverUrl, 'notifications/initialized', {});
      } catch (_) {}
      return true;
    } catch (e) {
      debugPrint('MCP initialize threw for $serverUrl: $e');
      _lastErrors[serverUrl] = '$e';
      return false;
    }
  }

  Future<List<McpTool>> listTools({String? server}) async {
    if (server != null) {
      await _listToolsForServer(server);
      return _serverTools[server] ?? [];
    }
    // refresh all
    for (final url in _channels.keys) {
      await _listToolsForServer(url);
    }
    return _serverTools.values.expand((e) => e).toList(growable: false);
  }

  Future<McpToolResult> call(
    String serverUrl,
    String tool,
    Map<String, dynamic> args, {
    Duration? timeout,
  }) async {
    final params = {'name': tool, 'arguments': args};
    final future = _rpc(serverUrl, 'tools/call', params);
    final resp = timeout == null
        ? await future
        : await future.timeout(timeout, onTimeout: () => McpResponse(id: 'timeout', error: McpError(code: -1, message: 'timeout')));
    if (resp.error != null) {
      return McpToolResult(error: resp.error.toString());
    }
    return McpToolResult(result: resp.result);
  }

  // Low-level JSON-RPC call (text frame)
  Future<McpResponse> _rpc(String serverUrl, String method, Map<String, dynamic> params) async {
    return _rpcSend(serverUrl, method, params, sendBinary: false);
  }

  // Low-level JSON-RPC call with option to send binary frame
  Future<McpResponse> _rpcSend(String serverUrl, String method, Map<String, dynamic> params, {required bool sendBinary}) async {
    final channel = _channels[serverUrl];
    if (channel == null) {
      throw Exception('Not connected to server: $serverUrl');
    }

    final completer = Completer<McpResponse>();
    final id = _uuid.v4();
    _pendingRequests[id] = completer;
    _requestServerById[id] = serverUrl;

    final request = McpRequest(method: method, params: params, id: id);
    final payloadStr = request.toJson();
    // For HTTP streaming, only text is supported; for WS we can optionally try binary.
    if (!sendBinary) {
      channel.sink.add(payloadStr);
      debugPrint('MCP -> (text) $method id=$id');
    } else {
      // Attempt binary; if the sink cannot handle it, it will log and fallback is not necessary here.
      channel.sink.add(utf8.encode(payloadStr));
      debugPrint('MCP -> (binary) $method id=$id');
    }

    return completer.future;
  }

  // JSON-RPC notification (no id, no response expected)
  Future<void> _notify(String serverUrl, String method, Map<String, dynamic> params) async {
    final channel = _channels[serverUrl];
    if (channel == null) return;
    final payload = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
    channel.sink.add(payload);
  }

  void _handleMessage(String serverUrl, dynamic message) {
    try {
      final text = message is String ? message : utf8.decode((message as List<int>));
      final json = jsonDecode(text);
      if (json is List) {
        for (final item in json) {
          _handleMessage(serverUrl, jsonEncode(item));
        }
        return;
      }
      if (json is Map && json.containsKey('id')) {
        final map = (json as Map);
        final idStr = '${map['id']}';
        final response = McpResponse(
          id: idStr,
          result: map['result'],
          error: map['error'] != null ? McpError.fromJson((map['error'] as Map).cast<String, dynamic>()) : null,
        );
        final completer = _pendingRequests.remove(idStr);
        _requestServerById.remove(idStr);
        completer?.complete(response);
      } else if (json is Map && json['method'] is String) {
        // Handle notifications of interest
        final method = json['method'] as String;
        if (method == 'notifications/tools/list_changed') {
          // Refresh tools list
          _listToolsForServer(serverUrl);
        }
      }
    } catch (e) {
      debugPrint('Failed to handle MCP message: $e');
    }
  }

  void _setState(String serverUrl, McpConnectionState state) {
    _connStates[serverUrl] = state;
    _stateController.add(Map<String, McpConnectionState>.from(_connStates));
  }

  @override
  void dispose() {
    for (var url in _channels.keys.toList()) {
      _channels[url]?.close();
    }
    _channels.clear();
    _stateController.close();
    super.dispose();
  }
}
