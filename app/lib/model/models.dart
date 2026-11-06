import 'package:flutter/material.dart';

import '../theme.dart';

/// View models built from the signed event log (see core/ and state/app_state.dart).

enum Role {
  triage('Triage', 'Register patients, set priority, record clinical observations', Icons.monitor_heart_outlined),
  clinician('Diagnosis & treatment', 'Record diagnosis, remediations performed and follow-up', Icons.medical_services_outlined),
  admin('Admin', 'Broadcast announcements and messages to the cluster', Icons.campaign_outlined);

  const Role(this.label, this.blurb, this.icon);
  final String label;
  final String blurb;
  final IconData icon;

  String get short => switch (this) {
        Role.triage => 'Triage',
        Role.clinician => 'Dx & Tx',
        Role.admin => 'Admin',
      };
}

enum Priority {
  t1('T1', 'Immediate', Brand.t1),
  t2('T2', 'Delayed', Brand.t2),
  t3('T3', 'Minimal', Brand.t3),
  t4('T4', 'Expectant', Brand.t4);

  const Priority(this.code, this.label, this.color);
  final String code;
  final String label;
  final Color color;
}

class User {
  const User({required this.id, required this.name, required this.roles, required this.deviceId});
  final String id;
  final String name;
  final Set<Role> roles; // a person may hold several roles
  final String deviceId;

  bool has(Role r) => roles.contains(r);

  /// Roles in a stable order for display.
  List<Role> get sortedRoles => Role.values.where(roles.contains).toList();

  String get rolesLabel => sortedRoles.map((r) => r.label).join(', ');
}

/// Where a record has got to: only on this phone, spread over the mesh, or acknowledged by HQ.
enum Reach { local, cluster, hq }

enum EntryType {
  registered('Registered', Icons.person_add_alt_1_outlined),
  priority('Priority changed', Icons.flag_outlined),
  observation('Clinical observation', Icons.monitor_heart_outlined),
  diagnosis('Diagnosis', Icons.biotech_outlined),
  remediation('Remediation performed', Icons.healing_outlined),
  followUp('Recommended follow-up', Icons.event_repeat_outlined);

  const EntryType(this.label, this.icon);
  final String label;
  final IconData icon;

  Role get author => switch (this) {
        EntryType.registered || EntryType.priority || EntryType.observation => Role.triage,
        _ => Role.clinician,
      };
}

class Entry {
  Entry({
    required this.type,
    required this.author,
    required this.time,
    required this.text,
    this.fields = const {},
    this.reach = Reach.cluster,
    this.facility = '',
    this.audit,
    this.priority,
  });

  final EntryType type;
  final User author;
  final DateTime time;
  final String text;
  final Map<String, String> fields;
  Reach reach;
  final String facility;

  /// Set when an HQ auditor ruled on this entry in a conflict.
  final AuditMark? audit;

  /// The priority this entry sets (registration and priority changes only).
  final Priority? priority;

  bool get voided => audit?.voided ?? false;
}

/// An HQ audit decision as it applies to one record.
class AuditMark {
  const AuditMark({required this.voided, required this.note, required this.by, required this.kind});
  final bool voided; // overruled (true) or confirmed (false)
  final String note;
  final String by;
  final String kind; // triage, venue, duplicate

  String get kindLabel => switch (kind) {
        'triage' => 'conflicting triage',
        'venue' => 'patient at two venues',
        'duplicate' => 'duplicate registration',
        _ => kind,
      };
}

class Patient {
  Patient({
    required this.id,
    required this.arrival,
    required this.description,
    required this.priority,
    required this.location,
    required this.entries,
    this.name = '',
    this.ident = '',
    this.facility = '',
  });

  final String id;
  final DateTime arrival;
  final String description;
  Priority priority;
  final String location;
  final List<Entry> entries;
  final String name;
  final String ident; // service number / ID tag
  final String facility;

  /// The registration itself was overruled by an HQ audit (e.g. a duplicate record).
  bool get voided => entries.isNotEmpty && entries.first.type == EntryType.registered && entries.first.voided;

  String get displayName => [name, if (ident.isNotEmpty) 'ID $ident'].where((s) => s.isNotEmpty).join(' · ');

  bool has(EntryType t) => entries.any((e) => e.type == t && !e.voided);

  /// Care stage for the progress strip.
  int get stage {
    if (has(EntryType.followUp)) return 4;
    if (has(EntryType.remediation)) return 3;
    if (has(EntryType.diagnosis)) return 2;
    if (has(EntryType.observation)) return 1;
    return 0;
  }

  Entry get latest => entries.last;

  Reach get reach => entries.map((e) => e.reach).reduce((a, b) => a.index < b.index ? a : b);
}

class Announcement {
  Announcement({
    required this.title,
    required this.body,
    required this.author,
    required this.time,
    this.urgent = false,
    this.fromHq = false,
    this.reach = Reach.cluster,
  });

  final String title;
  final String body;
  final User? author; // null when from HQ
  final DateTime time;
  final bool urgent;
  final bool fromHq;
  Reach reach;
}

/// Recipient of a message: everyone, a role, or one person.
class Audience {
  const Audience.all() : role = null, user = null;
  const Audience.role(Role this.role) : user = null;
  const Audience.user(User this.user) : role = null;
  final Role? role;
  final User? user;

  String get label => user?.name ?? role?.label ?? 'Everyone';

  bool includes(User u) => (role == null && user == null) || (role != null && u.has(role!)) || user?.id == u.id;
}

class Message {
  Message({required this.from, required this.to, required this.body, required this.time, this.reach = Reach.cluster});
  final User from;
  final Audience to;
  final String body;
  final DateTime time;
  Reach reach;
}

/// A device in direct BLE range, joined with its certificate when known.
class PeerView {
  PeerView({
    required this.user,
    required this.nodeId,
    required this.rssi,
    required this.inSync,
    required this.busy,
  });

  final User? user;
  final String nodeId;
  final int rssi;
  final bool inSync;
  final bool busy;
}

// ---------------------------------------------------------------------- inventory

enum StockCategory {
  supply('Supplies', Icons.medication_outlined),
  equipment('Equipment', Icons.monitor_heart_outlined),
  resource('Resources', Icons.local_shipping_outlined);

  const StockCategory(this.label, this.icon);
  final String label;
  final IconData icon;
}

class StockItem {
  StockItem({
    required this.name,
    required this.category,
    required this.unit,
    required this.facility,
    this.qty = 0,
    this.min = 0,
    this.updated,
    this.by,
  });

  String name;
  StockCategory category;
  String unit;
  final String facility;
  int qty;
  int min;
  DateTime? updated;
  User? by;
  Reach reach = Reach.cluster;

  bool get low => min > 0 && qty <= min;
}

enum RequestStatus {
  pending('Pending', Brand.ember),
  approved('Approved', Color(0xFF1F4C86)),
  dispatched('Dispatched', Brand.ok),
  denied('Denied', Brand.t1);

  const RequestStatus(this.label, this.color);
  final String label;
  final Color color;
}

class SupplyRequest {
  SupplyRequest({
    required this.rid,
    required this.item,
    required this.qty,
    required this.unit,
    required this.urgent,
    required this.note,
    required this.facility,
    required this.by,
    required this.time,
    required this.reach,
  });

  final String rid;
  final String item;
  final int qty;
  final String unit;
  final bool urgent;
  final String note;
  final String facility;
  final User by;
  final DateTime time;
  Reach reach;
  RequestStatus status = RequestStatus.pending;
  String hqNote = '';
  DateTime? updated;
}

class MeshLog {
  MeshLog(this.time, this.text, {this.bad = false});
  final DateTime time;
  final String text;
  final bool bad;
}
