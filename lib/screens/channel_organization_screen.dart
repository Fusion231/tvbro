import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

import '../data/app_database.dart';
import '../data/channel_organization.dart';
import '../data/source_store.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/tv_text_field.dart';

class ChannelOrganizationScreen extends StatefulWidget {
  const ChannelOrganizationScreen({
    super.key,
    required this.db,
    required this.store,
    required this.config,
  });
  final AppDatabase db;
  final SourceStore store;
  final SourceConfig config;

  @override
  State<ChannelOrganizationScreen> createState() =>
      _ChannelOrganizationScreenState();
}

class _ChannelOrganizationScreenState extends State<ChannelOrganizationScreen> {
  late ChannelOrganization _organization = widget.config.channelOrganization;
  List<Channel> _channels = const [];
  final _search = TextEditingController();
  String _query = '';
  String? _groupId;
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
      final channels = await widget.db.readChannels(widget.config.id);
      if (!mounted) return;
      setState(() {
        _channels = channels;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = tr('Could not load channels.');
          _loading = false;
        });
      }
    }
  }

  Future<void> _save(ChannelOrganization next) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final current = (await widget.store.list())
          .where((c) => c.id == widget.config.id)
          .firstOrNull;
      if (current == null) throw StateError('Source removed');
      await widget.store.save(current.withChannelOrganization(next));
      if (mounted) {
        setState(() {
          _organization = next;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = tr('Could not save channel changes. Try again.'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _name(
    String title,
    String initial, {
    bool allowEmpty = false,
  }) async {
    final controller = TextEditingController(text: initial);
    final route = DialogRoute<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: TvTextField(
            controller: controller,
            hintText: allowEmpty
                ? tr('Empty restores the provider name')
                : tr('Name'),
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Cancel')),
          ),
          TextButton(
            onPressed: () {
              final text = controller.text.trim();
              if (allowEmpty || text.isNotEmpty) Navigator.pop(context, text);
            },
            child: Text(tr('Save')),
          ),
        ],
      ),
    );
    final value = await Navigator.of(context).push(route);
    // The text field remains mounted until the exit transition has finished.
    await route.completed;
    controller.dispose();
    return value;
  }

  Future<void> _rename(Channel channel) async {
    final name = await _name(
      tr('Channel name'),
      _organization.names[channel.id] ?? channel.name,
      allowEmpty: true,
    );
    if (name == null || !mounted) return;
    final names = {..._organization.names};
    if (name.isEmpty) {
      names.remove(channel.id);
    } else {
      names[channel.id] = name;
    }
    await _save(_organization.copyWith(names: names));
  }

  Future<void> _createGroup() async {
    final name = await _name(tr('New channel group'), '');
    if (name == null || !mounted) return;
    final group = CustomChannelGroup(
      id: '$kCustomChannelGroupPrefix${newSourceId()}',
      name: name,
    );
    await _save(
      _organization.copyWith(groups: [..._organization.groups, group]),
    );
    if (mounted && _organization.group(group.id) != null) {
      setState(() => _groupId = group.id);
    }
  }

  Future<void> _editGroup() async {
    final group = _organization.group(_groupId);
    if (group == null) return;
    final name = await _name(tr('Group name'), group.name);
    if (name == null || !mounted) return;
    await _save(
      _organization.copyWith(
        groups: [
          for (final item in _organization.groups)
            if (item.id == group.id)
              CustomChannelGroup(
                id: group.id,
                name: name,
                channelIds: group.channelIds,
              )
            else
              item,
        ],
      ),
    );
  }

  Future<void> _deleteGroup() async {
    final group = _organization.group(_groupId);
    if (group == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete {name}?', {'name': group.name})),
        content: Text(tr('Channels stay in your source.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await _save(
      _organization.copyWith(
        groups: _organization.groups.where((g) => g.id != group.id).toList(),
      ),
    );
    if (mounted && _organization.group(group.id) == null) {
      setState(() => _groupId = null);
    }
  }

  Future<void> _membership(Channel channel) async {
    if (_organization.groups.isEmpty) {
      await _createGroup();
      if (!mounted || _organization.groups.isEmpty) return;
    }
    final selected = {
      for (final group in _organization.groups)
        if (group.channelIds.contains(channel.id)) group.id,
    };
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(tr('Groups · {name}', {'name': channel.name})),
          content: SizedBox(
            width: 400,
            height: 300,
            child: ListView(
              children: [
                for (final group in _organization.groups)
                  CheckboxListTile(
                    title: Text(group.name),
                    value: selected.contains(group.id),
                    onChanged: (value) => update(() {
                      if (value == true) {
                        selected.add(group.id);
                      } else {
                        selected.remove(group.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('Save')),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    await _save(
      _organization.copyWith(
        groups: [
          for (final group in _organization.groups)
            CustomChannelGroup(
              id: group.id,
              name: group.name,
              channelIds: [
                ...group.channelIds.where((id) => id != channel.id),
                if (selected.contains(group.id)) channel.id,
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _move(Channel channel, int delta) async {
    final order = _organization
        .apply(_channels, includeHidden: true)
        .map((c) => c.id)
        .toList();
    final index = order.indexOf(channel.id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= order.length) return;
    order[index] = order[target];
    order[target] = channel.id;
    await _save(_organization.copyWith(order: order));
  }

  @override
  Widget build(BuildContext context) {
    final group = _organization.group(_groupId);
    final members = group?.channelIds.toSet();
    final channels = _organization
        .apply(_channels, includeHidden: true)
        .where(
          (channel) =>
              (members == null || members.contains(channel.id)) &&
              channel.name.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr('Organize channels'))),
      body: SafeArea(
        child: Column(
          children: [
            if (_saving) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TvTextField(
                controller: _search,
                hintText: tr('Search channels'),
                onChanged: (value) => setState(() => _query = value),
                showClear: _query.isNotEmpty,
                onClear: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<String>(
                    value: group?.id ?? '',
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(tr('All channels')),
                      ),
                      for (final group in _organization.groups)
                        DropdownMenuItem(
                          value: group.id,
                          child: Text(group.name),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (id) =>
                              setState(() => _groupId = id == '' ? null : id),
                  ),
                  TextButton.icon(
                    onPressed: _saving ? null : _createGroup,
                    icon: const Icon(Icons.add),
                    label: Text(tr('New group')),
                  ),
                  if (group != null) ...[
                    IconButton(
                      tooltip: tr('Rename group'),
                      onPressed: _saving ? null : _editGroup,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: tr('Delete group'),
                      onPressed: _saving ? null : _deleteGroup,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ],
              ),
            ),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
            if (group != null && channels.isEmpty)
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  tr(
                    'Choose All channels, then use Groups on a channel to add it here.',
                  ),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: channels.length,
                      itemBuilder: (context, index) {
                        final channel = channels[index];
                        final hidden = _organization.hidden.contains(
                          channel.id,
                        );
                        return ListTile(
                          key: ValueKey('organize.${channel.id}'),
                          title: Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: hidden ? AppColors.textLo : null,
                            ),
                          ),
                          subtitle: hidden ? Text(tr('Hidden')) : null,
                          onTap: _saving ? null : () => _rename(channel),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: hidden
                                    ? tr('Show channel')
                                    : tr('Hide channel'),
                                onPressed: _saving
                                    ? null
                                    : () {
                                        final next = {..._organization.hidden};
                                        if (!next.add(channel.id)) {
                                          next.remove(channel.id);
                                        }
                                        _save(
                                          _organization.copyWith(hidden: next),
                                        );
                                      },
                                icon: Icon(
                                  hidden
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                              IconButton(
                                tooltip: tr('Groups'),
                                onPressed: _saving
                                    ? null
                                    : () => _membership(channel),
                                icon: const Icon(Icons.folder_outlined),
                              ),
                              IconButton(
                                tooltip: tr('Move up'),
                                onPressed:
                                    _saving ||
                                        _query.isNotEmpty ||
                                        group != null ||
                                        index == 0
                                    ? null
                                    : () => _move(channel, -1),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: tr('Move down'),
                                onPressed:
                                    _saving ||
                                        _query.isNotEmpty ||
                                        group != null ||
                                        index == channels.length - 1
                                    ? null
                                    : () => _move(channel, 1),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                            ],
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
