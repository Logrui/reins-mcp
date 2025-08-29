import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:reins/Services/mcp_service.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

void main() {
  group('McpService (in-memory Peer)', () {
    late McpService service;
    late rpc.Server server;
    late rpc.Peer clientPeer;
    late StreamChannelController<String> controller;

    setUp(() async {
      service = McpService();

      // Create an in-memory bidirectional channel
      controller = StreamChannelController<String>();

      // Server listens on one end
      server = rpc.Server(controller.local);

      // Register minimal MCP methods
      server.registerMethod('initialize', (params) async {
        return {
          'capabilities': {
            'tools': {},
          }
        };
      });

      server.registerMethod('tools/list', (params) async {
        return {
          'tools': [
            {
              'name': 'echo',
              'description': 'Echoes text',
              'parameters': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string'}
                }
              }
            },
          ]
        };
      });

      server.registerMethod('tools/call', (rpc.Parameters params) async {
        final name = params['name'].asString;
        final args = Map<String, dynamic>.from(params['arguments'].asMap);
        if (name == 'echo') {
          return {'text': args['text']};
        }
        throw rpc.RpcException(-32601, 'Tool not found');
      });

      // Start server
      unawaited(server.listen());

      // Client peer on the opposite end (service will call listen())
      clientPeer = rpc.Peer(controller.foreign);

      // Attach to service using the test seam and initialize
      await service.attachPeerAndInitialize('inmemory://server', clientPeer);
    });

    tearDown(() async {
      await clientPeer.close();
      await server.close();
      // Close the controller sinks/streams
      await controller.local.sink.close();
      await controller.foreign.sink.close();
    });

    test('connect + listTools caches server tools', () async {
      final tools = await service.listTools(server: 'inmemory://server');
      expect(tools, isNotEmpty);
      expect(tools.any((t) => t.name == 'echo'), isTrue);
    });

    test('call echo tool returns result', () async {
      final result = await service.call('inmemory://server', 'echo', {'text': 'hello'});
      expect(result.error, isNull);
      expect(result.result, isA<Map>());
      expect((result.result as Map)['text'], 'hello');
    });

    test('call unknown tool returns error', () async {
      final result = await service.call('inmemory://server', 'unknown', {});
      expect(result.error, isNotNull);
    });
  });
}
