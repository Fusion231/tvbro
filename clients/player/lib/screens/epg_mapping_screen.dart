import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

import '../data/library_repository.dart';
import '../sources/epg_mapping.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/tv_text_field.dart';

/// Manual guide bindings and time corrections for the active source. Suggested
/// matches are choices only; selecting one still requires an explicit Save.
class EpgMappingScreen extends StatefulWidget {
  final LibraryRepository repo;
  final List<Channel> channels;
  final String? initialChannelId;

  const EpgMappingScreen({
    super.key,
    required this.repo,
    required this.channels,
    this.initialChannelId,
  });

  @override
  State<EpgMappingScreen> createState() => _EpgMappingScreenState();
}

class _EpgMappingScreenState extends State<EpgMappingScreen> {
  final _filter = TextEditingController();
  List<EpgGuideChannel> _catalogue = const [];
  Map<String, EpgChannelOverride> _mappings = const {};
  Channel? _channel;
  bool _loading = true;
  bool _changed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final channel in widget.channels) {
      if (channel.id == widget.initialChannelId) _channel = channel;
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final catalogue = await widget.repo.readEpgGuideChannels();
      final mappings = await widget.repo.readEpgMappings();
      if (!mounted) return;
      setState(() {
        _catalogue = catalogue;
        _mappings = {
          for (final mapping in mappings) mapping.channelId: mapping,
        };
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = tr('The saved guide mappings could not be loaded.');
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _back() {
    if (_channel != null && widget.initialChannelId == null) {
      setState(() => _channel = null);
    } else {
      Navigator.of(context).pop(_changed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.text.trim().toLowerCase();
    final channels = query.isEmpty
        ? widget.channels
        : widget.channels
              .where((channel) => channel.name.toLowerCase().contains(query))
              .toList();
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_channel?.name ?? tr('EPG mapping')),
          leading: IconButton(
            tooltip: tr('Back'),
            onPressed: _back,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text(_error!))
            : _channel != null
            ? _MappingEditor(
                key: ValueKey(_channel!.id),
                repo: widget.repo,
                channel: _channel!,
                channels: widget.channels,
                catalogue: _catalogue,
                initial: _mappings[_channel!.id],
                onSaved: (mapping) {
                  setState(() {
                    _changed = true;
                    _mappings = {..._mappings, mapping.channelId: mapping};
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        tr('EPG correction saved. Updating guide…'),
                      ),
                    ),
                  );
                },
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TvTextField(
                      controller: _filter,
                      hintText: tr('Find a channel'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: channels.length,
                      itemBuilder: (context, index) {
                        final channel = channels[index];
                        final mapping = _mappings[channel.id];
                        return FocusableCard(
                          key: ValueKey('epg.channel.${channel.id}'),
                          onTap: () => setState(() => _channel = channel),
                          child: ListTile(
                            title: Text(channel.name),
                            subtitle: Text(
                              '${mapping?.hasBinding == true ? tr('Manual guide') : tr('Automatic matching')}'
                              '${mapping?.offsetMinutes == 0 || mapping == null ? '' : ' · ${mapping.offsetMinutes > 0 ? '+' : ''}${mapping.offsetMinutes} min'}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

List<EpgMappingSuggestion> _suggest((Channel, List<EpgGuideChannel>) args) =>
    suggestEpgMappings(args.$1, args.$2);

class _MappingEditor extends StatefulWidget {
  final LibraryRepository repo;
  final Channel channel;
  final List<Channel> channels;
  final List<EpgGuideChannel> catalogue;
  final EpgChannelOverride? initial;
  final ValueChanged<EpgChannelOverride> onSaved;

  const _MappingEditor({
    super.key,
    required this.repo,
    required this.channel,
    required this.channels,
    required this.catalogue,
    required this.initial,
    required this.onSaved,
  });

  @override
  State<_MappingEditor> createState() => _MappingEditorState();
}

class _MappingEditorState extends State<_MappingEditor> {
  final _search = TextEditingController();
  late final _offset = TextEditingController(
    text: '${widget.initial?.offsetMinutes ?? 0}',
  );
  late String? _guideId = widget.initial?.guideId;
  late String? _guideChannelId = widget.initial?.guideChannelId;
  late final Future<List<EpgMappingSuggestion>> _suggestions = compute(
    _suggest,
    (widget.channel, widget.catalogue),
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    _offset.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final offset = int.tryParse(_offset.text.trim());
    if (offset == null || offset.abs() > 1440) {
      setState(
        () => _error = tr('Enter whole minutes between −1440 and 1440.'),
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final mapping = EpgChannelOverride(
      channelId: widget.channel.id,
      guideId: _guideId,
      guideChannelId: _guideChannelId,
      offsetMinutes: offset,
    );
    try {
      await widget.repo.setEpgMapping(mapping, channels: widget.channels);
      if (!mounted) return;
      setState(() => _saving = false);
      widget.onSaved(mapping);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = tr('The EPG correction could not be saved. Try again.');
      });
    }
  }

  Widget _candidate(EpgGuideChannel candidate, {bool suggested = false}) {
    final selected =
        candidate.guideId == _guideId && candidate.channelId == _guideChannelId;
    return FocusableCard(
      key: ValueKey(
        'epg.candidate.${candidate.guideId}.${candidate.channelId}',
      ),
      selected: selected,
      onTap: () => setState(() {
        _guideId = candidate.guideId;
        _guideChannelId = candidate.channelId;
      }),
      child: ListTile(
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        ),
        title: Text(candidate.name),
        subtitle: Text(
          '${candidate.guideLabel} · ${candidate.channelId}${suggested ? tr(' · Suggested') : ''}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final results = query.isEmpty
        ? const <EpgGuideChannel>[]
        : widget.catalogue
              .where(
                (channel) =>
                    channel.channelId.toLowerCase().contains(query) ||
                    channel.displayNames.any(
                      (name) => name.toLowerCase().contains(query),
                    ),
              )
              .take(80)
              .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          tr(
            'Choose a guide channel, then save. Suggestions are never applied automatically.',
          ),
        ),
        const SizedBox(height: 12),
        FocusableCard(
          key: const ValueKey('epg.automatic'),
          selected: _guideId == null,
          onTap: () => setState(() {
            _guideId = null;
            _guideChannelId = null;
          }),
          child: ListTile(
            leading: Icon(
              _guideId == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(tr('Automatic matching')),
            subtitle: Text(
              tr('Use the existing guide order and exact matching rules'),
            ),
          ),
        ),
        if (_guideId != null) ...[
          const SizedBox(height: 8),
          Text(
            tr('Selected guide channel: {id}', {'id': _guideChannelId ?? ''}),
            style: const TextStyle(color: AppColors.textLo),
          ),
        ],
        const SizedBox(height: 12),
        TvTextField(
          key: const ValueKey('epg.offset'),
          controller: _offset,
          hintText: '0',
          label: tr('Time correction in minutes'),
        ),
        const SizedBox(height: 6),
        Text(
          tr(
            'Positive values move programmes later; negative values move them earlier.',
          ),
          style: TextStyle(color: AppColors.textLo),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('epg.save'),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_saving ? tr('Saving…') : tr('Save correction')),
        ),
        const SizedBox(height: 20),
        TvTextField(
          key: const ValueKey('epg.guideSearch'),
          controller: _search,
          hintText: tr('Find a guide channel by name or ID'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        if (widget.catalogue.isEmpty)
          Text(
            tr(
              'No XMLTV channel catalogue is cached yet. Refresh the guide first.',
            ),
          )
        else if (query.isNotEmpty) ...[
          if (results.isEmpty) Text(tr('No guide channels found')),
          for (final candidate in results) _candidate(candidate),
        ] else
          FutureBuilder<List<EpgMappingSuggestion>>(
            future: _suggestions,
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const LinearProgressIndicator();
              final suggestions = snapshot.data!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(tr('Suggested matches')),
                  if (suggestions.isEmpty)
                    Text(tr('Search the guide catalogue to choose a match.')),
                  for (final suggestion in suggestions)
                    _candidate(suggestion.candidate, suggested: true),
                ],
              );
            },
          ),
      ],
    );
  }
}
