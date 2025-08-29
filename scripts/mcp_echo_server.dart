// Minimal MCP Echo Server over WebSocket
// Usage: dart run scripts/mcp_echo_server.dart [port] [--verbose|-v]
// Default port: 8787
// Endpoint to configure in Reins settings: ws://127.0.0.1:8787

import 'dart:convert';
import 'dart:io';

class JsonRpcRequest {
  final dynamic id;
  final String method;
  final Map<String, dynamic>? params;
  JsonRpcRequest(this.id, this.method, this.params);
}

Future<void> main(List<String> args) async {
  // Parse args: first int-like arg is port; --verbose or -v enables logs
  final verbose = args.contains('--verbose') || args.contains('-v');
  int? parsedPort;
  for (final a in args) {
    final p = int.tryParse(a);
    if (p != null) {
      parsedPort = p;
      break;
    }
  }
  final port = parsedPort ?? 8787;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  print('MCP Echo Server listening on ws://127.0.0.1:$port');
  if (verbose) {
    print('[server] verbose logging enabled');
  }

  await for (final req in server) {
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      WebSocket socket;
      final remote = '${req.connectionInfo?.remoteAddress.address}:${req.connectionInfo?.remotePort}';
      try {
        socket = await WebSocketTransformer.upgrade(req);
      } catch (e) {
        req.response
          ..statusCode = HttpStatus.badRequest
          ..write('WebSocket upgrade failed: $e')
          ..close();
        continue;
      }

      if (verbose) {
        print('[conn $remote] WebSocket upgraded');
      }

      socket.listen((data) async {
        try {
          if (verbose) {
            final preview = data is String && data.length > 400 ? '${data.substring(0, 400)}…' : '$data';
            print('[conn $remote] <= frame: $preview');
          }
          final obj = data is String ? jsonDecode(data) : data;
          if (obj is Map<String, dynamic>) {
            await _handleRpc(socket, obj, verbose: verbose, tag: 'conn $remote');
          }
        } catch (e) {
          // Ignore malformed frames to keep server alive
          if (verbose) {
            print('[conn $remote] frame parse error: $e');
          }
        }
      }, onDone: () {
        if (verbose) {
          print('[conn $remote] closed');
        }
      }, onError: (e) {
        if (verbose) {
          print('[conn $remote] error: $e');
        }
      });
    } else {
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.text
        ..write('MCP Echo Server is running. Connect via WebSocket.')
        ..close();
    }
  }
}

Future<void> _handleRpc(WebSocket socket, Map<String, dynamic> msg, {bool verbose = false, String tag = 'rpc'}) async {
  final id = msg['id'];
  final method = msg['method'] as String?;
  final params = (msg['params'] is Map) ? (msg['params'] as Map).cast<String, dynamic>() : null;

  if (method == null) return;

  if (verbose) {
    final p = params == null ? '{}' : jsonEncode(params);
    print('[$tag] <= method: $method id: $id params: $p');
  }

  Future<void> respondOk(dynamic result) async {
    final reply = {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    final enc = jsonEncode(reply);
    if (verbose) {
      final preview = enc.length > 400 ? '${enc.substring(0, 400)}…' : enc;
      print('[$tag] => result: $preview');
    }
    socket.add(enc);
  }

  Future<void> respondErr(int code, String message, [dynamic data]) async {
    final reply = {
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    };
    final enc = jsonEncode(reply);
    if (verbose) {
      print('[$tag] => error: code=$code message=$message');
    }
    socket.add(enc);
  }

  switch (method) {
    case 'initialize':
      await respondOk({
        'protocolVersion': '2024-11-05',
        'capabilities': {
          'tools': {},
          'roots': {'listChanged': true},
          'sampling': {},
        },
        'serverInfo': {'name': 'EchoServer', 'version': '0.1.0'},
      });
      break;

    case 'tools/list':
      await respondOk({
        'tools': [
          {
            'name': 'echo',
            'description': 'Echo back the provided arguments',
            'parameters': {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
              },
              'required': ['text'],
            },
          },
        ],
      });
      break;

    case 'tools/call':
      final name = params?['name'];
      final arguments = params?['arguments'];
      if (name == 'echo') {
        await respondOk({'text': arguments?['text']});
      } else {
        await respondErr(-32601, 'Unknown tool: $name');
      }
      break;

    default:
      // Optional: respond to ping when client heartbeats using $/ping
      if (method == r'$/ping') {
        await respondOk({'ok': true});
      } else {
        await respondErr(-32601, 'Method not found');
      }
  }
}
