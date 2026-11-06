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
  });

  final EntryType type;
  final User author;
  final DateTime time;
  final String text;
  final Map<String, String> fields;
  Reach reach;
}

class Patient {
  Patient({
    required this.id,
    required this.arrival,
    required this.description,
    required this.priority,
    required this.location,
    required this.entries,
  });

  final String id;
  final DateTime arrival;
  final String description;
  Priority priority;
  final String location;
  final List<Entry> entries;

  bool has(EntryType t) => entries.any((e) => e.type == t);

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

class MeshLog {
  MeshLog(this.time, this.text, {this.bad = false});
  final DateTime time;
  final String text;
  final bool bad;
}
