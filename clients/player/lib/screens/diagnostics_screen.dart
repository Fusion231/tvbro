import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/app_appearance.dart';
import '../data/diagnostics_log.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final _scrollController = ScrollController();

  Future<void> _copy(BuildContext context) async {
    try {
      await Clipboard.setData(
        ClipboardData(text: DiagnosticsLog.instance.asText()),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Could not copy diagnostics.'))),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Diagnostics copied.'))));
  }

  KeyEventResult _scrollWithRemote(FocusNode _, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        !_scrollController.hasClients) {
      return KeyEventResult.ignored;
    }
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 120.0,
      LogicalKeyboardKey.arrowUp => -120.0,
      _ => 0.0,
    };
    if (delta == 0) return KeyEventResult.ignored;
    final position = _scrollController.position;
    final next = (_scrollController.offset + delta)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    if (next == position.pixels) return KeyEventResult.ignored;
    _scrollController.jumpTo(next);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AppAppearance(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final log = DiagnosticsLog.instance;
    return Scaffold(
      backgroundColor: AppAppearance.background,
      appBar: AppBar(
        title: Text(tr('Diagnostics')),
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
      ),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: log,
          builder: (context, _) => SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                FocusableCard(
                  autofocus: true,
                  centerOnFocus: false,
                  scrollOnFocus: false,
                  onTap: () => _copy(context),
                  onKeyEvent: _scrollWithRemote,
                  child: ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: Text(tr('Copy')),
                    trailing: const Icon(Icons.chevron_right),
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppAppearance.surface,
                    border: Border.all(color: AppAppearance.line),
                    borderRadius: BorderRadius.circular(AppAppearance.radius),
                  ),
                  child: SelectableText(
                    log.asText(),
                    style: const TextStyle(
                      color: AppColors.textHi,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
