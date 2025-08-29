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
  bool _hasUnsavedChanges = false;
  late final Box _settingsBox;
  late List<_EditableServer> _servers;

  @override
  void initState() {
    super.initState();
    _settingsBox = Hive.box('settings');
    _load();
    // Add a listener to each server to track changes for the save button
    for (final server in _servers) {
      server.addListener(_onChanged);
    }
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
    final hasErrors = _servers.any((s) => s.endpointError.value != null);
    if (hasErrors) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fix the errors before saving.')),
      );
      return;
    }

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
    setState(() => _hasUnsavedChanges = false);

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
    final newServer = _EditableServer();
    newServer.addListener(_onChanged);
    setState(() {
      _servers.add(newServer);
    });
  }

  void _removeAt(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Deletion'),
        content: const Text('Are you sure you want to remove this server?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _servers.removeAt(index).dispose();
      setState(() {});
      _saveAndReconnect();
    }
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
        String? errorMessage;
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
            errorMessage = mcpService.getLastError(serverUrl);
            break;
          case McpConnectionState.disconnected:
            color = Colors.grey;
            label = 'Disconnected';
        }

        final chip = Chip(
          label: Text(label),
          backgroundColor: color.withValues(alpha: 0.15),
          side: BorderSide(color: color.withValues(alpha: 0.6)),
          avatar: CircleAvatar(backgroundColor: color, radius: 6),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        );

        if (errorMessage != null && errorMessage.isNotEmpty) {
          return Tooltip(
            message: errorMessage,
            child: chip,
          );
        }
        return chip;
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
  void dispose() {
    for (final server in _servers) {
      server.dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {
        _hasUnsavedChanges = true;
      });
    }
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
            ValueListenableBuilder<bool>(
              valueListenable: ValueNotifier(_servers.any((s) => s.endpointError.value != null)),
              builder: (context, hasErrors, child) {
                return OutlinedButton.icon(
                  onPressed: !_hasUnsavedChanges || hasErrors ? null : _saveAndReconnect,
                  icon: const Icon(Icons.save),
                  label: const Text('Save & Reconnect'),
                );
              },
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
            child: ValueListenableBuilder<String?>(
              valueListenable: item.endpointError,
              builder: (context, error, child) {
                return TextField(
                  controller: item.endpointController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Endpoint (ws://host:port/path)',
                    border: const OutlineInputBorder(),
                    errorText: error,
                  ),
                );
              },
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
  final ValueNotifier<String?> endpointError = ValueNotifier(null);
  final TextEditingController nameController;
  final TextEditingController endpointController;
  final TextEditingController tokenController;
  final List<VoidCallback> _listeners = [];

  _EditableServer()
      : nameController = TextEditingController(),
        endpointController = TextEditingController(),
        tokenController = TextEditingController() {
    endpointController.addListener(_validateEndpoint);
    nameController.addListener(_notifyListeners);
    tokenController.addListener(_notifyListeners);
  }

  factory _EditableServer.fromConfig(McpServerConfig cfg) {
    final e = _EditableServer();
    e.nameController.text = cfg.name;
    e.endpointController.text = cfg.endpoint;
    if (cfg.authToken != null) e.tokenController.text = cfg.authToken!;
    e._validateEndpoint(); // Validate initial value
    return e;
  }

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  void dispose() {
    endpointController.removeListener(_validateEndpoint);
    nameController.removeListener(_notifyListeners);
    tokenController.removeListener(_notifyListeners);
    nameController.dispose();
    endpointController.dispose();
    tokenController.dispose();
    endpointError.dispose();
  }

  void _validateEndpoint() {
    final text = endpointController.text.trim();
    if (text.isEmpty) {
      endpointError.value = null; // No error if empty, just can't save
    } else {
      try {
        final uri = Uri.parse(text);
        if (!uri.isAbsolute || !['ws', 'wss', 'http', 'https'].contains(uri.scheme)) {
          endpointError.value = 'Use ws://, wss://, http://, or https://';
        } else {
          endpointError.value = null;
        }
      } catch (e) {
        endpointError.value = 'Invalid URI format';
      }
    }
    _notifyListeners();
  }
}
