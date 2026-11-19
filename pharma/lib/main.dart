import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

const String databaseUrl = 'https://drugs-6e4f8-default-rtdb.firebaseio.com';
late FirebaseDatabase rtdb;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MedicineStore.instance.open();
  try {
    await Firebase.initializeApp();
    rtdb = FirebaseDatabase.instanceFor(app: Firebase.app(), databaseURL: databaseUrl);
    rtdb.setPersistenceEnabled(true);
    SyncService.instance.start();
  } catch (e) {
    debugPrint('Firebase initialization unavailable: $e');
  }
  runApp(const PharmaHashiApp());
}

class MedicineStore {
  MedicineStore._();
  static final instance = MedicineStore._();
  late Database db;

  Future<void> open() async {
    final path = p.join(await getDatabasesPath(), 'pharma_hashi_medicines.db');
    db = await openDatabase(path, version: 1, onCreate: (d, v) async {
      await d.execute('CREATE TABLE medicines (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
      await d.execute('CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)');
    });
  }

  Future<List<Medicine>> all() async {
    final rows = await db.query('medicines', orderBy: 'id');
    return rows.map((r) => Medicine(r['id'] as String, jsonDecode(r['data'] as String) as Map<String, dynamic>)).toList();
  }

  Future<void> replaceAll(Map<String, dynamic> records) async {
    final batch = db.batch();
    batch.delete('medicines');
    records.forEach((id, value) {
      if (value is Map) {
        batch.insert('medicines', {'id': id, 'data': jsonEncode(Map<String, dynamic>.from(value))}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    batch.insert('metadata', {'key': 'last_sync', 'value': DateTime.now().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  }

  Future<String?> lastSync() async {
    final rows = await db.query('metadata', where: 'key=?', whereArgs: ['last_sync'], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }
}

class Medicine {
  final String id;
  final Map<String, dynamic> fields;
  Medicine(this.id, this.fields);
  String get generic => (fields['الاسم العلمي'] ?? fields['الاسم'] ?? 'دواء بدون اسم').toString();
  String get trade => (fields['الاسم التجاري'] ?? '').toString();
  String get group => (fields['المجموعة الدوائية'] ?? '').toString();
  String get searchable => fields.entries.map((e) => '${e.key} ${e.value ?? ''}').join(' ').toLowerCase();
}

class SyncService {
  SyncService._();
  static final instance = SyncService._();
  StreamSubscription<DatabaseEvent>? subscription;
  final status = ValueNotifier<String>('يعمل دون اتصال — البيانات المحفوظة متاحة');

  void start() {
    if (subscription != null) return;
    final ref = rtdb.ref('medicines');
    subscription = ref.onValue.listen((event) async {
      final raw = event.snapshot.value;
      if (raw is Map) {
        final records = <String, dynamic>{};
        raw.forEach((key, value) { if (value is Map) records[key.toString()] = Map<String, dynamic>.from(value); });
        await MedicineStore.instance.replaceAll(records);
        status.value = 'تم تحديث ${records.length} دواء من الإنترنت';
      } else {
        status.value = 'لا توجد بيانات أدوية على الخادم';
      }
    }, onError: (e) {
      status.value = 'تعذر الاتصال بالخادم — نعرض النسخة المحلية';
      debugPrint('Realtime Database error: $e');
    });
  }
}

class PharmaHashiApp extends StatelessWidget {
  const PharmaHashiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'فارماء حاشي | دليل الأدوية', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff087f8c)), useMaterial3: true, fontFamily: 'Roboto'),
    home: const MedicineHome(),
  );
}

class MedicineHome extends StatefulWidget {
  const MedicineHome({super.key});
  @override
  State<MedicineHome> createState() => _MedicineHomeState();
}

class _MedicineHomeState extends State<MedicineHome> {
  final search = TextEditingController();
  List<Medicine> medicines = [];
  bool loading = true;
  String query = '';
  @override
  void initState() { super.initState(); load(); search.addListener(() => setState(() => query = search.text.trim().toLowerCase())); }
  Future<void> load() async { final items = await MedicineStore.instance.all(); if (mounted) setState(() { medicines = items; loading = false; }); }
  @override
  void dispose() { search.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final filtered = medicines.where((m) => m.searchable.contains(query)).toList();
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: const Text('فارماء حاشي', style: TextStyle(fontWeight: FontWeight.bold)), centerTitle: true, actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh), tooltip: 'تحديث العرض')]),
      body: Column(children: [
        ValueListenableBuilder<String>(valueListenable: SyncService.instance.status, builder: (_, value, __) => Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9), color: const Color(0xffe5f5f6), child: Text(value, style: const TextStyle(fontSize: 12, color: Color(0xff075e66))))),
        Padding(padding: const EdgeInsets.all(12), child: TextField(controller: search, decoration: InputDecoration(hintText: 'ابحث بالاسم العلمي أو التجاري أو المجموعة أو الوكيل', prefixIcon: const Icon(Icons.search), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)), filled: true, fillColor: Colors.white))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Row(children: [Text('الأدوية', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)), const Spacer(), Text('${filtered.length} دواء', style: const TextStyle(color: Colors.grey))])),
        Expanded(child: loading ? const Center(child: CircularProgressIndicator()) : filtered.isEmpty ? Center(child: Text(medicines.isEmpty ? 'لا توجد بيانات محلية بعد. اتصل بالإنترنت للمزامنة.' : 'لا توجد نتائج مطابقة')) : RefreshIndicator(onRefresh: load, child: ListView.separated(padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), itemCount: filtered.length, separatorBuilder: (_, __) => const SizedBox(height: 7), itemBuilder: (_, i) { final m = filtered[i]; return Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.medication_outlined)), title: Text(m.generic, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text([m.trade, m.group].where((s) => s.isNotEmpty).join(' • '), maxLines: 2, overflow: TextOverflow.ellipsis), trailing: const Icon(Icons.chevron_left), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MedicineDetails(medicine: m)))); }))),
      ]),
    ));
  }
}

class MedicineDetails extends StatelessWidget {
  final Medicine medicine;
  const MedicineDetails({super.key, required this.medicine});
  @override
  Widget build(BuildContext context) {
    final entries = medicine.fields.entries.where((e) => e.value != null && e.value.toString().trim().isNotEmpty && e.value.toString() != '[]').toList();
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(appBar: AppBar(title: const Text('معلومات الدواء')), body: ListView(padding: const EdgeInsets.all(14), children: [Text(medicine.generic, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)), const SizedBox(height: 12), ...entries.map((e) => Card(margin: const EdgeInsets.only(bottom: 8), child: Padding(padding: const EdgeInsets.all(13), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(e.key, style: const TextStyle(color: Color(0xff087f8c), fontWeight: FontWeight.bold)), const SizedBox(height: 5), Text(e.value is List ? (e.value as List).join('، ') : e.value.toString(), style: const TextStyle(height: 1.5))])))), const SizedBox(height: 10), const Text('تنبيه: المعلومات المعروضة مأخوذة من قاعدة البيانات وقد تكون غير مكتملة أو غير مراجعة. يجب التحقق من المصادر الدوائية الموثوقة قبل اتخاذ قرار علاجي.', style: TextStyle(color: Colors.red, height: 1.5))])));
  }
}
