import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> main() async {
  print('=== Testing MCP Gateway at localhost:7999 ===\n');
  
  final baseUrl = 'http://localhost:7999';
  final client = http.Client();
  
  // Test MCP initialize with redirect following
  print('1. Testing MCP initialize with redirect following...');
  final initializePayload = {
    'jsonrpc': '2.0',
    'method': 'initialize',
    'id': 'test-init',
    'params': {
      'clientInfo': {'name': 'Reins-Test', 'version': '0.1.0'},
      'protocolVersion': '2024-11-05',
      'capabilities': {},
    },
  };
  
  final endpoints = [baseUrl, '$baseUrl/mcp', '$baseUrl/api'];
  
  for (final endpoint in endpoints) {
    print('\\nTesting: $endpoint');
    try {
      final response = await client.post(
        Uri.parse(endpoint),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(initializePayload),
      ).timeout(Duration(seconds: 10));
      
      print('   Status: ${response.statusCode}');
      
      if (response.statusCode == 307) {
        final location = response.headers['location'];
        print('   Redirect to: $location');
        
        if (location != null) {
          try {
            final redirectUri = location.startsWith('http') 
                ? Uri.parse(location)
                : Uri.parse('$baseUrl$location');
            
            print('   Following redirect to: $redirectUri');
            final redirectResponse = await client.post(
              redirectUri,
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode(initializePayload),
            ).timeout(Duration(seconds: 10));
            
            print('   Redirect response: ${redirectResponse.statusCode}');
            if (redirectResponse.body.isNotEmpty) {
              print('   Body: ${redirectResponse.body}');
              
              try {
                final jsonResp = jsonDecode(redirectResponse.body);
                if (jsonResp is Map && jsonResp.containsKey('jsonrpc')) {
                  print('   ✅ Valid JSON-RPC response!');
                  if (jsonResp.containsKey('result')) {
                    print('   Initialize successful!');
                    
                    // Test tools/list on the same endpoint
                    await testToolsList(client, redirectUri);
                  }
                }
              } catch (e) {
                print('   JSON parse error: $e');
              }
            }
          } catch (e) {
            print('   Redirect failed: $e');
          }
        }
      } else if (response.statusCode == 200) {
        print('   Body: ${response.body}');
        try {
          final jsonResp = jsonDecode(response.body);
          if (jsonResp is Map && jsonResp.containsKey('jsonrpc')) {
            print('   ✅ Direct JSON-RPC response!');
            if (jsonResp.containsKey('result')) {
              print('   Initialize successful!');
              await testToolsList(client, Uri.parse(endpoint));
            }
          }
        } catch (e) {
          print('   JSON parse error: $e');
        }
      } else {
        print('   Body: ${response.body}');
      }
    } catch (e) {
      print('   Failed: $e');
    }
  }
  
  // Test the session-based message endpoint pattern
  print('\\n2. Testing session-based message endpoint...');
  try {
    // First get a session from SSE endpoint
    final sseResponse = await client.get(Uri.parse('$baseUrl/sse')).timeout(Duration(seconds: 3));
    if (sseResponse.statusCode == 200) {
      final sseData = sseResponse.body;
      final sessionMatch = RegExp(r'sessionId=([a-f0-9-]+)').firstMatch(sseData);
      if (sessionMatch != null) {
        final sessionId = sessionMatch.group(1);
        print('   Found session ID: $sessionId');
        
        final messageEndpoint = '$baseUrl/message?sessionId=$sessionId';
        print('   Testing message endpoint: $messageEndpoint');
        
        final msgResponse = await client.post(
          Uri.parse(messageEndpoint),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(initializePayload),
        ).timeout(Duration(seconds: 10));
        
        print('   Message endpoint status: ${msgResponse.statusCode}');
        print('   Response: ${msgResponse.body}');
        
        if (msgResponse.statusCode == 200) {
          try {
            final jsonResp = jsonDecode(msgResponse.body);
            if (jsonResp is Map && jsonResp.containsKey('jsonrpc')) {
              print('   ✅ Session-based JSON-RPC works!');
              await testToolsList(client, Uri.parse(messageEndpoint));
            }
          } catch (e) {
            print('   JSON parse error: $e');
          }
        }
      }
    }
  } catch (e) {
    print('   Session test failed: $e');
  }
  
  client.close();
  print('\\n=== Test Complete ===');
}

Future<void> testToolsList(http.Client client, Uri endpoint) async {
  print('\\n   Testing tools/list on $endpoint...');
  final toolsPayload = {
    'jsonrpc': '2.0',
    'method': 'tools/list',
    'id': 'test-tools',
    'params': {},
  };
  
  try {
    final response = await client.post(
      endpoint,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(toolsPayload),
    ).timeout(Duration(seconds: 10));
    
    print('   Tools/list status: ${response.statusCode}');
    print('   Response: ${response.body}');
    
    if (response.statusCode == 200) {
      try {
        final jsonResp = jsonDecode(response.body);
        if (jsonResp is Map && jsonResp['result'] != null) {
          final result = jsonResp['result'];
          if (result is Map && result.containsKey('tools')) {
            final tools = result['tools'] as List;
            print('   ✅ Found ${tools.length} tools!');
            for (final tool in tools.take(3)) {
              if (tool is Map) {
                print('     - ${tool['name']}: ${tool['description'] ?? 'No description'}');
              }
            }
          } else if (result is List) {
            print('   ✅ Found ${result.length} tools (direct list)!');
            for (final tool in result.take(3)) {
              if (tool is Map) {
                print('     - ${tool['name']}: ${tool['description'] ?? 'No description'}');
              }
            }
          }
        }
      } catch (e) {
        print('   Tools JSON parse error: $e');
      }
    }
  } catch (e) {
    print('   Tools/list failed: $e');
  }
}
