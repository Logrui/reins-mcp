import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> main() async {
  print('Testing MCP connection to Docker gateway...');
  
  final baseUrl = 'http://localhost:7999';
  final sseEndpoint = '$baseUrl/sse';
  final possibleRpcEndpoints = [
    baseUrl,           // Root endpoint
    '$baseUrl/mcp',    // Common MCP endpoint
    '$baseUrl/rpc',    // RPC endpoint
    '$baseUrl/api',    // API endpoint
    '$baseUrl/jsonrpc', // JSON-RPC endpoint
  ];
  
  try {
    print('Testing SSE endpoint: $sseEndpoint...');
    
    final client = http.Client();
    
    // Test SSE endpoint with GET
    try {
      final response = await client.get(Uri.parse(sseEndpoint)).timeout(Duration(seconds: 5));
      print('✅ SSE GET response: ${response.statusCode}');
      if (response.headers.containsKey('content-type')) {
        print('   Content-Type: ${response.headers['content-type']}');
      }
    } catch (e) {
      print('❌ SSE GET failed: $e');
    }
    
    // Find the correct RPC endpoint
    String? workingRpcEndpoint;
    for (final endpoint in possibleRpcEndpoints) {
      print('\\nTesting RPC endpoint: $endpoint...');
      try {
        final response = await client.post(
          Uri.parse(endpoint),
          headers: {'Content-Type': 'application/json'},
          body: '{"jsonrpc":"2.0","method":"ping","id":"test"}',
        ).timeout(Duration(seconds: 3));
        
        print('   Response: ${response.statusCode}');
        if (response.statusCode != 404) {
          workingRpcEndpoint = endpoint;
          print('✅ Found working RPC endpoint: $endpoint');
          break;
        }
      } catch (e) {
        print('   Failed: $e');
      }
    }
    
    if (workingRpcEndpoint == null) {
      print('❌ Could not find working RPC endpoint');
      client.close();
      return;
    }
    
    // Test MCP initialize call
    print('\nTesting MCP initialize...');
    final initializePayload = {
      'jsonrpc': '2.0',
      'method': 'initialize',
      'id': 'test-1',
      'params': {
        'clientInfo': {
          'name': 'Reins-Test',
          'version': '0.1.0',
        },
        'protocolVersion': '2024-11-05',
        'capabilities': {},
      },
    };
    
    try {
      final response = await client.post(
        Uri.parse(workingRpcEndpoint),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'text/event-stream, application/x-ndjson, application/json',
        },
        body: jsonEncode(initializePayload),
      ).timeout(Duration(seconds: 10));
      
      print('✅ Initialize response: ${response.statusCode}');
      print('   Response body: ${response.body}');
      
      if (response.statusCode == 200) {
        try {
          final responseData = jsonDecode(response.body);
          if (responseData['error'] == null) {
            print('✅ MCP initialize successful!');
          } else {
            print('❌ MCP initialize error: ${responseData['error']}');
          }
        } catch (e) {
          print('⚠️  Could not parse response as JSON: $e');
        }
      }
    } catch (e) {
      print('❌ Initialize request failed: $e');
    }
    
    // Test tools/list call
    print('\nTesting tools/list...');
    final toolsPayload = {
      'jsonrpc': '2.0',
      'method': 'tools/list',
      'id': 'test-2',
      'params': {},
    };
    
    try {
      final response = await client.post(
        Uri.parse(workingRpcEndpoint),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(toolsPayload),
      ).timeout(Duration(seconds: 10));
      
      print('✅ Tools/list response: ${response.statusCode}');
      print('   Response body: ${response.body}');
      
      if (response.statusCode == 200) {
        try {
          final responseData = jsonDecode(response.body);
          if (responseData['error'] == null && responseData['result'] != null) {
            final result = responseData['result'];
            if (result is Map && result.containsKey('tools')) {
              final tools = result['tools'] as List;
              print('✅ Found ${tools.length} tools');
              for (final tool in tools) {
                if (tool is Map && tool.containsKey('name')) {
                  print('   - ${tool['name']}: ${tool['description'] ?? 'No description'}');
                }
              }
            } else if (result is List) {
              print('✅ Found ${result.length} tools (direct list)');
              for (final tool in result) {
                if (tool is Map && tool.containsKey('name')) {
                  print('   - ${tool['name']}: ${tool['description'] ?? 'No description'}');
                }
              }
            } else {
              print('⚠️  Unexpected tools result format: $result');
            }
          } else {
            print('❌ Tools/list error: ${responseData['error']}');
          }
        } catch (e) {
          print('⚠️  Could not parse tools response as JSON: $e');
        }
      }
    } catch (e) {
      print('❌ Tools/list request failed: $e');
    }
    
    client.close();
    
  } catch (e, stackTrace) {
    print('❌ Exception occurred: $e');
    print('Stack trace: $stackTrace');
  }
  
  print('\nTest completed.');
}
