import 'package:reins/Models/mcp.dart';

const String toolSystemPromptPrefix = '''
You can call external tools when needed.

When you need a tool, output exactly one line in this format and nothing else:
TOOL_CALL: {"server": "<server>", "name": "<tool>", "args": { /* json args */ }}

Example:
TOOL_CALL: {"server": "local", "name": "calculator", "args": {"expression": "2+2"}}

After execution, you'll receive a line starting with `TOOL_RESULT:` containing a JSON object with `name`, and either `result` or `error`. Use it to finalize your answer.

Available tools:
''';

String generateToolSystemPrompt(Map<String, List<McpTool>> serverTools) {
  final prompt = StringBuffer(toolSystemPromptPrefix);

  if (serverTools.isEmpty) {
    prompt.writeln('  - No tools available.');
    return prompt.toString();
  }

  serverTools.forEach((server, tools) {
    prompt.writeln('Server: `$server`');
    if (tools.isEmpty) {
      prompt.writeln('  - No tools available on this server.');
    } else {
      for (var tool in tools) {
        prompt.writeln('  - `${tool.name}`: ${tool.description}');
        prompt.writeln('    Args schema: ${tool.parameters}');
      }
    }
  });

  return prompt.toString();
}
