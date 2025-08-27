import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> main() async {
  print('=== Docker MCP Gateway Diagnostics ===\n');
  
  final baseUrl = 'http://localhost:7999';
  final client = http.Client();
  
  // Test if the gateway is running at all
  print('1. Testing basic connectivity...');
  final basicEndpoints = [
    '$baseUrl/',
    '$baseUrl/health',
    '$baseUrl/status',
    '$baseUrl/ping',
  ];
  
  bool gatewayRunning = false;
  for (final endpoint in basicEndpoints) {
    try {
      final response = await client.get(Uri.parse(endpoint)).timeout(Duration(seconds: 3));
      print('   $endpoint -> ${response.statusCode}');
      if (response.statusCode < 500) {
        gatewayRunning = true;
        if (response.body.isNotEmpty && response.body.length < 500) {
          print('     Body: ${response.body}');
        }
      }
    } catch (e) {
      print('   $endpoint -> Failed: $e');
    }
  }
  
  if (!gatewayRunning) {
    print('\n❌ Gateway appears to be down or not accessible at localhost:7999');
    print('   Please check:');
    print('   - Is the Docker container running?');
    print('   - Is it bound to port 7999?');
    print('   - Are there any firewall issues?');
    client.close();
    return;
  }
  
  print('\n2. Testing SSE endpoint patterns...');
  final sseEndpoints = [
    '$baseUrl/sse',
    '$baseUrl/events',
    '$baseUrl/stream',
    '$baseUrl/mcp/sse',
    '$baseUrl/api/sse',
  ];
  
  for (final endpoint in sseEndpoints) {
    try {
      final request = http.Request('GET', Uri.parse(endpoint));
      request.headers.addAll({
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      });
      
      final streamedResponse = await client.send(request).timeout(Duration(seconds: 3));
      print('   $endpoint -> ${streamedResponse.statusCode}');
      
      if (streamedResponse.statusCode == 200) {
        print('     ✅ SSE endpoint found!');
        // Try to read a few bytes to see if it's actually streaming
        try {
          final stream = streamedResponse.stream.timeout(Duration(seconds: 2));
          await for (final chunk in stream.take(1)) {
            final text = String.fromCharCodes(chunk);
            print('     First chunk: ${text.substring(0, text.length > 100 ? 100 : text.length)}...');
            break;
          }
        } catch (e) {
          print('     Stream test failed: $e');
        }
      }
    } catch (e) {
      print('   $endpoint -> Failed: $e');
    }
  }
  
  print('\n3. Testing JSON-RPC endpoint patterns...');
  final rpcEndpoints = [
    baseUrl,
    '$baseUrl/rpc',
    '$baseUrl/jsonrpc',
    '$baseUrl/mcp',
    '$baseUrl/api',
    '$baseUrl/api/rpc',
    '$baseUrl/mcp/rpc',
  ];
  
  final testPayload = {
    'jsonrpc': '2.0',
    'method': 'initialize',
    'id': 'diagnostic-test',
    'params': {
      'clientInfo': {'name': 'Diagnostic', 'version': '1.0'},
      'protocolVersion': '2024-11-05',
      'capabilities': {},
    },
  };
  
  for (final endpoint in rpcEndpoints) {
    try {
      final response = await client.post(
        Uri.parse(endpoint),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(testPayload),
      ).timeout(Duration(seconds: 5));
      
      print('   $endpoint -> ${response.statusCode}');
      if (response.statusCode != 404 && response.body.isNotEmpty) {
        print('     Body: ${response.body}');
        
        // Try to parse as JSON-RPC response
        try {
          final jsonResponse = jsonDecode(response.body);
          if (jsonResponse is Map && jsonResponse.containsKey('jsonrpc')) {
            print('     ✅ Valid JSON-RPC response!');
            if (jsonResponse.containsKey('result')) {
              print('     Result: ${jsonResponse['result']}');
            }
            if (jsonResponse.containsKey('error')) {
              print('     Error: ${jsonResponse['error']}');
            }
          }
        } catch (e) {
          print('     Not valid JSON-RPC: $e');
        }
      }
    } catch (e) {
      print('   $endpoint -> Failed: $e');
    }
  }
  
  print('\n4. Testing alternative HTTP methods...');
  final methods = ['PUT', 'PATCH'];
  for (final method in methods) {
    try {
      final request = http.Request(method, Uri.parse(baseUrl));
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(testPayload);
      
      final response = await client.send(request).timeout(Duration(seconds: 3));
      print('   $method $baseUrl -> ${response.statusCode}');
    } catch (e) {
      print('   $method $baseUrl -> Failed: $e');
    }
  }
  
  print('\n=== Diagnostic Complete ===');
  print('If no working endpoints were found, please check your Docker MCP gateway configuration.');
  print('Common issues:');
  print('- Gateway not running or crashed');
  print('- Port binding issues (check docker ps)');
  print('- Different port or host configuration');
  print('- Authentication required');
  
  client.close();
}
