import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

Future<void> main() async {
  debugPrint('=== Docker MCP Gateway Diagnostics ===\n');
  
  final baseUrl = 'http://localhost:7999';
  final client = http.Client();
  
  // Test if the gateway is running at all
  debugPrint('1. Testing basic connectivity...');
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
      debugPrint('   $endpoint -> ${response.statusCode}');
      if (response.statusCode < 500) {
        gatewayRunning = true;
        if (response.body.isNotEmpty && response.body.length < 500) {
          debugPrint('     Body: ${response.body}');
        }
      }
    } catch (e) {
      debugPrint('   $endpoint -> Failed: $e');
    }
  }
  
  if (!gatewayRunning) {
    debugPrint('\n❌ Gateway appears to be down or not accessible at localhost:7999');
    debugPrint('   Please check:');
    debugPrint('   - Is the Docker container running?');
    debugPrint('   - Is it bound to port 7999?');
    debugPrint('   - Are there any firewall issues?');
    client.close();
    return;
  }
  
  debugPrint('\n2. Testing SSE endpoint patterns...');
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
      debugPrint('   $endpoint -> ${streamedResponse.statusCode}');
      
      if (streamedResponse.statusCode == 200) {
        debugPrint('     ✅ SSE endpoint found!');
        // Try to read a few bytes to see if it's actually streaming
        try {
          final stream = streamedResponse.stream.timeout(Duration(seconds: 2));
          await for (final chunk in stream.take(1)) {
            final text = String.fromCharCodes(chunk);
            debugPrint('     First chunk: ${text.substring(0, text.length > 100 ? 100 : text.length)}...');
            break;
          }
        } catch (e) {
          debugPrint('     Stream test failed: $e');
        }
      }
    } catch (e) {
      debugPrint('   $endpoint -> Failed: $e');
    }
  }
  
  debugPrint('\n3. Testing JSON-RPC endpoint patterns...');
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
      
      debugPrint('   $endpoint -> ${response.statusCode}');
      if (response.statusCode != 404 && response.body.isNotEmpty) {
        debugPrint('     Body: ${response.body}');
        
        // Try to parse as JSON-RPC response
        try {
          final jsonResponse = jsonDecode(response.body);
          if (jsonResponse is Map && jsonResponse.containsKey('jsonrpc')) {
            debugPrint('     ✅ Valid JSON-RPC response!');
            if (jsonResponse.containsKey('result')) {
              debugPrint('     Result: ${jsonResponse['result']}');
            }
            if (jsonResponse.containsKey('error')) {
              debugPrint('     Error: ${jsonResponse['error']}');
            }
          }
        } catch (e) {
          debugPrint('     Not valid JSON-RPC: $e');
        }
      }
    } catch (e) {
      debugPrint('   $endpoint -> Failed: $e');
    }
  }
  
  debugPrint('\n4. Testing alternative HTTP methods...');
  final methods = ['PUT', 'PATCH'];
  for (final method in methods) {
    try {
      final request = http.Request(method, Uri.parse(baseUrl));
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(testPayload);
      
      final response = await client.send(request).timeout(Duration(seconds: 3));
      debugPrint('   $method $baseUrl -> ${response.statusCode}');
    } catch (e) {
      debugPrint('   $method $baseUrl -> Failed: $e');
    }
  }
  
  debugPrint('\n=== Diagnostic Complete ===');
  debugPrint('If no working endpoints were found, please check your Docker MCP gateway configuration.');
  debugPrint('Common issues:');
  debugPrint('- Gateway not running or crashed');
  debugPrint('- Port binding issues (check docker ps)');
  debugPrint('- Different port or host configuration');
  debugPrint('- Authentication required');
  
  client.close();
}
