import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:reins/Models/ollama_message.dart';
import 'package:reins/Providers/chat_provider.dart';

class ToolCallMessage extends StatelessWidget {
  final OllamaMessage message;

  const ToolCallMessage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final toolCall = message.toolCall;
    final toolResult = message.toolResult;

    if (toolCall == null) {
      return const SizedBox.shrink();
    }

    // While the tool is running, show a spinner and cancel button.
    if (toolResult == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      ),
                      SizedBox(width: 8),
                      Text('Executing Tool...', style: TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Provider.of<ChatProvider>(context, listen: false).cancelToolCall(message.id);
                    },
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Server: ${toolCall.server}'),
              Text('Tool: ${toolCall.name}'),
              Text('Arguments: ${toolCall.args}'),
            ],
          ),
        ),
      );
    }

    // Once the result is available, show the formatted content.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Tool Result', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(message.content),
          ],
        ),
      ),
    );
  }
}
