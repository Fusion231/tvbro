import 'package:flutter/material.dart';

import '../dvr/dvr_scheduler.dart';
import '../dvr/dvr_service.dart';
import '../l10n/app_localizations.dart';
import '../data/supporter_access.dart';
import '../sources/source.dart';
import '../widgets/tv_text_field.dart';
import '../widgets/supporter_gate.dart';

/// Used for both an EPG occurrence and a custom channel/time recording.
Future<DvrSchedule?> showRecordingScheduleDialog(
  BuildContext context, {
  required String sourceId,
  required Channel channel,
  Programme? programme,
  DvrScheduler? scheduler,
  String? profileId,
  SupporterAccess? supporterAccess,
}) => showDialog<DvrSchedule>(
  context: context,
  builder: (_) => _RecordingScheduleDialog(
    sourceId: sourceId,
    channel: channel,
    programme: programme,
    scheduler: scheduler ?? DvrScheduler.instance,
    profileId: profileId,
    supporterAccess: supporterAccess ?? SupporterAccess.instance,
  ),
);

class _RecordingScheduleDialog extends StatefulWidget {
  const _RecordingScheduleDialog({
    required this.sourceId,
    required this.channel,
    required this.scheduler,
    this.programme,
    this.profileId,
    required this.supporterAccess,
  });

  final String sourceId;
  final Channel channel;
  final Programme? programme;
  final DvrScheduler scheduler;
  final String? profileId;
  final SupporterAccess supporterAccess;

  @override
  State<_RecordingScheduleDialog> createState() =>
      _RecordingScheduleDialogState();
}

class _RecordingScheduleDialogState extends State<_RecordingScheduleDialog> {
  late final _title = TextEditingController(
    text: widget.programme?.title ?? '',
  );
  late DateTime _start =
      widget.programme?.start.toLocal() ??
      DateTime.now().add(const Duration(minutes: 5));
  late DateTime _end =
      widget.programme?.stop.toLocal() ?? _start.add(const Duration(hours: 1));
  int _before = 0;
  int _after = 0;
  final Set<int> _weekdays = {};
  bool _saving = false;
  bool _checkingAccess = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickTime(bool start) async {
    final previous = start ? _start : _end;
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day);
    final initial = previous.isBefore(first) ? first : previous;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: first.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(previous),
    );
    if (time == null || !mounted) return;
    setState(() {
      final value = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (start) {
        final duration = _end.difference(_start);
        _start = value;
        if (!_end.isAfter(_start)) _end = value.add(duration);
      } else {
        _end = value;
      }
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving || _checkingAccess) return;
    if (_weekdays.isNotEmpty) {
      setState(() => _checkingAccess = true);
      final allowed = await requireSupporter(
        context,
        SupporterFeature.recurringRecordings,
        access: widget.supporterAccess,
      );
      if (!mounted) return;
      setState(() => _checkingAccess = false);
      if (!allowed) return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.scheduler.schedule(
        sourceId: widget.sourceId,
        channelId: widget.channel.id,
        channelName: widget.channel.name,
        programmeTitle: _title.text.trim().isEmpty ? null : _title.text.trim(),
        startsAt: _start,
        endsAt: _end,
        startPadding: Duration(minutes: _before),
        endPadding: Duration(minutes: _after),
        repeatWeekdays: _weekdays,
        profileId: widget.profileId,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is DvrException
              ? tr(error.message)
              : tr('The recording schedule could not be saved.'),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _selectWeekday(int day, bool selected) async {
    if (_checkingAccess || _saving) return;
    if (!selected) {
      setState(() => _weekdays.remove(day));
      return;
    }
    setState(() => _checkingAccess = true);
    final allowed = await requireSupporter(
      context,
      SupporterFeature.recurringRecordings,
      access: widget.supporterAccess,
    );
    if (!mounted) return;
    setState(() {
      _checkingAccess = false;
      if (allowed) _weekdays.add(day);
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Schedule recording')),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.channel.name,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            TvTextField(
              controller: _title,
              hintText: tr('Recording title (optional)'),
              label: tr('Title'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              autofocus: true,
              onPressed: _saving ? null : () => _pickTime(true),
              icon: const Icon(Icons.event),
              label: Text(tr('Start: {time}', {'time': _date(_start)})),
            ),
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _pickTime(false),
              icon: const Icon(Icons.event_available),
              label: Text(tr('End: {time}', {'time': _date(_end)})),
            ),
            const SizedBox(height: 12),
            _paddingPicker(
              tr('Start early'),
              _before,
              (value) => setState(() => _before = value),
            ),
            _paddingPicker(
              tr('Finish late'),
              _after,
              (value) => setState(() => _after = value),
            ),
            const SizedBox(height: 12),
            Text(tr('Repeat on (leave empty for once)')),
            Wrap(
              spacing: 6,
              children: [
                for (var day = 1; day <= 7; day++)
                  FilterChip(
                    label: Text(
                      tr(
                        const [
                          'Mon',
                          'Tue',
                          'Wed',
                          'Thu',
                          'Fri',
                          'Sat',
                          'Sun',
                        ][day - 1],
                      ),
                    ),
                    selected: _weekdays.contains(day),
                    onSelected: _saving || _checkingAccess
                        ? null
                        : (selected) => _selectWeekday(day, selected),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'TVBro must remain running and the device awake. Schedules are saved on this device; recording cannot start after force-stop or while it is switched off.',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: Text(tr('Cancel')),
      ),
      FilledButton(
        onPressed: _saving || _checkingAccess ? null : _save,
        child: Text(_saving ? tr('Saving…') : tr('Schedule')),
      ),
    ],
  );

  Widget _paddingPicker(String label, int value, ValueChanged<int> onChanged) =>
      DropdownButtonFormField<int>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final minutes in const [0, 1, 2, 5, 10, 15, 30])
            DropdownMenuItem(
              value: minutes,
              child: Text(
                minutes == 0
                    ? tr('On time')
                    : tr('{minutes} minutes', {'minutes': minutes}),
              ),
            ),
        ],
        onChanged: _saving
            ? null
            : (next) {
                if (next != null) onChanged(next);
              },
      );
}

String _date(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}
