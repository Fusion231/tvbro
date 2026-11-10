import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

import '../data/app_database.dart';
import '../data/parental_controls.dart';
import '../data/profile_pin.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../widgets/pin_entry.dart';
import '../widgets/tv_text_field.dart';

/// Entry is PIN-gated by the caller. The existing TV-friendly PIN keypad and
/// verifier are shared with profile locking rather than implemented again.
class ParentalControlsScreen extends StatefulWidget {
  const ParentalControlsScreen({
    super.key,
    required this.db,
    required this.config,
    this.service,
  });
  final AppDatabase db;
  final SourceConfig config;
  final ParentalControlService? service;

  @override
  State<ParentalControlsScreen> createState() => _ParentalControlsScreenState();
}

class _ParentalControlsScreenState extends State<ParentalControlsScreen> {
  late final _controls = widget.service ?? ParentalControlService.instance;
  List<Channel> _channels = const [];
  final _categories = <ContentKind, List<({String id, String title})>>{};
  final _search = TextEditingController();
  String _query = '';
  ContentKind _kind = ContentKind.live;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await _controls.ensureInitialized();
      final sourceId = widget.config.id;
      final (channels, live, movies, series) = await (
        widget.db.readChannels(sourceId),
        widget.db.readCategories(sourceId),
        widget.db.readMediaCategories(sourceId, ContentKind.movie),
        widget.db.readMediaCategories(sourceId, ContentKind.series),
      ).wait;
      if (!mounted) return;
      setState(() {
        _channels = channels;
        _categories[ContentKind.live] = [
          for (final c in live) (id: c.id, title: c.title),
        ];
        _categories[ContentKind.movie] = [
          for (final c in movies) (id: c.id, title: c.title),
        ];
        _categories[ContentKind.series] = [
          for (final c in series) (id: c.id, title: c.title),
        ];
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = tr('Could not load parental controls.');
        });
      }
    }
  }

  Future<void> _save(ParentalRules rules) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _controls.save(rules);
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = tr('Could not save parental controls. Try again.'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setPin() async {
    final pin = await promptNewProfilePin(
      context,
      profileName: tr('parental controls'),
    );
    if (pin == null || !mounted) return;
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final verifier = await hashProfilePinAsync(pin);
      if (!mounted) return;
      await _controls.save(_controls.rules.copyWith(verifier: verifier));
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = tr('Could not save parental controls. Try again.'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _disable() async {
    final accepted = await promptUnlockProfile(
      context,
      profileName: tr('parental controls'),
      verifier: _controls.rules.verifier!,
    );
    if (accepted && mounted) await _save(const ParentalRules());
  }

  @override
  Widget build(BuildContext context) {
    final rules = _controls.rules;
    final query = _query.toLowerCase();
    final categories =
        (_categories[_kind] ?? const <({String id, String title})>[])
            .where((category) => category.title.toLowerCase().contains(query))
            .toList();
    final channels = _kind == ContentKind.live
        ? _channels
              .where((channel) => channel.name.toLowerCase().contains(query))
              .toList()
        : const <Channel>[];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Parental controls'))),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverList.list(
                      children: [
                        Text(
                          tr(
                            'Protected channels and categories are hidden until you unlock them with your PIN. '
                            'Unlocking lasts until you lock again, change profile, or restart TVBro.',
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_error != null) Text(_error!),
                        if (_saving) const LinearProgressIndicator(),
                        Wrap(
                          spacing: 12,
                          children: [
                            FilledButton.icon(
                              onPressed: _saving || _controls.unavailable
                                  ? null
                                  : _setPin,
                              icon: const Icon(Icons.pin_outlined),
                              label: Text(
                                rules.enabled
                                    ? tr('Change PIN')
                                    : tr('Set parental PIN'),
                              ),
                            ),
                            if (rules.enabled)
                              TextButton(
                                onPressed: _saving ? null : _disable,
                                child: Text(tr('Disable controls')),
                              ),
                          ],
                        ),
                        if (rules.enabled) ...[
                          SwitchListTile(
                            title: Text(
                              tr(
                                'Protect library and profile settings with PIN',
                              ),
                            ),
                            value: rules.lockSettings,
                            onChanged: _saving
                                ? null
                                : (value) => _save(
                                    rules.copyWith(lockSettings: value),
                                  ),
                          ),
                          Text(
                            tr('Locks for {name}', {
                              'name': widget.config.label,
                            }),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          DropdownButton<ContentKind>(
                            value: _kind,
                            items: [
                              DropdownMenuItem(
                                value: ContentKind.live,
                                child: Text(tr('Live TV')),
                              ),
                              DropdownMenuItem(
                                value: ContentKind.movie,
                                child: Text(tr('Movies')),
                              ),
                              DropdownMenuItem(
                                value: ContentKind.series,
                                child: Text(tr('Series')),
                              ),
                            ],
                            onChanged: (kind) {
                              if (kind != null) setState(() => _kind = kind);
                            },
                          ),
                          TvTextField(
                            controller: _search,
                            hintText: tr('Find channels or categories'),
                            onChanged: (value) =>
                                setState(() => _query = value),
                            showClear: _query.isNotEmpty,
                            onClear: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          ),
                          const SizedBox(height: 12),
                          Text(tr('Categories')),
                        ],
                      ],
                    ),
                  ),
                  if (rules.enabled) ...[
                    SliverList.builder(
                      itemCount: categories.length,
                      itemBuilder: (context, index) {
                        final category = categories[index];
                        final key = ParentalRules.categoryKey(
                          widget.config.id,
                          _kind,
                          category.id,
                        );
                        return CheckboxListTile(
                          key: ValueKey('parental.category.$key'),
                          title: Text(category.title),
                          subtitle: Text(tr('Require parental PIN')),
                          value: rules.categories.contains(key),
                          onChanged: _saving
                              ? null
                              : (locked) {
                                  final next = {...rules.categories};
                                  if (locked == true) {
                                    next.add(key);
                                  } else {
                                    next.remove(key);
                                  }
                                  _save(rules.copyWith(categories: next));
                                },
                        );
                      },
                    ),
                    if (_kind == ContentKind.live)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(tr('Individual channels')),
                        ),
                      ),
                    SliverList.builder(
                      itemCount: channels.length,
                      itemBuilder: (context, index) {
                        final channel = channels[index];
                        final key = ParentalRules.channelKey(
                          widget.config.id,
                          channel.id,
                        );
                        return CheckboxListTile(
                          key: ValueKey('parental.channel.${channel.id}'),
                          title: Text(channel.name),
                          value: rules.channels.contains(key),
                          onChanged: _saving
                              ? null
                              : (locked) {
                                  final next = {...rules.channels};
                                  if (locked == true) {
                                    next.add(key);
                                  } else {
                                    next.remove(key);
                                  }
                                  _save(rules.copyWith(channels: next));
                                },
                        );
                      },
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
