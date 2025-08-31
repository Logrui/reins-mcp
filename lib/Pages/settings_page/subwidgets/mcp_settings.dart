import 'package:flutter/material.dart';
import 'dart:convert';
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
  // --- Dev Logs UI State ---
  String? _logsServerFilter; // null -> All
  McpLogLevel? _logsLevelMin; // null -> All levels
  final Set<String> _logsCategoryFilter = <String>{};
  String _logsSearch = '';
  bool _logsLiveTail = true;
  final ScrollController _logsScroll = ScrollController();

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
    _logsScroll.dispose();
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
        const SizedBox(height: 24),
        const Divider(),
        _buildLogsSection(context),
      ],
    );
  }

  Widget _buildLogsSection(BuildContext context) {
    final mcp = context.watch<McpService>();
    final logs = mcp.logs;

    // Build list of server options from editable servers
    final List<String> servers = _servers
        .map((e) => e.endpointController.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    // Deduplicate and sort to avoid duplicate DropdownMenuItem values
    final List<String> serverOptions = servers.toSet().toList()..sort();
    // Ensure the selected value is present exactly once in items; otherwise fall back to null (All)
    final String? effectiveServerFilter =
        (_logsServerFilter != null && serverOptions.contains(_logsServerFilter))
            ? _logsServerFilter
            : null;

    Color _levelColor(McpLogLevel lvl) {
      switch (lvl) {
        case McpLogLevel.debug:
          return Colors.blueGrey;
        case McpLogLevel.info:
          return Colors.blue;
        case McpLogLevel.warn:
          return Colors.orange;
        case McpLogLevel.error:
          return Colors.red;
      }
    }

    String _fmtTime(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

    bool _passesLevel(McpLogEvent e) {
      if (_logsLevelMin == null) return true;
      return e.level.index >= _logsLevelMin!.index;
    }

    bool _passesCategory(McpLogEvent e) {
      if (_logsCategoryFilter.isEmpty) return true;
      return _logsCategoryFilter.contains(e.category);
    }

    bool _passesSearch(McpLogEvent e) {
      if (_logsSearch.isEmpty) return true;
      final q = _logsSearch.toLowerCase();
      final dataStr = e.data == null ? '' : jsonEncode(e.data);
      return e.message.toLowerCase().contains(q) ||
          e.category.toLowerCase().contains(q) ||
          (e.serverUrl ?? '').toLowerCase().contains(q) ||
          (e.requestId ?? '').toLowerCase().contains(q) ||
          (e.sessionId ?? '').toLowerCase().contains(q) ||
          dataStr.toLowerCase().contains(q);
    }

    // Rebuild on new events
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'MCP Logs (Developer)',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: 'Enable verbose dev logs (includes debug level)',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Dev logging'),
                  const SizedBox(width: 6),
                  Switch(
                    value: logs.devLoggingEnabled,
                    onChanged: (v) => setState(() => logs.enableDevLogging(v)),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Server filter
            DropdownButton<String?>(
              value: effectiveServerFilter,
              hint: const Text('All servers'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All servers')),
                ...serverOptions.map((s) => DropdownMenuItem<String?>(value: s, child: Text(s))),
              ],
              onChanged: (v) => setState(() => _logsServerFilter = v),
            ),
            // Level min filter
            DropdownButton<McpLogLevel?>(
              value: _logsLevelMin,
              hint: const Text('Level: All'),
              items: const [
                DropdownMenuItem<McpLogLevel?>(value: null, child: Text('Level: All')),
                DropdownMenuItem<McpLogLevel?>(value: McpLogLevel.debug, child: Text('>= Debug')),
                DropdownMenuItem<McpLogLevel?>(value: McpLogLevel.info, child: Text('>= Info')),
                DropdownMenuItem<McpLogLevel?>(value: McpLogLevel.warn, child: Text('>= Warn')),
                DropdownMenuItem<McpLogLevel?>(value: McpLogLevel.error, child: Text('>= Error')),
              ],
              onChanged: (v) => setState(() => _logsLevelMin = v),
            ),
            // Search box
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Search…',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _logsSearch = v.trim()),
              ),
            ),
            // Live tail toggle
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Live tail'),
                const SizedBox(width: 6),
                Switch(
                  value: _logsLiveTail,
                  onChanged: (v) => setState(() => _logsLiveTail = v),
                ),
              ],
            ),
            // Clear button
            OutlinedButton.icon(
              onPressed: () {
                logs.clear(serverUrl: effectiveServerFilter);
                setState(() {});
              },
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Categories from current recent events (dynamic chips)
        Builder(builder: (context) {
          final current = logs.recent(serverUrl: effectiveServerFilter);
          final cats = current.map((e) => e.category).toSet().toList()..sort();
          return Wrap(
            spacing: 8,
            children: [
              for (final c in cats)
                FilterChip(
                  label: Text(c),
                  selected: _logsCategoryFilter.contains(c),
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _logsCategoryFilter.add(c);
                    } else {
                      _logsCategoryFilter.remove(c);
                    }
                  }),
                ),
              if (_logsCategoryFilter.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _logsCategoryFilter.clear()),
                  child: const Text('Clear categories'),
                ),
            ],
          );
        }),
        const SizedBox(height: 8),
        // Live list
        StreamBuilder<McpLogEvent>(
          stream: logs.stream(),
          builder: (context, snapshot) {
            // Always pull from recent(); stream only triggers rebuilds
            final events = logs
                .recent(serverUrl: effectiveServerFilter)
                .where(_passesLevel)
                .where(_passesCategory)
                .where(_passesSearch)
                .toList();

            // Auto-scroll to bottom on update
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_logsLiveTail && _logsScroll.hasClients) {
                _logsScroll.jumpTo(_logsScroll.position.maxScrollExtent);
              }
            });

            return Container(
              constraints: const BoxConstraints(minHeight: 320, maxHeight: 640),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView.builder(
                controller: _logsScroll,
                itemCount: events.length,
                itemBuilder: (context, i) {
                  final e = events[i];
                  final line = '[${_fmtTime(e.timestamp)}] [${e.level.name.toUpperCase()}] [${e.category}] ${e.message}';
                  final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
                  return ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    childrenPadding: const EdgeInsets.only(left: 24, right: 12, bottom: 8),
                    leading: Icon(Icons.fiber_manual_record, size: 12, color: _levelColor(e.level)),
                    title: Text(line, style: mono),
                    subtitle: (e.serverUrl != null || e.requestId != null)
                        ? Text(
                            [
                              if (e.serverUrl != null) e.serverUrl!,
                              if (e.requestId != null) 'req=${e.requestId}',
                              if (e.sessionId != null) 'sess=${e.sessionId}',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          )
                        : null,
                    children: [
                      if (e.data != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            const JsonEncoder.withIndent('  ').convert(e.data),
                            style: mono,
                          ),
                        )
                      else
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: EdgeInsets.only(bottom: 4),
                            child: Text('No details'),
                          ),
                        ),
                    ],
                  );
                },
              ),
            );
          },
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
