import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common.dart';

/// PIN entry that unlocks the signing key stored on this phone.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_pin.text.length < 4 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await StoreScope.of(context).unlock(_pin.text);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = 'Wrong PIN';
        _pin.clear();
      });
    }
  }

  Future<void> _reset() async {
    final store = StoreScope.of(context);
    final yes = await confirmReset(context);
    if (yes) await store.reset();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = StoreScope.of(context).lockedName;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                const Center(child: LogoTile(size: 72)),
                const SizedBox(height: 16),
                const Center(child: Wordmark(size: 30)),
                const SizedBox(height: 28),
                Text(name ?? 'Locked', style: t.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text('Enter your PIN to unlock your signing key',
                    style: t.bodyMedium?.copyWith(color: Brand.bark), textAlign: TextAlign.center),
                const SizedBox(height: 20),
                TextField(
                  controller: _pin,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: t.headlineSmall?.copyWith(letterSpacing: 8),
                  decoration: InputDecoration(counterText: '', errorText: _error, hintText: 'PIN'),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _pin.text.length >= 4 && !_busy ? _submit : null,
                  icon: _busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.lock_open),
                  label: const Text('Unlock'),
                ),
                const SizedBox(height: 8),
                TextButton(onPressed: _reset, child: const Text('Reset this device')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> confirmReset(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Brand.cream,
        title: const Text('Reset this device?'),
        content: const Text(
            'This deletes your signing key, certificate and every record stored on this phone. '
            'Records already shared with the cluster stay on the other phones.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.t1),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    ) ??
    false;
