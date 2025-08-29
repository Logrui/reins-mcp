import 'dart:convert';
import 'package:reins/Models/mcp.dart';

// Generates a system prompt that describes the available tools to the model.
String generateToolSystemPrompt(List<McpTool> tools) {
  if (tools.isEmpty) {
    return 'You have no tools available.';
  }

  final toolDefinitions = tools.map((tool) {
    return {
      'name': tool.name,
      'description': tool.description,
      'parameters': tool.parameters,
    };
  }).toList();

  // This is a simplified JSON representation for the prompt.
  // A more robust implementation might use a dedicated JSON schema for tools.
  return '''You have access to the following tools. Use them when appropriate.

${jsonEncode(toolDefinitions)}
''';
}
