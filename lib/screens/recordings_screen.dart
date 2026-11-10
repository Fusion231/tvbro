import 'dart:async';

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dvr/dvr_service.dart';
import '../l10n/app_localizations.dart';
import '../dvr/dvr_scheduler.dart';
import '../player/player_screen.dart';
import '../theme.dart';

/// Device-local recordings and the current bounded timeshift session.
///
/// The service can be injected in widget tests; production uses its singleton.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key, this.service, this.scheduler});

  final DvrService? service;
  final DvrScheduler? scheduler;

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  late final DvrService _service = widget.service ?? DvrService.instance;
  late final DvrScheduler? _scheduler =
      widget.scheduler ??
      (widget.service == null ? DvrScheduler.instance : null);
  List<DvrSchedule> get _schedules => _scheduler?.schedules ?? const [];
  int get _itemCount => _schedules.length + _service.recordings.length;
  final ScrollController _listController = ScrollController();
  final FocusNode _listFocusNode = FocusNode(debugLabel: 'recordings.list');
  final GlobalKey _headerKey = GlobalKey(debugLabel: 'recordings.header');
  Timer? _clock;
  String? _initializationError;
  bool _loading = true;
  bool _working = false;
  int _selectedIndex = 0;
  bool _deleteColumn = false;
  double _rowExtent = 120;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _scheduler?.addListener(_onServiceChanged);
    unawaited(_initialize());
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _service.activeRecording != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _scheduler?.removeListener(_onServiceChanged);
    _clock?.cancel();
    _listController.dispose();
    _listFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _service.ensureInitialized();
      await _scheduler?.ensureInitialized();
      if (!mounted) return;
      setState(() {
        _initializationError = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initializationError = tr('Local recording storage could not be opened.');
        _loading = false;
      });
    }
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {
      final count = _itemCount;
      if (count == 0) {
        _selectedIndex = 0;
        _deleteColumn = false;
      } else if (_selectedIndex >= count) {
        _selectedIndex = count - 1;
      }
    });
  }

  String _errorMessage(Object error) => error is DvrException
      ? tr(error.message)
      : tr('The recording could not be changed. Check local storage and try again.');

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_errorMessage(error))));
  }

  Future<void> _runOperation(Future<void> Function() operation) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await operation();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _playRecording(DvrRecording recording) async {
    if (!_canPlay(recording)) return;
    await _runOperation(() async {
      final stream = await _service.recordingPlayback(recording);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            title: recording.programmeTitle?.trim().isNotEmpty == true
                ? recording.programmeTitle!.trim()
                : recording.channelName,
            sourceName: tr('On-device recording'),
            stream: stream,
          ),
        ),
      );
    });
  }

  Future<void> _stopRecording(DvrRecording recording) =>
      _runOperation(() => _service.stopRecording(recording.id));

  Future<void> _cancelSchedule(DvrSchedule schedule) =>
      _runOperation(() => _scheduler!.cancelSchedule(schedule.id));

  Future<void> _removeSchedule(DvrSchedule schedule) =>
      _runOperation(() => _scheduler!.removeSchedule(schedule.id));

  Future<void> _stopTimeshift() {
    final session = _service.activeSession;
    if (session == null) return Future<void>.value();
    return _runOperation(() => _service.stopTimeshift(session: session));
  }

  Future<void> _confirmDelete(DvrRecording recording) async {
    if (recording.status == DvrRecordingStatus.recording || _working) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Delete recording?')),
        content: Text(
          tr('Delete “{title}” from this device? This cannot be undone.', {
            'title': _displayTitle(recording),
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runOperation(() => _service.deleteRecording(recording.id));
  }

  bool _canPlay(DvrRecording recording) =>
      recording.hasMedia && recording.status != DvrRecordingStatus.recording;

  String _displayTitle(DvrRecording recording) {
    final programme = recording.programmeTitle?.trim();
    if (programme != null && programme.isNotEmpty) return programme;
    return recording.channelName;
  }

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final recordings = _service.recordings;
    final schedules = _schedules;
    final count = recordings.length + schedules.length;
    if (count == 0) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _select(_selectedIndex + 1, count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _select(_selectedIndex - 1, count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_selectedIndex < schedules.length) {
        if (!schedules[_selectedIndex].isPending) {
          setState(() => _deleteColumn = true);
        }
        return KeyEventResult.handled;
      }
      final recording =
          recordings[(_selectedIndex - schedules.length)
              .clamp(0, recordings.length - 1)
              .toInt()];
      if (recording.status != DvrRecordingStatus.recording) {
        setState(() => _deleteColumn = true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      setState(() => _deleteColumn = false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space) {
      if (_selectedIndex < schedules.length) {
        final schedule = schedules[_selectedIndex];
        if (_deleteColumn && !schedule.isPending) {
          unawaited(_removeSchedule(schedule));
        } else if (schedule.isPending) {
          unawaited(_cancelSchedule(schedule));
        }
        return KeyEventResult.handled;
      }
      final recording =
          recordings[(_selectedIndex - schedules.length)
              .clamp(0, recordings.length - 1)
              .toInt()];
      if (_deleteColumn) {
        unawaited(_confirmDelete(recording));
      } else if (recording.status == DvrRecordingStatus.recording) {
        unawaited(_stopRecording(recording));
      } else if (_canPlay(recording)) {
        unawaited(_playRecording(recording));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _select(int index, int count) {
    final next = index.clamp(0, count - 1).toInt();
    if (next != _selectedIndex) {
      setState(() {
        _selectedIndex = next;
        _deleteColumn = false;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_listController.hasClients) return;
      final header = _headerKey.currentContext?.findRenderObject();
      final headerExtent = header is RenderBox ? header.size.height : 0.0;
      final target = headerExtent + next * _rowExtent;
      final position = _listController.position;
      _listController.animateTo(
        target.clamp(0.0, position.maxScrollExtent).toDouble(),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    _rowExtent = _recordingRowExtent(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Recordings'))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_initializationError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Recordings'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_off_outlined, size: 48),
                const SizedBox(height: 16),
                Text(
                  tr('Local recording storage is unavailable.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  _initializationError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textLo),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final recordings = _service.recordings;
    final schedules = _schedules;
    final activeSession = _service.activeSession;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Recordings')),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                tr('Saved on this device'),
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: AppColors.textLo),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Focus(
              focusNode: _listFocusNode,
              autofocus: true,
              onKeyEvent: _onListKey,
              child: CustomScrollView(
                controller: _listController,
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      key: _headerKey,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _StorageSummary(service: _service),
                        if (schedules.any((schedule) => schedule.isPending))
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            child: Text(
                              tr(
                                Platform.isIOS
                                    ? 'On iOS, scheduled starts and ongoing captures may be interrupted if TVBro is backgrounded or suspended. Keep TVBro open in the foreground; missed starts and partial recordings are checked after reopening.'
                                    : 'Scheduled recording requires TVBro to remain running and the device awake. Missed starts are reported here after restart.',
                              ),
                            ),
                          ),
                        if (_service.notificationSuppressed &&
                            _service.activeRecording != null)
                          const _NotificationNotice(),
                        if (activeSession != null)
                          _TimeshiftCard(
                            session: activeSession,
                            working: _working,
                            onStop: _stopTimeshift,
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                          child: Row(
                            children: [
                              Text(
                                schedules.isEmpty
                                    ? tr('Saved recordings')
                                    : tr('Scheduled & saved recordings'),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const Spacer(),
                              if (recordings.isNotEmpty)
                                Text(
                                  tr(
                                    recordings.length == 1
                                        ? '{count} item'
                                        : '{count} items',
                                    {'count': recordings.length},
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: AppColors.textLo),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_itemCount == 0)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyRecordings(),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      sliver: SliverFixedExtentList(
                        itemExtent: _rowExtent,
                        delegate: SliverChildBuilderDelegate((context, index) {
                          if (index < schedules.length) {
                            final schedule = schedules[index];
                            return _ScheduleRow(
                              schedule: schedule,
                              selected:
                                  _listFocusNode.hasFocus &&
                                  index == _selectedIndex,
                              deleteColumn:
                                  _deleteColumn && index == _selectedIndex,
                              working: _working,
                              onSelect: () {
                                setState(() {
                                  _selectedIndex = index;
                                  _deleteColumn = false;
                                });
                                _listFocusNode.requestFocus();
                              },
                              onCancel: () =>
                                  unawaited(_cancelSchedule(schedule)),
                              onRemove: () =>
                                  unawaited(_removeSchedule(schedule)),
                            );
                          }
                          final recording =
                              recordings[index - schedules.length];
                          return _RecordingRow(
                            recording: recording,
                            selected:
                                _listFocusNode.hasFocus &&
                                index == _selectedIndex,
                            deleteColumn:
                                _deleteColumn && index == _selectedIndex,
                            working: _working,
                            canPlay: _canPlay(recording),
                            title: _displayTitle(recording),
                            onSelect: () {
                              setState(() {
                                _selectedIndex = index;
                                _deleteColumn = false;
                              });
                              _listFocusNode.requestFocus();
                              if (_canPlay(recording)) {
                                unawaited(_playRecording(recording));
                              } else if (recording.status ==
                                  DvrRecordingStatus.recording) {
                                unawaited(_stopRecording(recording));
                              }
                            },
                            onPlay: () => unawaited(_playRecording(recording)),
                            onStop: () => unawaited(_stopRecording(recording)),
                            onDelete: () =>
                                unawaited(_confirmDelete(recording)),
                          );
                        }, childCount: _itemCount),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double _recordingRowExtent(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
  return 120 * scale.clamp(1.0, 2.0);
}

class _StorageSummary extends StatelessWidget {
  const _StorageSummary({required this.service});

  final DvrService service;

  @override
  Widget build(BuildContext context) {
    final quota = service.recordingQuotaBytes;
    final used = service.recordingBytes;
    final ratio = quota <= 0 ? 0.0 : (used / quota).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.storage_outlined, color: AppColors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr('Recording storage  {used} / {quota}', {
                      'used': _formatBytes(used),
                      'quota': _formatBytes(quota),
                    }),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: ratio),
            const SizedBox(height: 8),
            Text(
              tr('Timeshift keeps up to {duration} or {size} in temporary local storage.', {
                'duration': _formatDuration(service.settings.maxBufferDuration),
                'size': _formatBytes(service.settings.maxBufferBytes),
              }),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: AppColors.textLo),
            ),
            const SizedBox(height: 6),
            Text(
              tr('Recordings start and stop at complete stream segments; the first or last few seconds may differ from the button time.'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: AppColors.textLo),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationNotice extends StatelessWidget {
  const _NotificationNotice();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Icon(Icons.notifications_off_outlined, color: AppColors.textLo),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('Android did not show the recording notification. You can stop the active recording here.'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _TimeshiftCard extends StatelessWidget {
  const _TimeshiftCard({
    required this.session,
    required this.working,
    required this.onStop,
  });

  final DvrSession session;
  final bool working;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final snapshot = session.snapshot;
    final state = snapshot.reconnecting
        ? tr('Reconnecting')
        : switch (snapshot.state) {
            DvrCaptureState.starting => tr('Starting'),
            DvrCaptureState.buffering => tr('Buffering'),
            DvrCaptureState.stopped => tr('Stopped'),
            DvrCaptureState.failed => tr('Unavailable'),
          };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            const Icon(Icons.history_rounded, color: AppColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${tr('Timeshift')} · ${session.channelName}'),
                  const SizedBox(height: 3),
                  Text(
                    tr('{state} · {duration} buffered · {size}', {
                      'state': state,
                      'duration': _formatDuration(snapshot.bufferedDuration),
                      'size': _formatBytes(snapshot.bytes),
                    }),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: AppColors.textLo),
                  ),
                  if (snapshot.error != null)
                    Text(
                      tr('The temporary buffer could not continue.'),
                      style: TextStyle(color: AppColors.danger, fontSize: 12),
                    ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: working ? null : onStop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(tr('Stop timeshift')),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyRecordings extends StatelessWidget {
  const _EmptyRecordings();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.video_library_outlined,
            size: 48,
            color: AppColors.textLo,
          ),
          const SizedBox(height: 12),
          Text(
            tr('No recordings yet'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            tr('Recordings are saved on this device and stay here after you leave the player.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textLo),
          ),
        ],
      ),
    ),
  );
}

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({
    required this.recording,
    required this.selected,
    required this.deleteColumn,
    required this.working,
    required this.canPlay,
    required this.title,
    required this.onSelect,
    required this.onPlay,
    required this.onStop,
    required this.onDelete,
  });

  final DvrRecording recording;
  final bool selected;
  final bool deleteColumn;
  final bool working;
  final bool canPlay;
  final String title;
  final VoidCallback onSelect;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final recordingNow = recording.status == DvrRecordingStatus.recording;
    final canDelete = !recordingNow;
    final duration = recordingNow
        ? DateTime.now().difference(recording.startedAt)
        : recording.duration;
    final status = switch (recording.status) {
      DvrRecordingStatus.recording => tr('RECORDING'),
      DvrRecordingStatus.completed =>
        recording.hasMedia
            ? (recording.hasGaps ? tr('SAVED · GAPS') : tr('SAVED'))
            : tr('NO MEDIA'),
      DvrRecordingStatus.interrupted =>
        recording.hasMedia ? tr('INTERRUPTED · PARTIAL') : tr('INTERRUPTED · NO MEDIA'),
      DvrRecordingStatus.failed =>
        recording.hasMedia ? tr('FAILED · PARTIAL') : tr('FAILED'),
    };
    final icon = switch (recording.status) {
      DvrRecordingStatus.recording => Icons.fiber_manual_record,
      DvrRecordingStatus.completed => Icons.video_file_outlined,
      DvrRecordingStatus.interrupted => Icons.warning_amber_rounded,
      DvrRecordingStatus.failed => Icons.error_outline,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? AppColors.panelHi : AppColors.panel,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                canRequestFocus: false,
                borderRadius: BorderRadius.circular(AppRadius.tile),
                onTap: onSelect,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                  child: Row(
                    children: [
                      Icon(icon, color: AppColors.accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              recording.channelName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: AppColors.textLo),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '$status  ·  ${_formatDateTime(recording.startedAt)}  ·  ${_formatDuration(duration)}  ·  ${_formatBytes(recording.bytes)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color:
                                        recording.status ==
                                            DvrRecordingStatus.failed
                                        ? AppColors.danger
                                        : AppColors.textLo,
                                  ),
                            ),
                            if (recording.status == DvrRecordingStatus.failed &&
                                recording.error != null)
                              Text(
                                tr(recording.error!),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: AppColors.danger),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _RowAction(
              icon: recordingNow
                  ? Icons.stop_circle_outlined
                  : Icons.play_arrow,
              label: recordingNow ? tr('Stop recording') : tr('Play recording'),
              selected: selected && !deleteColumn,
              enabled: !working && (recordingNow || canPlay),
              onPressed: recordingNow ? onStop : onPlay,
            ),
            _RowAction(
              icon: Icons.delete_outline,
              label: tr('Delete recording'),
              selected: selected && deleteColumn,
              enabled: !working && canDelete,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({
    required this.schedule,
    required this.selected,
    required this.deleteColumn,
    required this.working,
    required this.onSelect,
    required this.onCancel,
    required this.onRemove,
  });

  final DvrSchedule schedule;
  final bool selected;
  final bool deleteColumn;
  final bool working;
  final VoidCallback onSelect;
  final VoidCallback onCancel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final status = switch (schedule.status) {
      DvrScheduleStatus.scheduled => tr('SCHEDULED'),
      DvrScheduleStatus.starting => tr('STARTING'),
      DvrScheduleStatus.recording => tr('RECORDING'),
      DvrScheduleStatus.completed => tr('COMPLETED'),
      DvrScheduleStatus.interrupted => tr('INTERRUPTED'),
      DvrScheduleStatus.missed => tr('MISSED'),
      DvrScheduleStatus.failed => tr('FAILED'),
      DvrScheduleStatus.cancelled => tr('CANCELLED'),
      DvrScheduleStatus.conflict => tr('CONFLICT'),
    };
    final details =
        schedule.error ??
        (schedule.startedLate
            ? tr('Started late; the beginning may be missing.')
            : tr('Padding: {before} min before · {after} min after{repeat}', {
                'before': schedule.startPadding.inMinutes,
                'after': schedule.endPadding.inMinutes,
                'repeat': schedule.isRecurring ? tr(' · Repeats weekly') : '',
              }));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? AppColors.panelHi : AppColors.panel,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                canRequestFocus: false,
                onTap: onSelect,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                  child: Row(
                    children: [
                      Icon(
                        schedule.isActive
                            ? Icons.fiber_manual_record
                            : Icons.schedule,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              schedule.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(
                              '$status · ${schedule.channelName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              '${_formatDateTime(schedule.startsAt)} → ${_formatDateTime(schedule.endsAt)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            Text(
                              tr(details),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: AppColors.textLo),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _RowAction(
              icon: Icons.cancel_outlined,
              label: schedule.isActive
                  ? tr('Stop scheduled recording')
                  : tr('Cancel schedule'),
              selected: selected && !deleteColumn,
              enabled: !working && schedule.isPending,
              onPressed: onCancel,
            ),
            _RowAction(
              icon: Icons.delete_outline,
              label: tr('Remove schedule history'),
              selected: selected && deleteColumn,
              enabled: !working && !schedule.isPending,
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    label: label,
    child: Tooltip(
      message: label,
      child: InkWell(
        canRequestFocus: false,
        onTap: enabled ? onPressed : null,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: selected ? AppColors.accent.withValues(alpha: 0.18) : null,
            border: selected
                ? Border.all(color: AppColors.accent, width: 2)
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            color: enabled ? AppColors.textHi : AppColors.textLo,
            size: 22,
          ),
        ),
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatDuration(Duration value) {
  final seconds = value.inSeconds.clamp(0, 999999999).toInt();
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${two(minutes)}:${two(remaining)}';
  return '${two(minutes)}:${two(remaining)}';
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  if (AppLanguageController.instance.locale.languageCode == 'pl') {
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $hour:$minute $period';
}
