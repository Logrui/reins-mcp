import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:reins/Models/mcp.dart';

// Sentinels used in the transcript
const String kToolCallPrefix = 'TOOL_CALL:';
const String kToolResultPrefix = 'TOOL_RESULT:';

// Detects and parses the first TOOL_CALL in the provided text buffer.
// Returns null if not found or invalid JSON.
McpToolCall? parseToolCall(String text) {
  final idx = text.indexOf(kToolCallPrefix);
  if (idx == -1) return null;
  final jsonString = text.substring(idx + kToolCallPrefix.length).trim();
  try {
    final obj = jsonDecode(jsonString);
    if (obj is Map<String, dynamic>) {
      return McpToolCall.fromJson(obj);
    }
  } catch (e) {
    debugPrint('Failed to parse TOOL_CALL JSON: $e');
  }
  return null;
}

// Formats a tool result line for the transcript
String formatToolResult(String toolName, dynamic result, {String? error}) {
  final payload = <String, dynamic>{
    'name': toolName,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
  };
  return '$kToolResultPrefix ${jsonEncode(payload)}';
}
