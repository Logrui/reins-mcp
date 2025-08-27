import 'package:flutter/foundation.dart';
import 'package:reins/Services/mcp_service.dart';
import 'package:reins/Models/mcp.dart';

// Mock the debugPrint function for standalone testing
void debugPrint(String? message, {int? wrapWidth}) {
  print(message ?? '');
}

Future<void> main() async {
  print('=== Testing Reins MCP Service with Docker Gateway ===\n');
  
  final mcpService = McpService();
  
  try {
    // Test connection to Docker MCP gateway at port 7999
    final config = McpServerConfig(
      name: 'docker-gateway-7999',
      endpoint: 'http://localhost:7999/sse',
    );
    
    print('1. Connecting to ${config.endpoint}...');
    await mcpService.connect(config.endpoint);
    
    // Wait for connection to establish
    await Future.delayed(Duration(seconds: 3));
    
    if (mcpService.isConnected(config.endpoint)) {
      print('✅ Connected successfully!');
      
      // Test initialize
      print('\n2. Testing MCP initialize...');
      // The initialize is called automatically during connect
      
      // List available tools
      print('\n3. Fetching tools...');
      final tools = await mcpService.listTools(server: config.endpoint);
      
      if (tools.isNotEmpty) {
        print('✅ Found ${tools.length} tools:');
        for (final tool in tools.take(5)) {
          print('  - ${tool.name}: ${tool.description}');
          if (tool.parameters.isNotEmpty) {
            print('    Parameters: ${tool.parameters.keys.join(', ')}');
          }
        }
        
        // Test calling a tool if available
        if (tools.isNotEmpty) {
          print('\n4. Testing tool call...');
          final firstTool = tools.first;
          try {
            final result = await mcpService.call(
              config.endpoint,
              firstTool.name,
              {}, // Empty args for test
              timeout: Duration(seconds: 10),
            );
            
            if (result.error != null) {
              print('⚠️  Tool call returned error: ${result.error}');
            } else {
              print('✅ Tool call successful!');
              print('   Result: ${result.result}');
            }
          } catch (e) {
            print('❌ Tool call failed: $e');
          }
        }
      } else {
        print('⚠️  No tools found');
      }
    } else {
      print('❌ Failed to connect');
      final error = mcpService.getLastError(config.endpoint);
      if (error != null) {
        print('Error: $error');
      }
    }
    
  } catch (e, stackTrace) {
    print('❌ Exception occurred: $e');
    print('Stack trace: $stackTrace');
  } finally {
    await mcpService.disconnectAll();
    print('\n=== Test completed ===');
  }
}
