import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';
import 'package:flutter/foundation.dart';

/// A `StreamChannel<String>` that bridges HTTP SSE (incoming) + HTTP POST (outgoing)
/// to support JSON-RPC 2.0 over HTTP for the Docker MCP Gateway.
///
/// - Incoming: connects to GET {base}/sse and forwards each complete JSON-RPC
///   message as a String into the stream.
/// - Outgoing: POSTs JSON-RPC payloads (String) to the preferred session endpoint
///   emitted by the gateway via the initial `event: endpoint` SSE, with fallback
///   to canonical `/sse?sessionid=<id>`, then `/message`, `/rpc`, base.
class HttpSseStreamChannel with StreamChannelMixin<String> implements StreamChannel<String> {
  final http.Client _client;
  final Uri _baseUri;
  final Map<String, String> _headers;

  final StreamController<String> _controller = StreamController.broadcast();
  late final _HttpSseSink _sink;

  // SSE
  StreamSubscription<List<int>>? _sseSub;
  Timer? _reconnectTimer;
  int _retries = 0;
  bool _disposed = false;
  final StringBuffer _chunkBuffer = StringBuffer();
  final StringBuffer _eventData = StringBuffer();
  String _currentEvent = '';
  // Minimal cookie jar for gateways that use Set-Cookie on redirect/session
  String? _cookieHeader;

  // Session endpoint handling
  Uri? _preferredEndpoint; // e.g., /message?sessionId=...
  Uri? _canonicalEndpoint; // /sse?sessionid=...
  Completer<Uri>? _sessionReady;

  HttpSseStreamChannel(this._client, this._baseUri, this._headers) {
    _sink = _HttpSseSink(this);
    _connectSse();
  }

  // Resolve a redirect Location header against a base URI.
  Uri _resolveRedirect(Uri base, String location) {
    try {
      if (location.startsWith('http://') || location.startsWith('https://')) {
        return Uri.parse(location);
      }
      if (location.startsWith('/')) {
        return Uri(
          scheme: base.scheme,
          host: base.host,
          port: base.hasPort ? base.port : null,
          path: location,
        );
      }
      return base.resolve(location);
    } catch (_) {
      return base; // fallback
    }
  }

  // Public API
  @override
  Stream<String> get stream => _controller.stream;

  @override
  StreamSink<String> get sink => _sink;

  Future<void> dispose() async {
    _disposed = true;
    await _sseSub?.cancel();
    _reconnectTimer?.cancel();
    await _controller.close();
    _client.close();
  }

  // Generic redirect follower for streamed requests, with cookie propagation.
  Future<http.StreamedResponse> _sendWithRedirects(http.Request request, {int maxRedirects = 5}) async {
    var currentReq = request;
    var redirects = 0;
    while (true) {
      if (_cookieHeader != null) currentReq.headers['Cookie'] = _cookieHeader!;
      final res = await _client.send(currentReq);
      final setCookie = res.headers['set-cookie'];
      if (setCookie != null && setCookie.isNotEmpty) {
        _cookieHeader = _extractCookieHeader(setCookie);
      }
      final status = res.statusCode;
      if (status == 301 || status == 302 || status == 307) {
        if (redirects++ >= maxRedirects) {
          return res;
        }
        final loc = res.headers['location'];
        if (loc == null || loc.isEmpty) {
          return res;
        }
        final nextUri = _resolveRedirect(currentReq.url, loc);
        final nextReq = http.Request(currentReq.method, nextUri);
        nextReq.headers.addAll(currentReq.headers);
        if (currentReq.method != 'GET') {
          nextReq.bodyBytes = await currentReq.finalize().toBytes();
        }
        currentReq = nextReq;
        continue;
      }
      return res;
    }
  }

  String _extractCookieHeader(String setCookie) {
    // Take only cookie-pairs (name=value) and join for Cookie header
    // naive split by comma may break with expires, so split on ';' first item
    // Support multiple Set-Cookie by comma-separated: pick first pair of each
    final parts = setCookie.split(',');
    final pairs = <String>[];
    for (final p in parts) {
      final semi = p.split(';').first.trim();
      if (semi.contains('=')) pairs.add(semi);
    }
    return pairs.join('; ');
  }

  // Wait for a session endpoint if possible, otherwise return what we have.
  Future<Uri?> waitForSession({Duration timeout = const Duration(seconds: 10)}) async {
    if (_preferredEndpoint != null) return _preferredEndpoint;
    _sessionReady ??= Completer<Uri>();
    try {
      final uri = await _sessionReady!.future.timeout(timeout);
      return uri;
    } catch (_) {
      return _preferredEndpoint; // possibly null
    }
  }

  Uri? get preferredEndpoint => _preferredEndpoint;
  Uri? get canonicalEndpoint => _canonicalEndpoint;

  // Internal: SSE connect and parsing
  Future<void> _connectSse() async {
    try {
      // Try a set of common SSE endpoints to be resilient to gateway pathing.
      final candidates = <Uri>[
        _baseUri.resolve('/sse'),
        _baseUri.resolve('/sse/connect'),
        _baseUri, // some gateways serve SSE at base
        _baseUri.resolve('/events'),
        _baseUri.resolve('/events/connect'),
        _baseUri.resolve('/stream'),
        _baseUri.resolve('/mcp/sse'),
        _baseUri.resolve('/gateway/sse'),
      ];

      http.StreamedResponse? res;
      Uri? connected;
      for (final sseUri in candidates) {
        // Try GET first
        debugPrint('HttpSseStreamChannel connecting to $sseUri');
        try {
          final getReq = http.Request('GET', sseUri);
          getReq.headers.addAll({
            'Accept': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            ..._headers,
          });
          if (_cookieHeader != null) getReq.headers['Cookie'] = _cookieHeader!;
          http.StreamedResponse attempt = await _sendWithRedirects(getReq, maxRedirects: 5);
          int status = attempt.statusCode;
          String ct = attempt.headers['content-type'] ?? '';
          if (status == 200 && ct.contains('text/event-stream')) {
            res = attempt;
            connected = sseUri;
            break;
          } else {
            debugPrint('HttpSseStreamChannel SSE attempt(GET) ${sseUri.path} -> $status $ct');
          }
        } catch (e) {
          debugPrint('HttpSseStreamChannel SSE GET error for $sseUri: $e');
        }

        // Try POST fallback for SSE if GET didn't succeed
        try {
          final postReq = http.Request('POST', sseUri);
          postReq.headers.addAll({
            'Accept': 'text/event-stream',
            'Content-Type': 'application/json',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            ..._headers,
          });
          if (_cookieHeader != null) postReq.headers['Cookie'] = _cookieHeader!;
          // Empty body JSON to open a stream where servers require it
          postReq.body = '{}';
          http.StreamedResponse attempt = await _sendWithRedirects(postReq, maxRedirects: 5);
          int status = attempt.statusCode;
          String ct = attempt.headers['content-type'] ?? '';
          if (status == 200 && ct.contains('text/event-stream')) {
            res = attempt;
            connected = sseUri;
            break;
          } else {
            debugPrint('HttpSseStreamChannel SSE attempt(POST) ${sseUri.path} -> $status $ct');
          }
        } catch (e) {
          debugPrint('HttpSseStreamChannel SSE POST error for $sseUri: $e');
        }
      }

      if (res == null || connected == null) {
        throw Exception('SSE connection failed: no candidate endpoints accepted');
      }

      _retries = 0; // reset backoff on successful connect
      _sseSub = res.stream.listen((chunk) {
        final text = utf8.decode(chunk);
        _chunkBuffer.write(text);
        final lines = _chunkBuffer.toString().split('\n');
        _chunkBuffer.clear();
        if (lines.isNotEmpty && !text.endsWith('\n')) {
          _chunkBuffer.write(lines.removeLast());
        }
        for (final line in lines) {
          final trimmed = line.trimRight();
          if (trimmed.isEmpty) {
            _finishEvent();
            continue;
          }
          _onSseLine(trimmed);
        }
      }, onError: (e) {
        debugPrint('HttpSseStreamChannel SSE error: $e');
        _controller.addError(e);
        _scheduleReconnect();
      }, onDone: () {
        debugPrint('HttpSseStreamChannel SSE closed');
        _scheduleReconnect();
      });
    } catch (e) {
      debugPrint('HttpSseStreamChannel connect error: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    // Exponential backoff up to 30s
    final pow = _retries.clamp(0, 5);
    final seconds = 1 << pow; // 1,2,4,8,16,32
    final delay = Duration(seconds: seconds.clamp(1, 30));
    _retries++;
    debugPrint('HttpSseStreamChannel reconnect in ${delay.inSeconds}s');
    _reconnectTimer = Timer(delay, () {
      if (_disposed) return;
      _connectSse();
    });
  }

  void _onSseLine(String line) {
    if (line.startsWith('event:')) {
      _currentEvent = line.substring(6).trim();
      return;
    }
    if (line.startsWith('data:')) {
      final data = line.length >= 5 ? line.substring(5).replaceFirst(RegExp('^ '), '') : '';
      if (data.isNotEmpty && data != '[DONE]') {
        if (_eventData.isNotEmpty) _eventData.write('\n');
        _eventData.write(data);
      }
      return;
    }

    // Non-standard: session endpoint as a bare line
    final t = line.trim();
    if (t.startsWith('/sse?sessionid=') ||
        t.startsWith('/message?sessionId=') ||
        t.contains('sessionid=') ||
        t.contains('sessionId=')) {
      _setSessionEndpointFromData(t);
      return;
    }
  }

  void _finishEvent() {
    if (_eventData.isEmpty) return;
    final blob = _eventData.toString();
    _eventData.clear();
    final event = _currentEvent;
    _currentEvent = '';

    final data = blob.trim();
    if (data.isEmpty || data == '[DONE]') return;

    if (event == 'endpoint') {
      _setSessionEndpointFromData(data);
      return;
    }

    // Forward raw JSON payloads to the stream. If wrapped, try to unwrap first.
    if (data.startsWith('{') || data.startsWith('[')) {
      try {
        final decoded = jsonDecode(data);
        void forward(dynamic obj) {
          try {
            _controller.add(jsonEncode(obj));
          } catch (e) {
            debugPrint('HttpSseStreamChannel forward error: $e');
          }
        }

        dynamic unwrap(dynamic obj) {
          if (obj is Map<String, dynamic> && obj.containsKey('jsonrpc')) return obj;
          if (obj is Map<String, dynamic>) {
            for (final key in const ['data', 'message', 'payload']) {
              if (obj.containsKey(key)) {
                final inner = unwrap(obj[key]);
                if (inner != null) return inner;
              }
            }
          }
          if (obj is String) {
            final s = obj.trim();
            if (s.isNotEmpty && (s.startsWith('{') || s.startsWith('['))) {
              try {
                final inner = jsonDecode(s);
                return unwrap(inner) ?? inner;
              } catch (_) {}
            }
          }
          if (obj is List) return obj;
          return null;
        }

        final unwrapped = unwrap(decoded);
        if (unwrapped is List) {
          for (final item in unwrapped) {
            forward(item);
          }
        } else if (unwrapped != null) {
          forward(unwrapped);
        } else {
          forward(decoded);
        }
      } catch (e) {
        debugPrint('HttpSseStreamChannel JSON parse error: $e');
      }
    } else {
      // Might still carry session data
      if (data.contains('sessionid=') || data.contains('sessionId=')) {
        _setSessionEndpointFromData(data);
      }
    }
  }

  void _setSessionEndpointFromData(String data) {
    final trimmed = data.trim();
    if (trimmed.isEmpty) return;
    String? sid;
    try {
      Uri parsed;
      if (trimmed.startsWith('?') || trimmed.startsWith('/')) {
        parsed = Uri.parse('http://dummy$trimmed');
      } else if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        parsed = Uri.parse(trimmed);
      } else {
        parsed = Uri.parse('http://dummy?$trimmed');
      }
      final q = parsed.queryParameters;
      sid = q['sessionid'] ?? q['sessionId'];
      sid ??= RegExp(r'[?&](sessionid|sessionId)=([^&#\s]+)')
          .firstMatch(parsed.toString())
          ?.group(2);
    } catch (e) {
      debugPrint('HttpSseStreamChannel session parse error: $e');
    }
    if (sid == null || sid.isEmpty) return;

    final canonical = Uri(
      scheme: _baseUri.scheme,
      host: _baseUri.host,
      port: _baseUri.hasPort ? _baseUri.port : null,
      path: '/sse',
      queryParameters: {'sessionid': sid},
    );

    Uri preferred;
    if (trimmed.contains('/message') || trimmed.contains('sessionId=')) {
      preferred = Uri(
        scheme: _baseUri.scheme,
        host: _baseUri.host,
        port: _baseUri.hasPort ? _baseUri.port : null,
        path: '/message',
        queryParameters: {'sessionId': sid},
      );
    } else {
      preferred = canonical;
    }

    _preferredEndpoint = preferred;
    _canonicalEndpoint = preferred == canonical ? null : canonical;
    if (_sessionReady != null && !(_sessionReady!.isCompleted)) {
      _sessionReady!.complete(preferred);
    }
  }
}

class _HttpSseSink implements StreamSink<String> {
  final HttpSseStreamChannel _owner;
  _HttpSseSink(this._owner);

  bool _closed = false;
  // Queue messages until a session endpoint is available, then flush.
  final List<String> _pending = <String>[];
  bool _flushScheduled = false;

  @override
  void add(String data) {
    if (_closed) throw StateError('Sink is closed');
    _send(data);
  }

  Future<void> _send(String json) async {
    try {
      final endpoints = <Uri>[];
      // Wait for the server to emit the session endpoint via SSE. Do not
      // attempt to POST to endpoints that require a session until it exists.
      final session = await _owner.waitForSession();
      if (session != null) {
        endpoints.add(session);
        if (_owner.canonicalEndpoint != null) endpoints.add(_owner.canonicalEndpoint!);
      } else {
        // No session yet; avoid spamming gateways with POSTs that will 400.
        debugPrint('HttpSseStreamChannel session not ready; postponing send');
      }

      if (endpoints.isEmpty) {
        // Defer sending until session endpoint is available.
        debugPrint('HttpSseStreamChannel session not ready; queuing message');
        _pending.add(json);
        _scheduleFlush();
        return;
      }

      http.Response? response;
      for (final endpoint in endpoints) {
        try {
          debugPrint('HttpSseStreamChannel POST -> $endpoint');
          response = await _postWithRedirects(endpoint, json);
          if (response.statusCode >= 200 && response.statusCode < 300) {
            break;
          } else if (response.statusCode == 400) {
            debugPrint('POST 400: ${response.reasonPhrase}');
            debugPrint('Body: ${response.body}');
          } else if (response.statusCode != 404 && response.statusCode != 405) {
            debugPrint('POST failed ${response.statusCode} ${response.reasonPhrase}');
            if (response.body.isNotEmpty) debugPrint('Body: ${response.body}');
          }
        } catch (e) {
          debugPrint('HttpSseStreamChannel POST error: $e');
          continue;
        }
      }

      if (response == null || response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('HttpSseStreamChannel send failed to all endpoints');
      }
    } catch (e) {
      debugPrint('HttpSseStreamChannel send error: $e');
    }
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    _owner.waitForSession(timeout: const Duration(seconds: 15)).then((uri) async {
      _flushScheduled = false;
      if (uri == null || _closed) return;
      // Drain the queue now that session endpoint is available
      while (_pending.isNotEmpty && !_closed) {
        final payload = _pending.removeAt(0);
        await _send(payload);
      }
    }).catchError((_) {
      _flushScheduled = false;
    });
  }

  Future<http.Response> _postWithRedirects(Uri uri, String body, {int maxRedirects = 5}) async {
    var current = uri;
    var redirects = 0;
    while (redirects < maxRedirects) {
      final res = await _owner._client.post(
        current,
        headers: {
          'Content-Type': 'application/json',
          // Some gateways require Accept to advertise both JSON and SSE response capability
          'Accept': 'application/json, text/event-stream',
          ..._owner._headers,
        },
        body: body,
      );
      final setCookie = res.headers['set-cookie'];
      if (setCookie != null && setCookie.isNotEmpty) {
        _owner._cookieHeader = _owner._extractCookieHeader(setCookie);
      }
      if (res.statusCode == 307 || res.statusCode == 302 || res.statusCode == 301) {
        final loc = res.headers['location'];
        if (loc == null || loc.isEmpty) return res;
        Uri next;
        if (loc.startsWith('http://') || loc.startsWith('https://')) {
          next = Uri.parse(loc);
        } else if (loc.startsWith('/')) {
          next = Uri(
            scheme: current.scheme,
            host: current.host,
            port: current.port,
            path: loc,
          );
        } else {
          next = current.resolve(loc);
        }
        current = next;
        redirects++;
        continue;
      }
      return res;
    }
    throw Exception('Too many redirects');
  }

  @override
  void addError(error, [StackTrace? stackTrace]) {
    debugPrint('HttpSseStreamChannel sink error: $error');
  }

  @override
  Future addStream(Stream<String> stream) async {
    await for (final item in stream) {
      add(item);
    }
  }

  @override
  Future close() async {
    _closed = true;
  }

  @override
  Future get done async {}
}
