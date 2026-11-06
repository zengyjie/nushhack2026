import 'package:flutter/material.dart';

import '../model/models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// First launch: name, role and PIN. Generates this phone's Ed25519 key and a
/// demo certificate signed with the bundled HQ key.
class EnrolScreen extends StatefulWidget {
  const EnrolScreen({super.key});

  @override
  State<EnrolScreen> createState() => _EnrolScreenState();
}

class _EnrolScreenState extends State<EnrolScreen> {
  final _name = TextEditingController();
  final _pin = TextEditingController();
  final Set<Role> _roles = {};
  bool _issuing = false;

  bool get _ready => _name.text.trim().isNotEmpty && _roles.isNotEmpty && _pin.text.length >= 4;

  Future<void> _submit() async {
    setState(() => _issuing = true);
    try {
      await StoreScope.of(context).enrol(_name.text.trim(), {..._roles}, _pin.text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _issuing = false);
      toast(context, 'Enrolment failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
              children: [
                const Center(child: LogoTile(size: 84)),
                const SizedBox(height: 18),
                const Center(child: Wordmark(size: 34)),
                const SizedBox(height: 8),
                Center(
                  child: Text('Field hospital records, offline first',
                      style: t.bodyMedium?.copyWith(color: Brand.bark)),
                ),
                const SizedBox(height: 28),
                Text('Set up this device', style: t.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Your key stays on this phone. HQ\'s certificate tells every other phone who you are and what your role allows.',
                  style: t.bodyMedium?.copyWith(color: Brand.bark),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Rank and name', prefixIcon: Icon(Icons.badge_outlined)),
                  onChanged: (_) => setState(() {}),
                ),
                const SectionLabel('Roles · pick one or more'),
                for (final r in Role.values) ...[
                  _RoleCard(
                    role: r,
                    selected: _roles.contains(r),
                    onTap: () => setState(() => _roles.contains(r) ? _roles.remove(r) : _roles.add(r)),
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: _pin,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: 'Device PIN',
                    helperText: 'Unlocks your signing key',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _ready && !_issuing ? _submit : null,
                  icon: _issuing
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.key_outlined),
                  label: Text(_issuing ? 'Generating key…' : 'Generate key and get certificate'),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  const Icon(Icons.info_outline, size: 16, color: Brand.bark),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Demo build: certificates are signed with a bundled HQ demo key.',
                        style: t.bodySmall?.copyWith(color: Brand.bark)),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.role, required this.selected, required this.onTap});
  final Role role;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Material(
      color: selected ? Brand.ember.withValues(alpha: 0.10) : Brand.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
        side: BorderSide(color: selected ? Brand.ember : Brand.stone, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Brand.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: selected ? Brand.ember : Brand.cream,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(role.icon, color: selected ? Colors.white : Brand.bark),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(role.label, style: t.titleMedium),
                const SizedBox(height: 2),
                Text(role.blurb, style: t.bodySmall?.copyWith(color: Brand.bark)),
              ]),
            ),
            Icon(selected ? Icons.check_box : Icons.check_box_outline_blank,
                color: selected ? Brand.ember : Brand.stone),
          ]),
        ),
      ),
    );
  }
}
