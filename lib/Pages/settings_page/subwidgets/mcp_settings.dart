import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:reins/Models/mcp.dart';
import 'package:reins/Services/mcp_service.dart';

class McpServersSettings extends StatefulWidget {
  const McpServersSettings({super.key});

  @override
  State<McpServersSettings> createState() => _McpServersSettingsState();
}

class _McpServersSettingsState extends State<McpServersSettings> {
  late final Box _settingsBox;
  late List<_EditableServer> _servers;

  @override
  void initState() {
    super.initState();
    _settingsBox = Hive.box('settings');
    _load();
  }

  void _load() {
    final raw = _settingsBox.get('mcpServers', defaultValue: <dynamic>[]);
    _servers = (raw as List)
        .whereType<Map>()
        .map((m) => McpServerConfig.fromJson(m.cast<String, dynamic>()))
        .map((cfg) => _EditableServer.fromConfig(cfg))
        .toList();
    setState(() {});
  }

  String _deriveNameFromEndpoint(String endpoint) {
    try {
      final uri = Uri.parse(endpoint);
      if (uri.host.isNotEmpty) return uri.host;
    } catch (_) {}
    // Fallback: trim protocol if present
    return endpoint
        .replaceFirst(RegExp(r'^ws?://'), '')
        .split('/')
        .first;
  }

  Future<void> _saveAndReconnect() async {
    final mcpService = context.read<McpService>();
    final list = _servers
        .where((e) => e.endpointController.text.trim().isNotEmpty)
        .map((e) => McpServerConfig(
              name: (e.nameController.text.trim().isNotEmpty)
                  ? e.nameController.text.trim()
                  : _deriveNameFromEndpoint(e.endpointController.text.trim()),
              endpoint: e.endpointController.text.trim(),
              authToken: e.tokenController.text.trim().isEmpty
                  ? null
                  : e.tokenController.text.trim(),
            ).toJson())
        .toList();
    await _settingsBox.put('mcpServers', list);

    // Reconnect sequence
    await mcpService.disconnectAll();
    if (list.isNotEmpty) {
      final configs = list
          .map((m) => McpServerConfig.fromJson(
              (m as Map).cast<String, dynamic>()))
          .toList();
      await mcpService.connectAll(configs);
      await mcpService.listTools();
    }
    if (mounted) setState(() {});
  }

  void _addServer() {
    setState(() {
      _servers.add(_EditableServer());
    });
  }

  void _removeAt(int index) {
    setState(() {
      _servers.removeAt(index);
    });
    _saveAndReconnect();
  }

  Widget _statusChipForUrl(BuildContext context, String serverUrl) {
    final mcpService = context.read<McpService>();
    return StreamBuilder<Map<String, McpConnectionState>>(
      stream: mcpService.connectionStates(),
      initialData: const {},
      builder: (context, snapshot) {
        final stateMap = snapshot.data ?? const {};
        final state = stateMap[serverUrl] ??
            (mcpService.isConnected(serverUrl)
                ? McpConnectionState.connected
                : McpConnectionState.disconnected);

        Color color;
        String label;
        switch (state) {
          case McpConnectionState.connecting:
            color = Colors.amber;
            label = 'Connecting';
            break;
          case McpConnectionState.connected:
            color = Colors.green;
            label = 'Connected';
            break;
          case McpConnectionState.error:
            color = Colors.red;
            label = 'Error';
            break;
          case McpConnectionState.disconnected:
            color = Colors.grey;
            label = 'Disconnected';
        }

        return Chip(
          label: Text(label),
          backgroundColor: color.withOpacity(0.15),
          side: BorderSide(color: color.withOpacity(0.6)),
          avatar: CircleAvatar(backgroundColor: color, radius: 6),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        );
      },
    );
  }

  void _showToolsDialog(BuildContext context, String serverUrl) {
    final mcpService = context.read<McpService>();
    final tools = mcpService.getTools(serverUrl);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Tools for $serverUrl'),
          content: SizedBox(
            width: 500,
            child: tools.isEmpty
                ? const Text('No tools available (not connected or server returned none).')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: tools.length,
                    itemBuilder: (context, i) {
                      final t = tools[i];
                      return ListTile(
                        dense: true,
                        title: Text(t.name),
                        subtitle: Text(
                          t.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.build_outlined, size: 18),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MCP Servers',
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Add WebSocket endpoints to enable tools via Model Context Protocol. Use ws:// for production/web.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < _servers.length; i++) _buildServerRow(i),
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: _addServer,
              icon: const Icon(Icons.add),
              label: const Text('Add Server'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _saveAndReconnect,
              icon: const Icon(Icons.save),
              label: const Text('Save & Reconnect'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildServerRow(int index) {
    final item = _servers[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: TextField(
              controller: item.nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {},
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: TextField(
              controller: item.endpointController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Endpoint (ws://host:port/path)',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {},
            ),
          ),
          const SizedBox(width: 8),
          // Status + Tools cluster
          Builder(builder: (context) {
            final serverUrl = item.endpointController.text.trim();
            final mcpService = context.watch<McpService>();
            final toolsCount = serverUrl.isEmpty ? 0 : mcpService.getTools(serverUrl).length;
            return ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (serverUrl.isNotEmpty)
                    _statusChipForUrl(context, serverUrl)
                  else
                    const Chip(
                      label: Text('No URL'),
                      visualDensity: VisualDensity.compact,
                    ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Tools: $toolsCount'),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: serverUrl.isEmpty
                            ? null
                            : () => _showToolsDialog(context, serverUrl),
                        icon: const Icon(Icons.list_alt_outlined, size: 16),
                        label: const Text('View'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: item.tokenController,
              decoration: const InputDecoration(
                labelText: 'Auth token (optional)',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {},
              obscureText: true,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Remove',
            onPressed: () => _removeAt(index),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _EditableServer {
  final TextEditingController nameController;
  final TextEditingController endpointController;
  final TextEditingController tokenController;

  _EditableServer()
      : nameController = TextEditingController(),
        endpointController = TextEditingController(),
        tokenController = TextEditingController();

  factory _EditableServer.fromConfig(McpServerConfig cfg) {
    final e = _EditableServer();
    e.nameController.text = cfg.name;
    e.endpointController.text = cfg.endpoint;
    if (cfg.authToken != null) e.tokenController.text = cfg.authToken!;
    return e;
  }
}
