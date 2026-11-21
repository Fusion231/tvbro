import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/cloud_config.dart';
import '../data/distribution_channel.dart';
import '../data/supporter_access.dart';
import '../l10n/app_localizations.dart';

bool get canOpenGooglePlaySupporter =>
    DistributionConfig.channel == DistributionChannel.googlePlay &&
    defaultTargetPlatform == TargetPlatform.android &&
    CloudConfig.isConfigured;

Future<bool> showGooglePlaySupporter(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const _GooglePlaySupporter(),
    ) ??
    false;

class _GooglePlaySupporter extends StatefulWidget {
  const _GooglePlaySupporter();

  @override
  State<_GooglePlaySupporter> createState() => _GooglePlaySupporterState();
}

class _GooglePlaySupporterState extends State<_GooglePlaySupporter>
    with WidgetsBindingObserver {
  static const _billing = MethodChannel('iptvs/google_play_supporter');
  final List<({String id, String price, int devices})> _plans = [];
  String? _product;
  String? _selected;
  String? _checkout;
  String? _message;
  bool _working = true;
  bool _playManaged = false;
  bool _canPurchase = false;
  bool _pairRequired = false;
  bool _accessRefreshed = false;
  bool _resumeAfterOperation = false;
  MethodCall? _deferredUpdate;

  SupabaseClient get _api => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _billing.setMethodCallHandler(_updated);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _billing.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _product == null) return;
    if (_working) {
      _resumeAfterOperation = true;
    } else {
      unawaited(_restore(quiet: true));
    }
  }

  Future<Map<String, dynamic>> _request(
    String action, [
    Map<String, String> arguments = const {},
  ]) async {
    final response = await _api.functions
        .invoke('google-play-billing', body: {'action': action, ...arguments})
        .timeout(const Duration(seconds: 38));
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> _readStatus() async {
    final status = await _request('status');
    _product = status['product_id'] as String;
    _playManaged = status['play_managed'] == true;
    _canPurchase = status['can_purchase'] == true;
  }

  Future<void> _load() async {
    try {
      if (_api.auth.currentSession == null) {
        _pairRequired = true;
        return;
      }
      await _readStatus();
      if (!_canPurchase) return;
      final details = await _billing
          .invokeListMethod<Map>('plans', {'product': _product})
          .timeout(const Duration(seconds: 15));
      for (final plan in details ?? const <Map>[]) {
        final id = plan['id'] as String;
        final devices = int.tryParse(id.replaceFirst('annual-', '')) ?? 0;
        if (id == 'annual-$devices' &&
            devices >= 5 &&
            devices <= 100 &&
            devices % 5 == 0) {
          _plans.add((
            id: id,
            price: plan['price'] as String,
            devices: devices,
          ));
        }
      }
      _plans.sort((a, b) => a.devices.compareTo(b.devices));
      if (_plans.isEmpty) {
        _message = 'Google Play plans are currently unavailable.';
      } else {
        _selected = _plans.first.id;
      }
    } on FunctionException catch (error) {
      if (error.status == 403) {
        _pairRequired = true;
      } else {
        _message = 'Google Play plans are currently unavailable.';
      }
    } catch (_) {
      _message = 'Google Play plans are currently unavailable.';
    } finally {
      _finished();
    }
  }

  void _finished() {
    if (!mounted) return;
    setState(() => _working = false);
    if (_deferredUpdate case final update?) {
      _deferredUpdate = null;
      unawaited(_updated(update));
      return;
    }
    if (_resumeAfterOperation) {
      _resumeAfterOperation = false;
      unawaited(_restore(quiet: true));
    }
  }

  Future<void> _clearCheckout() async {
    final checkout = _checkout;
    _checkout = null;
    if (checkout != null) await _request('cancel', {'checkout_id': checkout});
  }

  Future<void> _buy() async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final reservation = await _request('prepare');
      _checkout = reservation['checkout_id'] as String;
      if (!mounted) {
        await _clearCheckout();
        return;
      }
      final result = await _billing
          .invokeMethod<int>('buy', {
            'product': _product,
            'plan': _selected,
            'account': reservation['account_id'],
            'checkout': _checkout,
          })
          .timeout(const Duration(seconds: 15));
      if (result == 0) return;
      await _clearCheckout();
      _message = result == 7
          ? 'Google Play already has a purchase. Restore your purchase below.'
          : 'Google Play could not start the purchase. Try again.';
    } catch (error) {
      _message = 'Google Play could not start the purchase. Try again.';
      // A timed-out platform call can still open the purchase sheet.
      if (error is PlatformException) {
        try {
          await _clearCheckout();
        } catch (_) {
          /* Checkout expires on the server. */
        }
      }
    } finally {
      _finished();
    }
  }

  Future<void> _updated(MethodCall call) async {
    if (!mounted || call.method != 'updated' || _product == null) return;
    final event = call.arguments as Map;
    if (_working) {
      _deferredUpdate = call;
      return;
    }
    setState(() => _working = true);
    try {
      switch (event['result']) {
        case 0:
          await _confirm(event['purchases'] as List, quiet: false);
        case 1:
          await _clearCheckout();
          _message = null;
        default:
          await _clearCheckout();
          _message = 'Google Play could not finish the purchase. Restore it if you were charged.';
      }
    } catch (_) {
      _message = 'Google Play could not confirm the purchase. Restore it to try again.';
    } finally {
      _finished();
    }
  }

  Future<void> _restore({bool quiet = false}) async {
    if (_working || _product == null) return;
    setState(() => _working = true);
    try {
      final purchases = await _billing
          .invokeListMethod<Map>('purchases', {'product': _product})
          .timeout(const Duration(seconds: 15));
      await _confirm(purchases ?? const [], quiet: quiet);
    } catch (_) {
      if (!quiet) _message = 'Google Play could not confirm the purchase. Restore it to try again.';
    } finally {
      _finished();
    }
  }

  Future<void> _confirm(List purchases, {required bool quiet}) async {
    var found = false;
    for (final value in purchases.whereType<Map>()) {
      if (!(value['products'] as List).contains(_product)) continue;
      found = true;
      final status = await _request('confirm', {
        'purchase_token': value['token'] as String,
      });
      _checkout = null;
      if (status['state'] == 'pending') {
        _message = 'Google Play is waiting for payment. Access will update after confirmation.';
      } else if ((status['device_limit'] as int? ?? 0) > 0) {
        final access = await SupporterAccess.instance.status(
          reportErrors: true,
        );
        _accessRefreshed = access.isActiveAt(DateTime.now());
        _message = _accessRefreshed ? 'Supporter is active on this device.' : 'The purchase is linked to your account. Assign this device a place in the panel.';
      } else if (!quiet) {
        _message =
            'There is no active Google Play subscription for this purchase.';
      }
    }
    if (found) await _readStatus();
    if (!found && !quiet) {
      _message = 'No Google Play purchase was found on this account.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
    return AlertDialog(
      scrollable: true,
      title: const Text('Supporter · Google Play'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pairRequired)
            Text(
              tr(
                'Pair this device with your TVBro account before buying Supporter.',
              ),
            ),
          if (_canPurchase && _plans.isNotEmpty) ...[
            Text(
              tr(
                'Choose how many devices to include. The subscription renews annually.',
              ),
            ),
            DropdownButton<String>(
              isExpanded: true,
              value: _selected,
              onChanged: _working
                  ? null
                  : (value) => setState(() => _selected = value),
              items: [
                for (final plan in _plans)
                  DropdownMenuItem(
                    value: plan.id,
                    child: Text(
                      tr('{count} devices · {price}/year', {
                        'count': plan.devices,
                        'price': plan.price,
                      }),
                    ),
                  ),
              ],
            ),
          ],
          if (product != null && !_canPurchase && !_playManaged)
            Text(
              tr(
                'Your TVBro account already has a subscription or a checkout in progress.',
              ),
            ),
          if (_message case final message?)
            Semantics(liveRegion: true, child: Text(tr(message))),
          if (_working) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_accessRefreshed),
          child: Text(tr('Close')),
        ),
        if (product != null)
          TextButton(
            onPressed: _working ? null : _restore,
            child: Text(tr('Restore purchase')),
          ),
        if (_playManaged && product != null)
          OutlinedButton(
            onPressed: () => launchUrl(
              Uri.https('play.google.com', '/store/account/subscriptions', {
                'sku': product,
                'package': 'app.tvbro.player',
              }),
              mode: LaunchMode.externalApplication,
            ),
            child: Text(tr('Manage in Google Play')),
          ),
        if (_canPurchase && _selected != null)
          FilledButton(
            onPressed: _working || _checkout != null ? null : _buy,
            child: Text(tr('Buy with Google Play')),
          ),
      ],
    );
  }
}
