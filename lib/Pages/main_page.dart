import 'package:flutter/material.dart';
import 'package:reins/Pages/chat_page/chat_page.dart';
import 'package:reins/Pages/chat_page/subwidgets/chat_dev_drawer.dart';
import 'package:reins/Widgets/chat_app_bar.dart';
import 'package:reins/Widgets/chat_drawer.dart';
import 'package:responsive_framework/responsive_framework.dart';

class ReinsMainPage extends StatelessWidget {
  const ReinsMainPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (ResponsiveBreakpoints.of(context).isMobile) {
      return const Scaffold(
        appBar: ChatAppBar(),
        body: SafeArea(child: ChatPage()),
        drawer: ChatDrawer(),
        endDrawer: ChatDevDrawer(),
      );
    } else {
      return const _ReinsLargeMainPage();
    }
  }
}

class _ReinsLargeMainPage extends StatefulWidget {
  const _ReinsLargeMainPage();

  @override
  State<_ReinsLargeMainPage> createState() => _ReinsLargeMainPageState();
}

class _ReinsLargeMainPageState extends State<_ReinsLargeMainPage> {
  bool _showDevPanel = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            const ChatDrawer(),
            Expanded(
              child: ChatPage(
                onToggleDevPanel: () => setState(() => _showDevPanel = !_showDevPanel),
              ),
            ),
            if (_showDevPanel)
              ChatDevDrawer(
                asPanel: true,
                onClose: () => setState(() => _showDevPanel = false),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        tooltip: _showDevPanel ? 'Hide Debug Panel' : 'Show Debug Panel',
        onPressed: () => setState(() => _showDevPanel = !_showDevPanel),
        child: Icon(_showDevPanel ? Icons.close : Icons.bug_report_outlined),
      ),
    );
  }
}
