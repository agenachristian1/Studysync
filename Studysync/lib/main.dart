import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

// Global helper function for 12-hour time format
String format12HourTime(TimeOfDay time) {
  final period = time.hour >= 12 ? 'PM' : 'AM';
  final hour = time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour);
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute $period';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  runApp(const StudySyncApp());
}

// ======================================================
// NOTIFICATIONS
// ======================================================

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // ─── Channel constants ───────────────────────────────────────────────────
  static const String _channelId = 'study_reminders';
  static const String _channelName = 'Study Reminders';
  static const String _channelDesc = 'Task and study reminder notifications';

  // ─── 1. INITIALIZATION ──────────────────────────────────────────────────
  static Future<void> init() async {
    // Set timezone to Asia/Manila (Philippines, UTC+8) — no extra package needed
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Manila'));

    // Android init settings
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // Handle notification tap here if needed
        print('🔔 Notification tapped: ${response.payload}');
      },
    );

    // ─── 2. NOTIFICATION CHANNEL SETUP (Android) ────────────────────────
    await _createNotificationChannel();

    // ─── 3. PERMISSION REQUESTS ─────────────────────────────────────────
    await _requestPermissions();
  }

  // ─── CHANNEL SETUP ──────────────────────────────────────────────────────
  static Future<void> _createNotificationChannel() async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.max,
      enableVibration: true,
      playSound: true,
      showBadge: true,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  // ─── PERMISSION REQUESTS ────────────────────────────────────────────────
  static Future<void> _requestPermissions() async {
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    // Request notification permission (Android 13+)
    await androidPlugin?.requestNotificationsPermission();

    // Request exact alarm permission (Android 12+)
    await androidPlugin?.requestExactAlarmsPermission();
  }

  // ─── ANDROID NOTIFICATION DETAILS ───────────────────────────────────────
  static AndroidNotificationDetails _androidDetails({
    bool fullScreen = false,
  }) {
    return AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
      fullScreenIntent: fullScreen,
      icon: '@mipmap/ic_launcher',
    );
  }

  // ─── 4. SCHEDULED NOTIFICATION (one-time) ───────────────────────────────
  static Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDateTime,
    String? payload,
  }) async {
    final tz.TZDateTime tzScheduled =
        tz.TZDateTime.from(scheduledDateTime, tz.local);

    final now = tz.TZDateTime.now(tz.local);
    if (tzScheduled.isBefore(now)) {
      print('⚠️ Skipped: scheduled time is in the past (\$tzScheduled)');
      return;
    }

    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tzScheduled,
        NotificationDetails(android: _androidDetails(fullScreen: true)),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
      print('✅ Scheduled: "\$title" at \$tzScheduled');
    } catch (e) {
      print('❌ Failed to schedule: \$e');
    }
  }

  // ─── 5. DAILY REPEATING NOTIFICATION ────────────────────────────────────
  /// Schedules a notification every day at [hour]:[minute] (24-hour format).
  /// Example: scheduleDailyNotification(hour: 8, minute: 0) → fires at 8:00 AM daily
  static Future<void> scheduleDailyNotification({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
    String? payload,
  }) async {
    final tz.TZDateTime scheduledTime = _nextInstanceOfTime(hour, minute);

    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        scheduledTime,
        NotificationDetails(android: _androidDetails()),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time, // Makes it repeat daily
        payload: payload,
      );
      print('✅ Daily notification set: "\$title" at \$hour:\$minute every day');
    } catch (e) {
      print('❌ Failed to schedule daily notification: \$e');
    }
  }

  /// Returns the next occurrence of [hour]:[minute] in Asia/Manila time.
  /// If that time has already passed today, it schedules for tomorrow.
  static tz.TZDateTime _nextInstanceOfTime(int hour, int minute) {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );

    // If the time already passed today, move to tomorrow
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    return scheduled;
  }

  // ─── SHOW IMMEDIATE NOTIFICATION ────────────────────────────────────────
  static Future<void> showNow({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: _androidDetails()),
      payload: payload,
    );
    print('🔔 Immediate notification shown: "\$title"');
  }

  // ─── CANCEL ─────────────────────────────────────────────────────────────
  static Future<void> cancel(int id) async {
    await _plugin.cancel(id);
    print('🗑️ Cancelled notification ID: \$id');
  }

  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
    print('🗑️ All notifications cancelled');
  }

  // ─── TASK REMINDER HELPERS (for StudySync) ──────────────────────────────
  static int idFromString(String id) => id.hashCode & 0x7fffffff;

  static Future<void> scheduleTaskReminder({
    required String id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    await scheduleNotification(
      id: idFromString(id),
      title: title,
      body: body,
      scheduledDateTime: scheduledDate,
      payload: id,
    );
  }

  static Future<void> cancelTaskReminder(String id) async {
    await cancel(idFromString(id));
  }

  // ─── TEST NOTIFICATION ───────────────────────────────────────────────────
  static Future<void> testNotification() async {
    await showNow(
      id: 999,
      title: '🔔 Test Notification',
      body: 'Notifications are working correctly!',
    );
  }
}

// ======================================================
// APP ROOT
// ======================================================

class StudySyncApp extends StatefulWidget {
  const StudySyncApp({super.key});

  @override
  State<StudySyncApp> createState() => _StudySyncAppState();
}

class _StudySyncAppState extends State<StudySyncApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _updateThemeMode(bool isDark) {
    setState(() {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return StudySyncScope(
      onThemeChanged: _updateThemeMode,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'StudySync',
        themeMode: _themeMode,
        theme: _buildLightTheme(),
        darkTheme: _buildDarkTheme(),
        home: const StudySyncHome(),
      ),
    );
  }

  ThemeData _buildLightTheme() {
    const seed = Color(0xFF7C4DFF);
    final base = ThemeData(brightness: Brightness.light);
    final poppins = GoogleFonts.poppinsTextTheme(base.textTheme);
    final orbitron = GoogleFonts.orbitronTextTheme(base.textTheme);

    return ThemeData(
      useMaterial3: true,
      colorSchemeSeed: seed,
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F7FF),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFFFFFFFF),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: MaterialStatePropertyAll(
          GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600),
        ),
        height: 76,
        indicatorColor: const Color(0xFF7C4DFF).withOpacity(0.16),
        iconTheme: MaterialStatePropertyAll(
          IconThemeData(color: const Color(0xFF111827)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF4F6FB),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
      textTheme: poppins.copyWith(
        titleLarge: orbitron.titleLarge,
        headlineMedium: orbitron.headlineMedium,
        titleMedium: orbitron.titleMedium,
        bodyLarge: poppins.bodyLarge?.copyWith(color: const Color(0xFF111827)),
        bodyMedium: poppins.bodyMedium?.copyWith(color: const Color(0xFF111827)),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    const seed = Color(0xFF7C4DFF);
    final base = ThemeData(brightness: Brightness.dark);
    final poppins = GoogleFonts.poppinsTextTheme(base.textTheme);
    final orbitron = GoogleFonts.orbitronTextTheme(base.textTheme);

    return ThemeData(
      useMaterial3: true,
      colorSchemeSeed: seed,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF090B10),
      cardTheme: CardThemeData(
        color: const Color(0xFF1A1F2E),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: const Color(0xFF7C4DFF).withOpacity(0.22),
        labelTextStyle: MaterialStatePropertyAll(
          GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600),
        ),
        height: 76,
        iconTheme: MaterialStatePropertyAll(
          IconThemeData(color: Colors.white70),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF111827),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
      textTheme: poppins.copyWith(
        titleLarge: orbitron.titleLarge,
        headlineMedium: orbitron.headlineMedium,
        titleMedium: orbitron.titleMedium,
        bodyLarge: poppins.bodyLarge?.copyWith(color: const Color(0xFFFFFFFF)),
        bodyMedium: poppins.bodyMedium?.copyWith(color: const Color(0xFFFFFFFF)),
      ),
    );
  }
}

class StudySyncScope extends InheritedWidget {
  final void Function(bool isDark) onThemeChanged;

  const StudySyncScope({
    super.key,
    required this.onThemeChanged,
    required super.child,
  });

  static StudySyncScope of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<StudySyncScope>();
    return scope!;
  }

  @override
  bool updateShouldNotify(covariant StudySyncScope oldWidget) {
    return onThemeChanged != oldWidget.onThemeChanged;
  }
}

// ======================================================
// MODELS
// ======================================================

enum TaskPriority { low, medium, high }

enum TaskFilter { all, pending, completed }

enum TaskSort { upcoming, priority, subject, completedLast }

enum TaskCategory { study, assignment, quiz, exam, project }

class StudyTask {
  String id;
  String title;
  String subject;
  String note;
  DateTime date;
  TimeOfDay startTime;
  TimeOfDay endTime;
  bool completed;
  int colorValue;
  TaskPriority priority;
  bool reminderEnabled;
  TaskCategory category;
  DateTime? deletedAt;

  StudyTask({
    required this.id,
    required this.title,
    required this.subject,
    required this.note,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.completed,
    required this.colorValue,
    required this.priority,
    required this.reminderEnabled,
    required this.category,
    this.deletedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'subject': subject,
      'note': note,
      'date': date.toIso8601String(),
      'startHour': startTime.hour,
      'startMinute': startTime.minute,
      'endHour': endTime.hour,
      'endMinute': endTime.minute,
      'completed': completed,
      'colorValue': colorValue,
      'priority': priority.name,
      'reminderEnabled': reminderEnabled,
      'category': category.name,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory StudyTask.fromMap(Map<String, dynamic> map) {
    return StudyTask(
      id: map['id'],
      title: map['title'],
      subject: map['subject'],
      note: map['note'] ?? '',
      date: DateTime.parse(map['date']),
      startTime: TimeOfDay(
        hour: map['startHour'],
        minute: map['startMinute'],
      ),
      endTime: TimeOfDay(
        hour: map['endHour'],
        minute: map['endMinute'],
      ),
      completed: map['completed'] ?? false,
      colorValue: map['colorValue'] ?? Colors.indigo.value,
      priority: TaskPriority.values.firstWhere(
        (p) => p.name == map['priority'],
        orElse: () => TaskPriority.medium,
      ),
      reminderEnabled: map['reminderEnabled'] ?? false,
      category: TaskCategory.values.firstWhere(
        (c) => c.name == map['category'],
        orElse: () => TaskCategory.study,
      ),
      deletedAt: map['deletedAt'] != null
          ? DateTime.parse(map['deletedAt'])
          : null,
    );
  }
}

class DeadlineItem {
  String id;
  String title;
  String subject;
  DateTime date;
  TaskCategory category;
  String note;
  int colorValue;
  DateTime? deletedAt;

  DeadlineItem({
    required this.id,
    required this.title,
    required this.subject,
    required this.date,
    required this.category,
    required this.note,
    required this.colorValue,
    this.deletedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'subject': subject,
      'date': date.toUtc().toIso8601String(),
      'category': category.name,
      'note': note,
      'colorValue': colorValue,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory DeadlineItem.fromMap(Map<String, dynamic> map) {
    return DeadlineItem(
      id: map['id'],
      title: map['title'],
      subject: map['subject'],
      date: DateTime.parse(map['date']).toLocal(),
      category: TaskCategory.values.firstWhere(
        (c) => c.name == map['category'],
        orElse: () => TaskCategory.exam,
      ),
      note: map['note'] ?? '',
      colorValue: map['colorValue'] ?? Colors.red.value,
      deletedAt: map['deletedAt'] != null
          ? DateTime.parse(map['deletedAt'])
          : null,
    );
  }
}

class NoteItem {
  String text;
  DateTime createdAt;

  NoteItem({
    required this.text,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'text': text,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory NoteItem.fromMap(Map<String, dynamic> map) {
    return NoteItem(
      text: map['text'] ?? '',
      createdAt: map['createdAt'] != null
          ? DateTime.parse(map['createdAt'])
          : DateTime.now(),
    );
  }
}

class AppSettings {
  String displayName;
  bool darkMode;
  int weeklyGoalMinutes;
  bool notificationsEnabled;
  String schoolOrCourse;
  String yearLevel;
  String? profilePhotoBase64;

  AppSettings({
    required this.displayName,
    required this.darkMode,
    required this.weeklyGoalMinutes,
    required this.notificationsEnabled,
    required this.schoolOrCourse,
    required this.yearLevel,
    this.profilePhotoBase64,
  });

  Map<String, dynamic> toMap() {
    return {
      'displayName': displayName,
      'darkMode': darkMode,
      'weeklyGoalMinutes': weeklyGoalMinutes,
      'notificationsEnabled': notificationsEnabled,
      'schoolOrCourse': schoolOrCourse,
      'yearLevel': yearLevel,
      'profilePhotoBase64': profilePhotoBase64,
    };
  }

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    return AppSettings(
      displayName: map['displayName'] ?? 'Student',
      darkMode: map['darkMode'] ?? false,
      weeklyGoalMinutes: map['weeklyGoalMinutes'] ?? 600,
      notificationsEnabled: map['notificationsEnabled'] ?? true,
      schoolOrCourse: map['schoolOrCourse'] ?? '',
      yearLevel: map['yearLevel'] ?? '',
      profilePhotoBase64: map['profilePhotoBase64']?.toString(),
    );
  }
}

class TimetableEntry {
  String id;
  String subject;
  String day;
  TimeOfDay startTime;
  TimeOfDay endTime;
  String room;
  int colorValue;
  DateTime? deletedAt;

  TimetableEntry({
    required this.id,
    required this.subject,
    required this.day,
    required this.startTime,
    required this.endTime,
    required this.room,
    required this.colorValue,
    this.deletedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'subject': subject,
      'day': day,
      'startHour': startTime.hour,
      'startMinute': startTime.minute,
      'endHour': endTime.hour,
      'endMinute': endTime.minute,
      'room': room,
      'colorValue': colorValue,
      'deletedAt': deletedAt?.toIso8601String(),
    };
  }

  factory TimetableEntry.fromMap(Map<String, dynamic> map) {
    return TimetableEntry(
      id: map['id'],
      subject: map['subject'] ?? '',
      day: map['day'] ?? 'Monday',
      startTime: TimeOfDay(
        hour: map['startHour'] ?? 8,
        minute: map['startMinute'] ?? 0,
      ),
      endTime: TimeOfDay(
        hour: map['endHour'] ?? 9,
        minute: map['endMinute'] ?? 0,
      ),
      room: map['room'] ?? '',
      colorValue: map['colorValue'] ?? Colors.indigo.value,
      deletedAt: map['deletedAt'] != null
          ? DateTime.parse(map['deletedAt'])
          : null,
    );
  }
}

class Flashcard {
  String id;
  String question;
  String answer;
  String subject;
  bool mastered;

  Flashcard({
    required this.id,
    required this.question,
    required this.answer,
    required this.subject,
    this.mastered = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'question': question,
      'answer': answer,
      'subject': subject,
      'mastered': mastered,
    };
  }

  factory Flashcard.fromMap(Map<String, dynamic> map) {
    return Flashcard(
      id: map['id'],
      question: map['question'] ?? '',
      answer: map['answer'] ?? '',
      subject: map['subject'] ?? 'General',
      mastered: map['mastered'] ?? false,
    );
  }
}

// ======================================================
// LOADING SCREEN
// ======================================================

class StudySyncLoadingScreen extends StatefulWidget {
  const StudySyncLoadingScreen({super.key});

  @override
  State<StudySyncLoadingScreen> createState() => _StudySyncLoadingScreenState();
}

class _StudySyncLoadingScreenState extends State<StudySyncLoadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colorScheme.primary.withOpacity(0.96),
              colorScheme.primaryContainer.withOpacity(0.88),
              colorScheme.secondary.withOpacity(0.85),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: -60,
              top: -40,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withOpacity(0.18),
                      Colors.white.withOpacity(0.02),
                    ],
                    radius: 0.8,
                  ),
                ),
              ),
            ),
            Positioned(
              right: -50,
              bottom: -30,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      colorScheme.secondary.withOpacity(0.22),
                      Colors.transparent,
                    ],
                    radius: 0.75,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 20,
              top: 92,
              right: 20,
              child: Container(
                height: 320,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  color: Colors.white.withOpacity(0.06),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.08),
                    width: 1,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 36,
              top: 128,
              child: Container(
                width: 88,
                height: 10,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Positioned(
              left: 36,
              top: 148,
              child: Container(
                width: 120,
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Positioned(
              left: 28,
              top: 216,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  color: Colors.white.withOpacity(0.06),
                ),
              ),
            ),
            Positioned(
              right: 24,
              bottom: 144,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Colors.white.withOpacity(0.08),
                ),
              ),
            ),
            Positioned(
              left: 46,
              bottom: 86,
              child: Transform.rotate(
                angle: -0.08,
                child: Container(
                  width: 180,
                  height: 2,
                  color: Colors.white.withOpacity(0.06),
                ),
              ),
            ),
            Positioned(
              right: 42,
              bottom: 68,
              child: Transform.rotate(
                angle: 0.12,
                child: Container(
                  width: 120,
                  height: 2,
                  color: Colors.white.withOpacity(0.06),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RotationTransition(
                      turns: _controller,
                      child: Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          shape: BoxShape.circle,
                          // subtle colored ring for contrast
                          border: Border.all(
                            color: colorScheme.secondary.withOpacity(0.18),
                            width: 2,
                          ),
                          // soft glow/shadow to lift the image from the background
                          boxShadow: [
                            BoxShadow(
                              color: colorScheme.secondary.withOpacity(0.24),
                              blurRadius: 18,
                              spreadRadius: 1,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.hardEdge,
                        child: ClipOval(
                          child: Image.asset(
                            'assets/images/study_logo.png',
                            width: 140,
                            height: 140,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'StudySync',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            color: Colors.black,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Getting your study plan ready…',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Colors.black,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Syncing your classes, deadlines, and study goals.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.black,
                            height: 1.4,
                          ),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        backgroundColor: Colors.grey.shade300.withOpacity(0.22),
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.grey.shade100),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ],
        ),
      ),
    );
  }
}

// ======================================================
// HOME
// ======================================================

class StudySyncHome extends StatefulWidget {
  const StudySyncHome({super.key});

  @override
  State<StudySyncHome> createState() => _StudySyncHomeState();
}

class _StudySyncHomeState extends State<StudySyncHome> {
  int _selectedIndex = 0;
  bool _isLoading = true;

  Widget _buildAmbientBackground(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            top: -80,
            right: -50,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    (isDark ? const Color(0xFF7C83FF) : const Color(0xFF5B5CF6)).withOpacity(0.22),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -70,
            left: -40,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    (isDark ? const Color(0xFF00C2FF) : const Color(0xFF8B5CF6)).withOpacity(0.16),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  final List<StudyTask> _tasks = [];
  final List<NoteItem> _notes = [];
  final List<DeadlineItem> _deadlines = [];
  final List<TimetableEntry> _timetable = [];
  final List<Flashcard> _flashcards = [];

  final List<StudyTask> _deletedTasks = [];
  final List<DeadlineItem> _deletedDeadlines = [];
  final List<TimetableEntry> _deletedTimetable = [];

  late AppSettings _settings;

  static const String _tasksKey = 'studysync_tasks_v3';
  static const String _notesKey = 'studysync_notes_v3';
  static const String _settingsKey = 'studysync_settings_v3';
  static const String _deadlinesKey = 'studysync_deadlines_v3';
  static const String _timetableKey = 'studysync_timetable_v1';
  static const String _flashcardsKey = 'studysync_flashcards_v1';
  static const String _deletedTasksKey = 'studysync_deleted_tasks_v1';
  static const String _deletedDeadlinesKey = 'studysync_deleted_deadlines_v1';
  static const String _deletedTimetableKey = 'studysync_deleted_timetable_v1';
  static const Duration _trashRetentionDuration = Duration(days: 30);

  final Map<String, int> _subjectColorMap = {
    'calculus': Colors.blue.value,
    'math': Colors.blue.value,
    'physics': Colors.green.value,
    'chemistry': Colors.purple.value,
    'biology': Colors.teal.value,
    'english': Colors.orange.value,
    'history': Colors.red.value,
    'programming': Colors.indigo.value,
    'computer': Colors.indigo.value,
  };

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _dismissKeyboard() {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    Future.delayed(Duration.zero, () {
      if (!mounted) return;
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    });
  }

  void _changePage(int index) {
    _dismissKeyboard();
    setState(() {
      _selectedIndex = index;
    });
  }

  // ======================================================
  // NAVIGATION HELPERS
  // ======================================================

  int _getDisplayNavIndex() {
    // Maps the actual page index to the display navigation index
    switch (_selectedIndex) {
      case 0:
        return 0; // Home
      case 2:
        return 1; // Tasks
      case 6:
        return 2; // Focus
      case 8:
        return 4; // Profile
      default:
        return 3; // More (for Calendar, Stats, Planner, Flashcards, Deadlines)
    }
  }

  int _mapDisplayIndexToPageIndex(int displayIndex) {
    // Maps the display navigation index to the actual page index
    switch (displayIndex) {
      case 0:
        return 0; // Home
      case 1:
        return 2; // Tasks
      case 2:
        return 6; // Focus
      case 4:
        return 8; // Profile
      default:
        return 0;
    }
  }

  List<String> _plannerSubjects() {
    final subjects = _timetable
        .map((entry) => entry.subject.trim())
        .where((subject) => subject.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return subjects;
  }

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final maxHeight = MediaQuery.of(context).size.height * 0.72;
        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF0F172A).withOpacity(0.96)
                : Colors.white.withOpacity(0.96),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
                width: 1,
              ),
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      'More Pages',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  _buildMoreMenuItem(
                    icon: Icons.calendar_month_rounded,
                    label: 'Calendar',
                    onTap: () {
                      Navigator.pop(context);
                      _changePage(1);
                    },
                  ),
                  _buildMoreMenuItem(
                    icon: Icons.bar_chart_rounded,
                    label: 'Statistics',
                    onTap: () {
                      Navigator.pop(context);
                      _changePage(3);
                    },
                  ),
                  _buildMoreMenuItem(
                    icon: Icons.event_available_rounded,
                    label: 'Class Planner',
                    onTap: () {
                      Navigator.pop(context);
                      _changePage(4);
                    },
                  ),
                  _buildMoreMenuItem(
                    icon: Icons.style_rounded,
                    label: 'Flashcards',
                    onTap: () {
                      Navigator.pop(context);
                      _changePage(5);
                    },
                  ),
                  _buildMoreMenuItem(
                    icon: Icons.event_note_rounded,
                    label: 'Deadlines',
                    onTap: () {
                      Navigator.pop(context);
                      _changePage(7);
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMoreMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
    );
  }

  // ======================================================
  // STORAGE
  // ======================================================

  Map<String, dynamic>? _safeDecodeMap(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  bool _isTrashItemExpired(DateTime? deletedAt) {
    if (deletedAt == null) return false;
    return DateTime.now().difference(deletedAt) > _trashRetentionDuration;
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

    final taskStrings = prefs.getStringList(_tasksKey) ?? [];
    final noteStrings = prefs.getStringList(_notesKey) ?? [];
    final deadlineStrings = prefs.getStringList(_deadlinesKey) ?? [];
    final timetableStrings = prefs.getStringList(_timetableKey) ?? [];
    final flashcardStrings = prefs.getStringList(_flashcardsKey) ?? [];
    final settingsString = prefs.getString(_settingsKey);

    _tasks.clear();
    _notes.clear();
    _deadlines.clear();
    _timetable.clear();
    _flashcards.clear();

    for (final taskJson in taskStrings) {
      final map = _safeDecodeMap(taskJson);
      if (map != null) {
        _tasks.add(StudyTask.fromMap(map));
      }
    }

    for (final deadlineJson in deadlineStrings) {
      final map = _safeDecodeMap(deadlineJson);
      if (map != null) {
        _deadlines.add(DeadlineItem.fromMap(map));
      }
    }

    for (final timetableJson in timetableStrings) {
      final map = _safeDecodeMap(timetableJson);
      if (map != null) {
        _timetable.add(TimetableEntry.fromMap(map));
      }
    }

    for (final flashcardJson in flashcardStrings) {
      final map = _safeDecodeMap(flashcardJson);
      if (map != null) {
        _flashcards.add(Flashcard.fromMap(map));
      }
    }

    final deletedTaskStrings = prefs.getStringList(_deletedTasksKey) ?? [];
    final deletedDeadlineStrings = prefs.getStringList(_deletedDeadlinesKey) ?? [];
    final deletedTimetableStrings = prefs.getStringList(_deletedTimetableKey) ?? [];

    bool deletedItemsPurged = false;

    for (final deletedTaskJson in deletedTaskStrings) {
      final map = _safeDecodeMap(deletedTaskJson);
      if (map != null) {
        final deletedAt = map['deletedAt'] != null
            ? DateTime.parse(map['deletedAt'])
            : null;
        if (_isTrashItemExpired(deletedAt)) {
          deletedItemsPurged = true;
          continue;
        }
        _deletedTasks.add(StudyTask.fromMap(map));
      }
    }

    for (final deletedDeadlineJson in deletedDeadlineStrings) {
      final map = _safeDecodeMap(deletedDeadlineJson);
      if (map != null) {
        final deletedAt = map['deletedAt'] != null
            ? DateTime.parse(map['deletedAt'])
            : null;
        if (_isTrashItemExpired(deletedAt)) {
          deletedItemsPurged = true;
          continue;
        }
        _deletedDeadlines.add(DeadlineItem.fromMap(map));
      }
    }

    for (final deletedTimetableJson in deletedTimetableStrings) {
      final map = _safeDecodeMap(deletedTimetableJson);
      if (map != null) {
        final deletedAt = map['deletedAt'] != null
            ? DateTime.parse(map['deletedAt'])
            : null;
        if (_isTrashItemExpired(deletedAt)) {
          deletedItemsPurged = true;
          continue;
        }
        _deletedTimetable.add(TimetableEntry.fromMap(map));
      }
    }

    for (final noteJson in noteStrings) {
      try {
        final decoded = jsonDecode(noteJson);
        if (decoded is Map<String, dynamic>) {
          _notes.add(NoteItem.fromMap(decoded));
        } else if (decoded is String) {
          _notes.add(NoteItem(text: decoded, createdAt: DateTime.now()));
        }
      } catch (_) {
        _notes.add(NoteItem(text: noteJson, createdAt: DateTime.now()));
      }
    }

    if (deletedItemsPurged) {
      await _saveDeletedTasks();
      await _saveDeletedDeadlines();
      await _saveDeletedTimetable();
    }

    if (settingsString != null) {
      final map = _safeDecodeMap(settingsString);
      if (map != null) {
        _settings = AppSettings.fromMap(map);
      } else {
        _settings = AppSettings(
          displayName: 'Student',
          darkMode: false,
          weeklyGoalMinutes: 600,
          notificationsEnabled: true,
          schoolOrCourse: '',
          yearLevel: '',
        );
      }
    } else {
      _settings = AppSettings(
        displayName: 'Student',
        darkMode: false,
        weeklyGoalMinutes: 600,
        notificationsEnabled: true,
        schoolOrCourse: '',
        yearLevel: '',
      );
    }

    // Always start in light mode when the app opens, even if a dark-mode
    // preference exists in storage from an earlier session.
    _settings.darkMode = false;

    if (mounted) {
      StudySyncScope.of(context).onThemeChanged(false);
    }

    // Reschedule any pending reminders after loading data
    for (final task in _tasks) {
      await _scheduleReminderIfNeeded(task);
    }

    // Keep the loading screen visible for a short moment so the startup
    // experience is noticeable instead of flashing too quickly.
    await Future.delayed(const Duration(seconds: 4));

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _saveTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _tasks.map((task) => jsonEncode(task.toMap())).toList();
    await prefs.setStringList(_tasksKey, encoded);
  }

  Future<void> _saveNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _notes.map((note) => jsonEncode(note.toMap())).toList();
    await prefs.setStringList(_notesKey, encoded);
  }

  Future<void> _saveDeadlines() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        _deadlines.map((item) => jsonEncode(item.toMap())).toList();
    await prefs.setStringList(_deadlinesKey, encoded);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(_settings.toMap()));
  }

  Future<void> _saveTimetable() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _timetable.map((entry) => jsonEncode(entry.toMap())).toList();
    await prefs.setStringList(_timetableKey, encoded);
  }

  Future<void> _saveDeletedTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _deletedTasks.map((task) => jsonEncode(task.toMap())).toList();
    await prefs.setStringList(_deletedTasksKey, encoded);
  }

  Future<void> _saveDeletedDeadlines() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _deletedDeadlines.map((item) => jsonEncode(item.toMap())).toList();
    await prefs.setStringList(_deletedDeadlinesKey, encoded);
  }

  Future<void> _saveDeletedTimetable() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        _deletedTimetable.map((entry) => jsonEncode(entry.toMap())).toList();
    await prefs.setStringList(_deletedTimetableKey, encoded);
  }

  Future<void> _saveFlashcards() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _flashcards.map((card) => jsonEncode(card.toMap())).toList();
    await prefs.setStringList(_flashcardsKey, encoded);
  }

  void _seedSampleData() {
    final today = DateTime.now();

    _tasks.addAll([
      StudyTask(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: 'Review derivatives',
        subject: 'Calculus',
        note: 'Practice chapter 3 exercises',
        date: DateTime(today.year, today.month, today.day),
        startTime: const TimeOfDay(hour: 9, minute: 0),
        endTime: const TimeOfDay(hour: 10, minute: 0),
        completed: false,
        colorValue: _autoSubjectColor('Calculus'),
        priority: TaskPriority.high,
        reminderEnabled: true,
        category: TaskCategory.study,
      ),
      StudyTask(
        id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
        title: 'Physics worksheet',
        subject: 'Physics',
        note: 'Answer the problem set',
        date: DateTime(today.year, today.month, today.day + 1),
        startTime: const TimeOfDay(hour: 13, minute: 0),
        endTime: const TimeOfDay(hour: 14, minute: 0),
        completed: false,
        colorValue: _autoSubjectColor('Physics'),
        priority: TaskPriority.medium,
        reminderEnabled: false,
        category: TaskCategory.assignment,
      ),
      StudyTask(
        id: (DateTime.now().millisecondsSinceEpoch + 2).toString(),
        title: 'Chemistry notes',
        subject: 'Chemistry',
        note: 'Summarize ionic vs covalent bonding',
        date: DateTime(today.year, today.month, today.day - 1),
        startTime: const TimeOfDay(hour: 16, minute: 0),
        endTime: const TimeOfDay(hour: 17, minute: 0),
        completed: true,
        colorValue: _autoSubjectColor('Chemistry'),
        priority: TaskPriority.low,
        reminderEnabled: false,
        category: TaskCategory.study,
      ),
    ]);

    _deadlines.addAll([
      DeadlineItem(
        id: 'deadline_1',
        title: 'Calculus Quiz',
        subject: 'Calculus',
        date: DateTime(today.year, today.month, today.day + 3),
        category: TaskCategory.quiz,
        note: 'Chapter 3 and 4 coverage',
        colorValue: _autoSubjectColor('Calculus'),
      ),
      DeadlineItem(
        id: 'deadline_2',
        title: 'Programming Project Submission',
        subject: 'Programming',
        date: DateTime(today.year, today.month, today.day + 6),
        category: TaskCategory.project,
        note: 'Submit final Flutter UI',
        colorValue: _autoSubjectColor('Programming'),
      ),
    ]);

    _notes.addAll([
      NoteItem(text: 'Bring notebook for Calculus.', createdAt: DateTime.now()),
      NoteItem(text: 'Review Physics formulas before quiz.', createdAt: DateTime.now()),
    ]);

    _timetable.addAll([
      TimetableEntry(
        id: 'tt_1',
        subject: 'Programming',
        day: 'Monday',
        startTime: const TimeOfDay(hour: 8, minute: 0),
        endTime: const TimeOfDay(hour: 10, minute: 0),
        room: 'Lab 2',
        colorValue: _autoSubjectColor('Programming'),
      ),
      TimetableEntry(
        id: 'tt_2',
        subject: 'Math',
        day: 'Monday',
        startTime: const TimeOfDay(hour: 10, minute: 30),
        endTime: const TimeOfDay(hour: 12, minute: 0),
        room: 'Room 12',
        colorValue: _autoSubjectColor('Math'),
      ),
    ]);

    _flashcards.addAll([
      Flashcard(
        id: 'fc_1',
        question: 'What is Flutter?',
        answer: 'Flutter is a UI toolkit for building natively compiled apps.',
        subject: 'Programming',
      ),
      Flashcard(
        id: 'fc_2',
        question: 'What does MVP stand for?',
        answer: 'Minimum Viable Product.',
        subject: 'Project Management',
        mastered: true,
      ),
    ]);
  }

  // ======================================================
  // HELPERS
  // ======================================================

  int _autoSubjectColor(String subject) {
    final lower = subject.toLowerCase().trim();
    for (final entry in _subjectColorMap.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }

    final palette = [
      Colors.indigo.value,
      Colors.blue.value,
      Colors.green.value,
      Colors.purple.value,
      Colors.orange.value,
      Colors.teal.value,
      Colors.red.value,
    ];

    final hash = lower.hashCode.abs();
    return palette[hash % palette.length];
  }

  DateTime _combineDateTime(DateTime date, TimeOfDay time) {
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  int _notificationIdForTask(StudyTask task) {
    return task.id.hashCode & 0x7fffffff;
  }

  List<StudyTask> _tasksForDate(DateTime date) {
    return _tasks.where((task) {
      return task.date.year == date.year &&
          task.date.month == date.month &&
          task.date.day == date.day;
    }).toList()
      ..sort((a, b) {
        final aMinutes = a.startTime.hour * 60 + a.startTime.minute;
        final bMinutes = b.startTime.hour * 60 + b.startTime.minute;
        return aMinutes.compareTo(bMinutes);
      });
  }

  List<StudyTask> _todayTasks() {
    final now = DateTime.now();
    return _tasksForDate(DateTime(now.year, now.month, now.day));
  }

  StudyTask? _nextPendingTask() {
    final now = DateTime.now();

    final pending = _tasks.where((task) {
      final taskDateTime = _combineDateTime(task.date, task.startTime);
      return !task.completed && taskDateTime.isAfter(now);
    }).toList();

    pending.sort((a, b) {
      final aDate = _combineDateTime(a.date, a.startTime);
      final bDate = _combineDateTime(b.date, b.startTime);
      return aDate.compareTo(bDate);
    });

    return pending.isEmpty ? null : pending.first;
  }

  DeadlineItem? _nearestDeadline() {
    final now = DateTime.now();
    final upcoming = _deadlines
        .where((d) => d.date.isAfter(now) || d.date.isAtSameMomentAs(now))
        .toList();

    upcoming.sort((a, b) => a.date.compareTo(b.date));
    return upcoming.isEmpty ? null : upcoming.first;
  }

  List<DeadlineItem> _upcomingDeadlines({int limit = 3}) {
    final now = DateTime.now();
    final upcoming = _deadlines
        .where((d) => d.date.isAfter(now) || d.date.isAtSameMomentAs(now))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    if (upcoming.length <= limit) return upcoming;
    return upcoming.take(limit).toList();
  }

  int _daysUntil(DateTime date) {
    final today = DateTime.now();
    final a = DateTime(today.year, today.month, today.day);
    final b = DateTime(date.year, date.month, date.day);
    return b.difference(a).inDays;
  }

  int _totalCompletedTasks() {
    return _tasks.where((task) => task.completed).length;
  }

  int _totalTasks() => _tasks.length;

  double _completionRate() {
    if (_tasks.isEmpty) return 0;
    return _totalCompletedTasks() / _tasks.length;
  }

  int _taskMinutes(StudyTask task) {
    final start = task.startTime.hour * 60 + task.startTime.minute;
    final end = task.endTime.hour * 60 + task.endTime.minute;
    return (end - start).clamp(0, 1440);
  }

  int _totalStudyMinutes() {
    int total = 0;
    for (final task in _tasks.where((task) => task.completed)) {
      total += _taskMinutes(task);
    }
    return total;
  }

  Map<String, int> _subjectMinutes() {
    final Map<String, int> map = {};
    for (final task in _tasks.where((task) => task.completed)) {
      map[task.subject] = (map[task.subject] ?? 0) + _taskMinutes(task);
    }
    return map;
  }

  Map<String, SubjectSummary> _subjectSummaries() {
    final Map<String, SubjectSummary> map = {};

    for (final task in _tasks) {
      final key = task.subject.trim().isEmpty ? 'Unknown' : task.subject.trim();
      map.putIfAbsent(
        key,
        () => SubjectSummary(
          subject: key,
          colorValue: task.colorValue,
          totalTasks: 0,
          completedTasks: 0,
          totalMinutes: 0,
        ),
      );

      final summary = map[key]!;
      summary.totalTasks += 1;
      if (task.completed) {
        summary.completedTasks += 1;
        summary.totalMinutes += _taskMinutes(task);
      }
    }

    return map;
  }

  int _currentWeekMinutes() {
    final now = DateTime.now();
    final startOfWeek = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    final endOfWeek = startOfWeek.add(const Duration(days: 7));

    int total = 0;
    for (final task in _tasks.where((task) => task.completed)) {
      final taskDate = DateTime(task.date.year, task.date.month, task.date.day);
      if (!taskDate.isBefore(startOfWeek) && taskDate.isBefore(endOfWeek)) {
        total += _taskMinutes(task);
      }
    }
    return total;
  }

  double _weeklyGoalProgress() {
    if (_settings.weeklyGoalMinutes <= 0) return 0;
    return (_currentWeekMinutes() / _settings.weeklyGoalMinutes).clamp(0.0, 1.0);
  }

  int _streakCount() {
    final completedDates = _tasks
        .where((task) => task.completed)
        .map((task) => DateTime(task.date.year, task.date.month, task.date.day))
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    if (completedDates.isEmpty) return 0;

    final today = DateTime.now();
    DateTime cursor = DateTime(today.year, today.month, today.day);

    int streak = 0;
    final set = completedDates.toSet();

    if (!set.contains(cursor) &&
        !set.contains(cursor.subtract(const Duration(days: 1)))) {
      return 0;
    }

    if (!set.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }

    while (set.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    return streak;
  }

  List<Map<String, dynamic>> _last7DaysStudyData() {
    final now = DateTime.now();
    final List<Map<String, dynamic>> data = [];

    for (int i = 6; i >= 0; i--) {
      final day = DateTime(now.year, now.month, now.day - i);
      int minutes = 0;

      for (final task in _tasks.where((t) => t.completed)) {
        if (task.date.year == day.year &&
            task.date.month == day.month &&
            task.date.day == day.day) {
          minutes += _taskMinutes(task);
        }
      }

      data.add({
        'label': DateFormat('E').format(day),
        'minutes': minutes,
      });
    }

    return data;
  }

  Map<String, int> _monthlyStudyMinutes() {
    final Map<String, int> result = {};
    final now = DateTime.now();

    for (int i = 5; i >= 0; i--) {
      final monthDate = DateTime(now.year, now.month - i, 1);
      final key = DateFormat('MMM').format(monthDate);
      result[key] = 0;
    }

    for (final task in _tasks.where((task) => task.completed)) {
      final key = DateFormat('MMM').format(task.date);
      if (result.containsKey(key)) {
        result[key] = (result[key] ?? 0) + _taskMinutes(task);
      }
    }

    return result;
  }

  int _completedThisMonth() {
    final now = DateTime.now();
    return _tasks.where((task) {
      return task.completed &&
          task.date.year == now.year &&
          task.date.month == now.month;
    }).length;
  }

  String _bestSubjectThisMonth() {
    final now = DateTime.now();
    final Map<String, int> minutes = {};

    for (final task in _tasks.where((task) {
      return task.completed &&
          task.date.year == now.year &&
          task.date.month == now.month;
    })) {
      minutes[task.subject] = (minutes[task.subject] ?? 0) + _taskMinutes(task);
    }

    if (minutes.isEmpty) return 'No data';

    final sorted = minutes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  String _mostProductiveDay() {
    final Map<int, int> dayMinutes = {};

    for (final task in _tasks.where((task) => task.completed)) {
      dayMinutes[task.date.weekday] =
          (dayMinutes[task.date.weekday] ?? 0) + _taskMinutes(task);
    }

    if (dayMinutes.isEmpty) return 'No data';

    final best = dayMinutes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    const names = {
      1: 'Monday',
      2: 'Tuesday',
      3: 'Wednesday',
      4: 'Thursday',
      5: 'Friday',
      6: 'Saturday',
      7: 'Sunday',
    };

    return names[best.first.key] ?? 'No data';
  }

  double _averageSessionLength() {
    final completed = _tasks.where((task) => task.completed).toList();
    if (completed.isEmpty) return 0;
    final total = completed.fold<int>(0, (sum, t) => sum + _taskMinutes(t));
    return total / completed.length;
  }

  String _mostStudiedSubject() {
    final map = _subjectMinutes();
    if (map.isEmpty) return 'No data';

    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  String _formatMinutes(int total) {
    if (total >= 60) {
      final hours = total ~/ 60;
      return '${hours} ${hours == 1 ? 'hr' : 'hrs'}';
    }
    return '${total}m';
  }

  
  Future<void> _showDeletedItemsDialog() async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, dialogSetState) {
            final hasDeletedItems =
                _deletedTasks.isNotEmpty ||
                _deletedDeadlines.isNotEmpty ||
                _deletedTimetable.isNotEmpty;

            return AlertDialog(
              title: const Text('Deleted items'),
              content: SizedBox(
                width: double.maxFinite,
                child: hasDeletedItems
                    ? SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_deletedTasks.isNotEmpty) ...[
                              const Text('Tasks', style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              ..._deletedTasks.map((task) {
                                return ListTile(
                                  title: Text(task.title),
                                  subtitle: Text(task.subject),
                                  trailing: TextButton(
                                    onPressed: () async {
                                      await _restoreDeletedTask(task.id);
                                      dialogSetState(() {});
                                    },
                                    child: const Text('Restore'),
                                  ),
                                );
                              }),
                              const Divider(),
                            ],
                            if (_deletedDeadlines.isNotEmpty) ...[
                              const Text('Deadlines', style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              ..._deletedDeadlines.map((deadline) {
                                return ListTile(
                                  title: Text(deadline.title),
                                  subtitle: Text(DateFormat.yMMMd().format(deadline.date)),
                                  trailing: TextButton(
                                    onPressed: () async {
                                      await _restoreDeletedDeadline(deadline.id);
                                      dialogSetState(() {});
                                    },
                                    child: const Text('Restore'),
                                  ),
                                );
                              }),
                              const Divider(),
                            ],
                            if (_deletedTimetable.isNotEmpty) ...[
                              const Text('Activities', style: TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              ..._deletedTimetable.map((entry) {
                                return ListTile(
                                  title: Text(entry.subject),
                                  subtitle: Text('${format12HourTime(entry.startTime)} - ${format12HourTime(entry.endTime)}'),
                                  trailing: TextButton(
                                    onPressed: () async {
                                      await _restoreDeletedTimetable(entry.id);
                                      dialogSetState(() {});
                                    },
                                    child: const Text('Restore'),
                                  ),
                                );
                              }),
                            ],
                          ],
                        ),
                      )
                    : const Text('There are no deleted items to restore.'),
              ),
              actions: [
                if (hasDeletedItems)
                  TextButton(
                    onPressed: () async {
                      await _restoreAllDeletedItems();
                      dialogSetState(() {});
                    },
                    child: const Text('Restore all'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _restoreDeletedTask(String id) async {
    final index = _deletedTasks.indexWhere((task) => task.id == id);
    if (index == -1) return;
    final task = _deletedTasks.removeAt(index);
    task.deletedAt = null;

    setState(() {
      _tasks.add(task);
    });

    await _saveTasks();
    await _saveDeletedTasks();
    await _scheduleReminderIfNeeded(task);
  }

  Future<void> _restoreDeletedDeadline(String id) async {
    final index = _deletedDeadlines.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final item = _deletedDeadlines.removeAt(index);
    item.deletedAt = null;

    setState(() {
      _deadlines.add(item);
    });

    await _saveDeadlines();
    await _saveDeletedDeadlines();
  }

  Future<void> _restoreDeletedTimetable(String id) async {
    final index = _deletedTimetable.indexWhere((entry) => entry.id == id);
    if (index == -1) return;
    final entry = _deletedTimetable.removeAt(index);
    entry.deletedAt = null;

    setState(() {
      _timetable.add(entry);
    });

    await _saveTimetable();
    await _saveDeletedTimetable();
  }

  Future<void> _restoreAllDeletedItems() async {
    if (_deletedTasks.isNotEmpty) {
      final restoredTasks = List<StudyTask>.from(_deletedTasks);
      _deletedTasks.clear();
      for (final task in restoredTasks) {
        task.deletedAt = null;
      }
      _tasks.addAll(restoredTasks);
      for (final task in restoredTasks) {
        await _scheduleReminderIfNeeded(task);
      }
    }
    if (_deletedDeadlines.isNotEmpty) {
      for (final item in _deletedDeadlines) {
        item.deletedAt = null;
      }
      _deadlines.addAll(_deletedDeadlines);
      _deletedDeadlines.clear();
    }
    if (_deletedTimetable.isNotEmpty) {
      for (final entry in _deletedTimetable) {
        entry.deletedAt = null;
      }
      _timetable.addAll(_deletedTimetable);
      _deletedTimetable.clear();
    }

    setState(() {});
    await _saveTasks();
    await _saveDeadlines();
    await _saveTimetable();
    await _saveDeletedTasks();
    await _saveDeletedDeadlines();
    await _saveDeletedTimetable();
  }

  Future<void> _addTask(StudyTask task) async {
    task.colorValue = _autoSubjectColor(task.subject);

    setState(() {
      _tasks.add(task);
    });

    await _saveTasks();
    await _scheduleReminderIfNeeded(task);
  }

  Future<void> _updateTask(StudyTask updatedTask) async {
    updatedTask.colorValue = _autoSubjectColor(updatedTask.subject);

    final index = _tasks.indexWhere((task) => task.id == updatedTask.id);
    if (index != -1) {
      setState(() {
        _tasks[index] = updatedTask;
      });
      await _saveTasks();
      await NotificationService.cancelTaskReminder(updatedTask.id);
      await _scheduleReminderIfNeeded(updatedTask);
    }
  }

  Future<void> _deleteTask(String id) async {
    final task = _tasks.firstWhere((t) => t.id == id);
    task.deletedAt = DateTime.now();

    setState(() {
      _deletedTasks.add(task);
      _tasks.removeWhere((task) => task.id == id);
    });

    await NotificationService.cancelTaskReminder(task.id);
    await _saveTasks();
    await _saveDeletedTasks();
  }

  Future<void> _toggleTaskComplete(String id) async {
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index != -1) {
      setState(() {
        _tasks[index].completed = !_tasks[index].completed;
      });
      await _saveTasks();
    }
  }

  Future<void> _scheduleReminderIfNeeded(StudyTask task) async {
    if (!_settings.notificationsEnabled) {
      print('🔕 Notifications disabled in settings');
      return;
    }

    if (!task.reminderEnabled) {
      print('🚫 Reminders disabled for ${task.title}');
      await NotificationService.cancelTaskReminder(task.id);
      return;
    }

    final taskDateTime = DateTime(
      task.date.year,
      task.date.month,
      task.date.day,
      task.startTime.hour,
      task.startTime.minute,
    );
    final now = DateTime.now();

    // Default reminder: 10 minutes before
    DateTime reminderTime = taskDateTime.subtract(const Duration(minutes: 10));

    print('📅 Task: ${task.title}');
    print('⏱️ Task start time: $taskDateTime');
    print('⏰ Original reminder time: $reminderTime');
    print('🕐 Current time: $now');

    // If task is very soon and 10-min-before is already past,
    // schedule it 1 minute from now instead (only if task itself is still in future)
    if (reminderTime.isBefore(now) && taskDateTime.isAfter(now)) {
      reminderTime = now.add(const Duration(minutes: 1));
      print('⚠️ 10-minute reminder already passed, scheduling fallback at: $reminderTime');
    }

    // If the actual task time is already in the past, do not schedule
    if (!taskDateTime.isAfter(now)) {
      print('⏸️ Task time already passed, not scheduling');
      await NotificationService.cancelTaskReminder(task.id);
      return;
    }

    await NotificationService.scheduleTaskReminder(
      id: task.id,
      title: 'Upcoming Study Task',
      body: '${task.title} • ${task.subject} starts soon',
      scheduledDate: reminderTime,
    );
  }

  // ======================================================
  // DEADLINE ACTIONS
  // ======================================================

  Future<void> _addDeadline(DeadlineItem item) async {
    setState(() {
      _deadlines.add(item);
    });
    await _saveDeadlines();
  }

  Future<void> _updateDeadline(DeadlineItem item) async {
    final index = _deadlines.indexWhere((d) => d.id == item.id);
    if (index != -1) {
      setState(() {
        _deadlines[index] = item;
      });
      await _saveDeadlines();
    }
  }

  Future<void> _deleteDeadline(String id) async {
    final deadline = _deadlines.firstWhere((d) => d.id == id);
    deadline.deletedAt = DateTime.now();

    setState(() {
      _deletedDeadlines.add(deadline);
      _deadlines.removeWhere((d) => d.id == id);
    });
    await _saveDeadlines();
    await _saveDeletedDeadlines();
  }

  // ======================================================
  // NOTES ACTIONS
  // ======================================================

  Future<void> _addNote(String note) async {
    final trimmed = note.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _notes.add(NoteItem(text: trimmed, createdAt: DateTime.now()));
    });
    await _saveNotes();
  }

  Future<void> _updateNote(int index, String newText) async {
    final trimmed = newText.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _notes[index] = NoteItem(text: trimmed, createdAt: _notes[index].createdAt);
    });
    await _saveNotes();
  }

  Future<void> _deleteNote(int index) async {
    setState(() {
      _notes.removeAt(index);
    });
    await _saveNotes();
  }

  // ======================================================
  // SETTINGS ACTIONS
  // ======================================================

  Future<void> _updateSettings(AppSettings settings) async {
    _settings = settings;
    await _saveSettings();
    if (mounted) {
      StudySyncScope.of(context).onThemeChanged(_settings.darkMode);
    }

    if (!_settings.notificationsEnabled) {
      await NotificationService.cancelAll();
    } else {
      for (final task in _tasks) {
        await _scheduleReminderIfNeeded(task);
      }
    }

    setState(() {});
  }

  Future<void> _addTimetableEntry(TimetableEntry entry) async {
    setState(() {
      _timetable.add(entry);
    });
    await _saveTimetable();
  }

  Future<void> _updateTimetableEntry(TimetableEntry entry) async {
    final index = _timetable.indexWhere((item) => item.id == entry.id);
    if (index != -1) {
      setState(() {
        _timetable[index] = entry;
      });
      await _saveTimetable();
    }
  }

  Future<void> _deleteTimetableEntry(String id) async {
    final entry = _timetable.firstWhere((entry) => entry.id == id);
    entry.deletedAt = DateTime.now();

    setState(() {
      _deletedTimetable.add(entry);
      _timetable.removeWhere((entry) => entry.id == id);
    });
    await _saveTimetable();
    await _saveDeletedTimetable();
  }

  Future<void> _addFlashcard(Flashcard card) async {
    setState(() {
      _flashcards.add(card);
    });
    await _saveFlashcards();
  }

  Future<void> _updateFlashcard(Flashcard card) async {
    final index = _flashcards.indexWhere((item) => item.id == card.id);
    if (index != -1) {
      setState(() {
        _flashcards[index] = card;
      });
      await _saveFlashcards();
    }
  }

  Future<void> _deleteFlashcard(String id) async {
    setState(() {
      _flashcards.removeWhere((card) => card.id == id);
    });
    await _saveFlashcards();
  }

  Future<void> _toggleFlashcardMastered(String id) async {
    final index = _flashcards.indexWhere((card) => card.id == id);
    if (index != -1) {
      setState(() {
        _flashcards[index].mastered = !_flashcards[index].mastered;
      });
      await _saveFlashcards();
    }
  }

  Future<void> _resetAllData() async {
    for (final task in _tasks) {
      await NotificationService.cancelTaskReminder(task.id);
    }

    setState(() {
      _tasks.clear();
      _notes.clear();
      _deadlines.clear();
      _timetable.clear();
      _flashcards.clear();
      _deletedTasks.clear();
      _deletedDeadlines.clear();
      _deletedTimetable.clear();
      _settings = AppSettings(
        displayName: 'Student',
        darkMode: false,
        weeklyGoalMinutes: 600,
        notificationsEnabled: true,
        schoolOrCourse: '',
        yearLevel: '',
        profilePhotoBase64: null,
      );
    });

    await _saveTasks();
    await _saveNotes();
    await _saveDeadlines();
    await _saveTimetable();
    await _saveFlashcards();
    await _saveSettings();

    if (mounted) {
      StudySyncScope.of(context).onThemeChanged(_settings.darkMode);
    }
  }

  // ======================================================
  // UI
  // ======================================================

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const StudySyncLoadingScreen();
    }

    final pages = [
      DashboardPage(
        settings: _settings,
        profilePhotoBase64: _settings.profilePhotoBase64,
        tasks: _tasks,
        todayTasks: _todayTasks(),
        notes: _notes,
        completionRate: _completionRate(),
        completedCount: _totalCompletedTasks(),
        totalCount: _totalTasks(),
        nextTask: _nextPendingTask(),
        weeklyGoalMinutes: _settings.weeklyGoalMinutes,
        currentWeekMinutes: _currentWeekMinutes(),
        weeklyGoalProgress: _weeklyGoalProgress(),
        streakCount: _streakCount(),
        deadlines: _upcomingDeadlines(limit: 3),
        nearestDeadline: _nearestDeadline(),
        subjectSummaries: _subjectSummaries(),
        onAddNote: _addNote,
        onUpdateNote: _updateNote,
        onDeleteNote: _deleteNote,
        onAddTaskPressed: () => _openTaskDialog(),
        onToggleTaskComplete: _toggleTaskComplete,
        onEditTask: (task) => _openTaskDialog(existingTask: task),
        onDeleteTask: _deleteTask,
        onOpenDeadlinePage: () {
          _changePage(7);
        },
        onRefresh: () async {
          await _loadData();
          if (mounted) setState(() {});
        },
      ),
      CalendarPage(
        allTasks: _tasks,
        getTasksForDate: _tasksForDate,
        onAddTaskPressed: (selectedDate) =>
            _openTaskDialog(prefilledDate: selectedDate),
        onToggleTaskComplete: _toggleTaskComplete,
        onEditTask: (task) => _openTaskDialog(existingTask: task),
        onDeleteTask: _deleteTask,
      ),
      TasksPage(
        tasks: _tasks,
        onAddTaskPressed: () => _openTaskDialog(),
        onToggleTaskComplete: _toggleTaskComplete,
        onEditTask: (task) => _openTaskDialog(existingTask: task),
        onDeleteTask: _deleteTask,
      ),
      StatisticsPage(
        tasks: _tasks,
        totalMinutes: _totalStudyMinutes(),
        completedCount: _totalCompletedTasks(),
        completionRate: _completionRate(),
        subjectMinutes: _subjectMinutes(),
        subjectSummaries: _subjectSummaries(),
        weeklyGoalMinutes: _settings.weeklyGoalMinutes,
        currentWeekMinutes: _currentWeekMinutes(),
        weeklyGoalProgress: _weeklyGoalProgress(),
        last7DaysData: _last7DaysStudyData(),
        monthlyMinutes: _monthlyStudyMinutes(),
        completedThisMonth: _completedThisMonth(),
        bestSubjectThisMonth: _bestSubjectThisMonth(),
        mostProductiveDay: _mostProductiveDay(),
        averageSessionLength: _averageSessionLength(),
        mostStudiedSubject: _mostStudiedSubject(),
      ),
      PlannerPage(
        timetable: _timetable,
        onAddEntry: () => _openTimetableDialog(),
        onEditEntry: (entry) => _openTimetableDialog(existingEntry: entry),
        onDeleteEntry: _deleteTimetableEntry,
      ),
      FlashcardsPage(
        flashcards: _flashcards,
        onAddCard: () => _openFlashcardDialog(),
        onEditCard: (card) => _openFlashcardDialog(existingCard: card),
        onDeleteCard: _deleteFlashcard,
        onToggleMastered: _toggleFlashcardMastered,
      ),
      const FocusPage(),
      DeadlinesPage(
        deadlines: _deadlines,
        onAddDeadline: () => _openDeadlineDialog(),
        onEditDeadline: (item) => _openDeadlineDialog(existingDeadline: item),
        onDeleteDeadline: _deleteDeadline,
        daysUntil: _daysUntil,
      ),
      SettingsPage(
        settings: _settings,
        streakCount: _streakCount(),
        currentWeekMinutes: _currentWeekMinutes(),
        onShowDeletedItems: _showDeletedItemsDialog,
        onSaveSettings: _updateSettings,
        onResetData: _resetAllData,
      ),
    ];

    return Scaffold(
      body: Stack(
        children: [
          _buildAmbientBackground(context),
          IndexedStack(
            index: _selectedIndex,
            children: pages,
          ),
        ],
      ),
      bottomNavigationBar: Container(
        margin: const EdgeInsets.fromLTRB(0, 0, 0, 0),
        padding: const EdgeInsets.all(0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF0F172A).withOpacity(0.96)
              : Colors.white.withOpacity(0.92),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.16),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.zero,
          child: NavigationBar(
            selectedIndex: _getDisplayNavIndex(),
            height: 74,
            backgroundColor: Colors.transparent,
            elevation: 0,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (index) {
              if (index == 3) {
                _showMoreMenu();
              } else {
                _changePage(_mapDisplayIndexToPageIndex(index));
              }
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.checklist_outlined),
                selectedIcon: Icon(Icons.checklist_rounded),
                label: 'Tasks',
              ),
              NavigationDestination(
                icon: Icon(Icons.timer_outlined),
                selectedIcon: Icon(Icons.timer_rounded),
                label: 'Focus',
              ),
              NavigationDestination(
                icon: Icon(Icons.menu_rounded),
                selectedIcon: Icon(Icons.menu_rounded),
                label: 'More',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _selectedIndex == 2
          ? FloatingActionButton.small(
              onPressed: () => _openTaskDialog(),
              child: const Icon(Icons.add),
              tooltip: 'Add Task',
            )
          : null,
    );
  }

  Future<void> _openTaskDialog({
    StudyTask? existingTask,
    DateTime? prefilledDate,
  }) async {
    final result = await showModalBottomSheet<StudyTask>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TaskEditorSheet(
        existingTask: existingTask,
        prefilledDate: prefilledDate,
        notificationsEnabled: _settings.notificationsEnabled,
        plannerSubjects: _plannerSubjects(),
        autoColorForSubject: _autoSubjectColor,
      ),
    );

    if (result == null) return;

    if (existingTask == null) {
      await _addTask(result);
    } else {
      await _updateTask(result);
    }
  }

  Future<void> _openTimetableDialog({
    TimetableEntry? existingEntry,
  }) async {
    final result = await showModalBottomSheet<TimetableEntry>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TimetableEditorSheet(
        existingEntry: existingEntry,
        autoColorForSubject: _autoSubjectColor,
      ),
    );

    if (result == null) return;

    if (existingEntry == null) {
      await _addTimetableEntry(result);
    } else {
      await _updateTimetableEntry(result);
    }
  }

  Future<void> _openFlashcardDialog({
    Flashcard? existingCard,
  }) async {
    final result = await showModalBottomSheet<Flashcard>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FlashcardEditorSheet(
        existingCard: existingCard,
        plannerSubjects: _plannerSubjects(),
      ),
    );

    if (result == null) return;

    if (existingCard == null) {
      await _addFlashcard(result);
    } else {
      await _updateFlashcard(result);
    }
  }

  Future<void> _openDeadlineDialog({
    DeadlineItem? existingDeadline,
  }) async {
    final result = await showModalBottomSheet<DeadlineItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DeadlineEditorSheet(
        existingDeadline: existingDeadline,
        plannerSubjects: _plannerSubjects(),
        autoColorForSubject: _autoSubjectColor,
      ),
    );

    if (result == null) return;

    if (existingDeadline == null) {
      await _addDeadline(result);
    } else {
      await _updateDeadline(result);
    }
  }
}

// ======================================================
// SUBJECT SUMMARY MODEL
// ======================================================

class SubjectSummary {
  final String subject;
  final int colorValue;
  int totalTasks;
  int completedTasks;
  int totalMinutes;

  SubjectSummary({
    required this.subject,
    required this.colorValue,
    required this.totalTasks,
    required this.completedTasks,
    required this.totalMinutes,
  });
}

List<SubjectSummary> getSlowProgressSubjects(
  Map<String, SubjectSummary> subjectSummaries, {
  double threshold = 0.5,
  int minimumTasks = 2,
}) {
  final candidates = subjectSummaries.values
      .where((summary) => summary.totalTasks >= minimumTasks)
      .toList();

  if (candidates.isEmpty) return [];

  final flagged = candidates.where((summary) {
    final progress = summary.totalTasks == 0
        ? 0.0
        : summary.completedTasks / summary.totalTasks;
    return progress < threshold;
  }).toList()
    ..sort((a, b) {
      final progressA = a.totalTasks == 0 ? 0.0 : a.completedTasks / a.totalTasks;
      final progressB = b.totalTasks == 0 ? 0.0 : b.completedTasks / b.totalTasks;
      return progressA.compareTo(progressB);
    });

  return flagged;
}

// ======================================================
// DASHBOARD PAGE
// ======================================================

class DashboardPage extends StatefulWidget {
  final AppSettings settings;
  final String? profilePhotoBase64;
  final List<StudyTask> tasks;
  final List<StudyTask> todayTasks;
  final List<NoteItem> notes;
  final double completionRate;
  final int completedCount;
  final int totalCount;
  final StudyTask? nextTask;
  final int weeklyGoalMinutes;
  final int currentWeekMinutes;
  final double weeklyGoalProgress;
  final int streakCount;
  final List<DeadlineItem> deadlines;
  final DeadlineItem? nearestDeadline;
  final Map<String, SubjectSummary> subjectSummaries;
  final Future<void> Function(String) onAddNote;
  final Future<void> Function(int, String) onUpdateNote;
  final Future<void> Function(int) onDeleteNote;
  final VoidCallback onAddTaskPressed;
  final Future<void> Function(String id) onToggleTaskComplete;
  final void Function(StudyTask task) onEditTask;
  final Future<void> Function(String id) onDeleteTask;
  final VoidCallback onOpenDeadlinePage;
  final Future<void> Function()? onRefresh;

  const DashboardPage({
    super.key,
    required this.settings,
    this.profilePhotoBase64,
    required this.tasks,
    required this.todayTasks,
    required this.notes,
    required this.completionRate,
    required this.completedCount,
    required this.totalCount,
    required this.nextTask,
    required this.weeklyGoalMinutes,
    required this.currentWeekMinutes,
    required this.weeklyGoalProgress,
    required this.streakCount,
    required this.deadlines,
    required this.nearestDeadline,
    required this.subjectSummaries,
    required this.onAddNote,
    required this.onUpdateNote,
    required this.onDeleteNote,
    required this.onAddTaskPressed,
    required this.onToggleTaskComplete,
    required this.onEditTask,
    required this.onDeleteTask,
    required this.onOpenDeadlinePage,
    this.onRefresh,
  });

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _formatMinutes(int total) {
    if (total >= 60) {
      final hours = total ~/ 60;
      return '${hours} ${hours == 1 ? 'hr' : 'hrs'}';
    }
    return '${total}m';
  }

  int _daysUntil(DateTime date) {
    final today = DateTime.now();
    final a = DateTime(today.year, today.month, today.day);
    final b = DateTime(date.year, date.month, date.day);
    return b.difference(a).inDays;
  }

  List<DeadlineItem> _getUpcomingExams({int limit = 3}) {
    final now = DateTime.now();
    final upcoming = deadlines
      .where((d) => (d.date.isAfter(now) || d.date.isAtSameMomentAs(now)) &&
        d.category == TaskCategory.exam)
      .toList();
    upcoming.sort((a, b) => a.date.compareTo(b.date));
    return upcoming.take(limit).toList();
  }

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _showNoteEditDialog(BuildContext context, int index, NoteItem note) {
    final editController = TextEditingController(text: note.text);
    
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit Note'),
          content: SizedBox(
            width: double.maxFinite,
            child: TextField(
              controller: editController,
              maxLines: null,
              minLines: 4,
              decoration: InputDecoration(
                hintText: 'Enter your note...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF1C2233)
                    : const Color(0xFFF6F7FB),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (editController.text.trim().isNotEmpty) {
                  await widget.onUpdateNote(index, editController.text);
                  if (context.mounted) Navigator.pop(context);
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final topSubjects = widget.subjectSummaries.values.toList()
      ..sort((a, b) => b.totalMinutes.compareTo(a.totalMinutes));
    final slowProgressSubjects = getSlowProgressSubjects(widget.subjectSummaries);
    final worstSubject = slowProgressSubjects.isEmpty
        ? null
        : slowProgressSubjects.first;
    final studyQuotes = <String>[
      'Small steps every day build big results.',
      'Consistency beats intensity when motivation fades.',
      'Your future self will thank you for this session.',
      'Focus on progress, not perfection.',
      'A calm mind studies better.',
    ];

    return SafeArea(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DashboardHeader(
              greeting: widget._greeting(),
              displayName: widget.settings.displayName,
              taskCount: widget.todayTasks.length,
              schoolOrCourse: widget.settings.schoolOrCourse,
              yearLevel: widget.settings.yearLevel,
              profilePhotoBase64: widget.profilePhotoBase64,
            ),
            const SizedBox(height: 18),

            _HeroSummaryCard(
              completionRate: widget.completionRate,
              completedCount: widget.completedCount,
              totalCount: widget.totalCount,
            ),
            const SizedBox(height: 18),

            if (worstSubject != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.error.withOpacity(0.28),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Worst subject',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            worstSubject.subject,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${worstSubject.completedTasks}/${worstSubject.totalTasks} tasks completed',
                            style: TextStyle(color: Theme.of(context).hintColor),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

            if (worstSubject != null) const SizedBox(height: 18),

            Row(
              children: [
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.flag_rounded,
                    title: 'Weekly Goal',
                    value: '${(widget.weeklyGoalProgress * 100).round()}%',
                    subtitle:
                        '${widget._formatMinutes(widget.currentWeekMinutes)} / ${widget._formatMinutes(widget.weeklyGoalMinutes)}',
                    color: Colors.indigo,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.local_fire_department_rounded,
                    title: 'Streak',
                    value: '${widget.streakCount}',
                    subtitle: 'day${widget.streakCount == 1 ? '' : 's'} in a row',
                    color: Colors.orange,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 18),
            const _SectionHeader(title: 'Daily Study Quote'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '“${studyQuotes[(DateTime.now().day + DateTime.now().month) % studyQuotes.length]}”',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A fresh reminder to keep your study streak going.',
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),
            const _SectionHeader(title: 'Achievement Badges'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: cardDecoration(context),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (widget.streakCount >= 3)
                    _AchievementPill(
                      icon: Icons.local_fire_department_rounded,
                      label: '3-Day Streak',
                      color: Colors.orange,
                    ),
                  if (widget.completedCount >= 5)
                    _AchievementPill(
                      icon: Icons.emoji_events_rounded,
                      label: 'Task Finisher',
                      color: Colors.green,
                    ),
                  if (widget.currentWeekMinutes >= 240)
                    _AchievementPill(
                      icon: Icons.timer_rounded,
                      label: 'Focused Week',
                      color: Colors.indigo,
                    ),
                  if (widget.completionRate >= 0.8)
                    _AchievementPill(
                      icon: Icons.star_rounded,
                      label: 'Goal Achiever',
                      color: Colors.purple,
                    ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            if (widget.nearestDeadline != null) ...[
              const _SectionHeader(
                title: 'Urgent Deadline',
              ),
              const SizedBox(height: 10),
              _UrgentDeadlineCard(
                item: widget.nearestDeadline!,
                daysLeft: widget._daysUntil(widget.nearestDeadline!.date),
              ),
              const SizedBox(height: 20),
            ],

            if (widget._getUpcomingExams().isNotEmpty) ...[
              _SectionHeader(
                title: 'Upcoming Exams',
                actionText: 'View All',
                onActionTap: widget.onOpenDeadlinePage,
              ),
              const SizedBox(height: 10),
              ...widget._getUpcomingExams().map((exam) {
                return _ExamCountdownCard(
                  exam: exam,
                  daysLeft: widget._daysUntil(exam.date),
                );
              }),
              const SizedBox(height: 20),
            ],

            _SectionHeader(
              title: "Today's Plan",
              actionText: 'Add',
              onActionTap: widget.onAddTaskPressed,
            ),
            const SizedBox(height: 10),

            if (widget.todayTasks.isEmpty)
              const _EmptyCard(
                icon: Icons.event_note_rounded,
                title: 'No study tasks for today',
                subtitle: 'Tap "Add Task" to create your first session.',
              )
            else
              ...widget.todayTasks.map(
                (task) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TaskCard(
                    task: task,
                    onToggleComplete: () => widget.onToggleTaskComplete(task.id),
                    onEdit: () => widget.onEditTask(task),
                    onDelete: () => widget.onDeleteTask(task.id),
                  ),
                ),
              ),

            const SizedBox(height: 20),

            _SectionHeader(title: 'Up Next'),
            const SizedBox(height: 10),
            if (widget.nextTask == null)
              const _EmptyCard(
                icon: Icons.alarm_off_rounded,
                title: 'No upcoming pending task',
                subtitle: 'Your next study session will appear here.',
              )
            else
              _NextTaskCard(task: widget.nextTask!),

            const SizedBox(height: 20),

            _SectionHeader(title: 'Needs Attention'),
            const SizedBox(height: 10),
            if (slowProgressSubjects.isEmpty)
              const _EmptyCard(
                icon: Icons.insights_rounded,
                title: 'No subjects need extra attention',
                subtitle: 'Keep going — your subjects are progressing well.',
              )
            else
              Column(
                children: slowProgressSubjects.take(3).map((summary) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SlowProgressSubjectCard(summary: summary),
                  );
                }).toList(),
              ),

            const SizedBox(height: 20),

            _SectionHeader(title: 'Subject Overview'),
            const SizedBox(height: 10),
            if (topSubjects.isEmpty)
              const _EmptyCard(
                icon: Icons.menu_book_outlined,
                title: 'No subject data yet',
                subtitle: 'Complete tasks to build your subject analytics.',
              )
            else
              Column(
                children: topSubjects.take(3).map((summary) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SubjectOverviewCard(summary: summary),
                  );
                }).toList(),
              ),

            const SizedBox(height: 20),

            _SectionHeader(title: 'Weekly Goal Progress'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'You’ve completed ${widget._formatMinutes(widget.currentWeekMinutes)} this week.',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: widget.weeklyGoalProgress,
                      minHeight: 12,
                      backgroundColor:
                          Theme.of(context).colorScheme.primary.withOpacity(0.10),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${(widget.weeklyGoalProgress * 100).round()}% of ${widget._formatMinutes(widget.weeklyGoalMinutes)} goal',
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),
            _SectionHeader(title: 'Notes'),
            const SizedBox(height: 10),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: cardDecoration(context),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _noteController,
                          decoration: InputDecoration(
                            hintText: 'Write a quick note...',
                            prefixIcon:
                                const Icon(Icons.sticky_note_2_outlined),
                            filled: true,
                            fillColor: Theme.of(context).brightness ==
                                    Brightness.dark
                                ? const Color(0xFF1C2233)
                                : const Color(0xFFF6F7FB),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onSubmitted: (value) async {
                            if (value.trim().isEmpty) return;
                            await widget.onAddNote(value);
                            _noteController.clear();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filled(
                        onPressed: () async {
                          if (_noteController.text.trim().isEmpty) return;
                          await widget.onAddNote(_noteController.text);
                          _noteController.clear();
                        },
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (widget.notes.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No notes yet.',
                        style: TextStyle(color: Theme.of(context).hintColor),
                      ),
                    )
                  else
                    ...List.generate(widget.notes.length, (index) {
                      final note = widget.notes[index];
                      return GestureDetector(
                        onTap: () => _showNoteEditDialog(context, index, note),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF1C2233)
                                : const Color(0xFFF9FAFD),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? const Color(0xFF263049)
                                  : const Color(0xFFE8ECF4),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.circle,
                                size: 8,
                                color: Colors.indigo,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      note.text,
                                      style: const TextStyle(fontSize: 14),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      DateFormat.yMMMd().add_jm().format(note.createdAt),
                                      style: TextStyle(
                                        color: Theme.of(context).hintColor,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => widget.onDeleteNote(index),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// CALENDAR PAGE
// ======================================================

class CalendarPage extends StatefulWidget {
  final List<StudyTask> allTasks;
  final List<StudyTask> Function(DateTime date) getTasksForDate;
  final void Function(DateTime selectedDate) onAddTaskPressed;
  final Future<void> Function(String id) onToggleTaskComplete;
  final void Function(StudyTask task) onEditTask;
  final Future<void> Function(String id) onDeleteTask;

  const CalendarPage({
    super.key,
    required this.allTasks,
    required this.getTasksForDate,
    required this.onAddTaskPressed,
    required this.onToggleTaskComplete,
    required this.onEditTask,
    required this.onDeleteTask,
  });

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime _selectedDate;
  late DateTime _displayedMonth;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _displayedMonth = DateTime(now.year, now.month, 1);
  }

  List<DateTime> _buildMonthDays(DateTime month) {
    final firstDay = DateTime(month.year, month.month, 1);
    final lastDay = DateTime(month.year, month.month + 1, 0);

    final startOffset = firstDay.weekday % 7;
    final firstGridDay = firstDay.subtract(Duration(days: startOffset));

    final endOffset = 6 - (lastDay.weekday % 7);
    final lastGridDay = lastDay.add(Duration(days: endOffset));

    final days = <DateTime>[];
    DateTime current = firstGridDay;
    while (!current.isAfter(lastGridDay)) {
      days.add(current);
      current = current.add(const Duration(days: 1));
    }
    return days;
  }

  bool _hasTasks(DateTime date) {
    return widget.getTasksForDate(date).isNotEmpty;
  }

  bool _sameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override
  Widget build(BuildContext context) {
    final monthDays = _buildMonthDays(_displayedMonth);
    final selectedTasks = widget.getTasksForDate(_selectedDate);
    final today = DateTime.now();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageTitle(
              title: 'Study Calendar',
              subtitle: 'Plan your sessions and track your schedule.',
            ),
            const SizedBox(height: 18),

            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () {
                          setState(() {
                            _displayedMonth = DateTime(
                              _displayedMonth.year,
                              _displayedMonth.month - 1,
                              1,
                            );
                          });
                        },
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            DateFormat('MMMM yyyy').format(_displayedMonth),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          setState(() {
                            _displayedMonth = DateTime(
                              _displayedMonth.year,
                              _displayedMonth.month + 1,
                              1,
                            );
                          });
                        },
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: const [
                      Expanded(child: Center(child: Text('Sun'))),
                      Expanded(child: Center(child: Text('Mon'))),
                      Expanded(child: Center(child: Text('Tue'))),
                      Expanded(child: Center(child: Text('Wed'))),
                      Expanded(child: Center(child: Text('Thu'))),
                      Expanded(child: Center(child: Text('Fri'))),
                      Expanded(child: Center(child: Text('Sat'))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  GridView.builder(
                    itemCount: monthDays.length,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 7,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1,
                    ),
                    itemBuilder: (context, index) {
                      final date = monthDays[index];
                      final isCurrentMonth =
                          date.month == _displayedMonth.month &&
                              date.year == _displayedMonth.year;
                      final isSelected = _sameDay(date, _selectedDate);
                      final isToday = _sameDay(date, today);
                      final hasTasks = _hasTasks(date);

                      return InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          setState(() {
                            _selectedDate = date;
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? const Color(0xFF1C2233)
                                    : const Color(0xFFF7F8FC)),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isToday && !isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.transparent,
                              width: 1.4,
                            ),
                          ),
                          child: Stack(
                            children: [
                              Center(
                                child: Text(
                                  '${date.day}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: !isCurrentMonth
                                        ? Theme.of(context)
                                            .hintColor
                                            .withOpacity(0.6)
                                        : isSelected
                                            ? Colors.white
                                            : null,
                                  ),
                                ),
                              ),
                              if (hasTasks)
                                Positioned(
                                  bottom: 8,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.white
                                            : Theme.of(context)
                                                .colorScheme
                                                .primary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: Text(
                    'Tasks for ${DateFormat('MMM d, yyyy').format(_selectedDate)}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => widget.onAddTaskPressed(_selectedDate),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(64, 36),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (selectedTasks.isEmpty)
              const _EmptyCard(
                icon: Icons.calendar_today_outlined,
                title: 'No tasks on this date',
                subtitle: 'Add a study session for the selected day.',
              )
            else
              ...selectedTasks.map(
                (task) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TaskCard(
                    task: task,
                    onToggleComplete: () =>
                        widget.onToggleTaskComplete(task.id),
                    onEdit: () => widget.onEditTask(task),
                    onDelete: () => widget.onDeleteTask(task.id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// TASKS PAGE
// ======================================================

class TasksPage extends StatefulWidget {
  final List<StudyTask> tasks;
  final VoidCallback onAddTaskPressed;
  final Future<void> Function(String id) onToggleTaskComplete;
  final void Function(StudyTask task) onEditTask;
  final Future<void> Function(String id) onDeleteTask;

  const TasksPage({
    super.key,
    required this.tasks,
    required this.onAddTaskPressed,
    required this.onToggleTaskComplete,
    required this.onEditTask,
    required this.onDeleteTask,
  });

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  TaskFilter _filter = TaskFilter.all;
  TaskSort _sort = TaskSort.upcoming;
  String _search = '';

  List<StudyTask> _filteredTasks() {
    List<StudyTask> result = [...widget.tasks];

    if (_search.trim().isNotEmpty) {
      final q = _search.toLowerCase().trim();
      result = result.where((task) {
        return task.title.toLowerCase().contains(q) ||
            task.subject.toLowerCase().contains(q) ||
            task.note.toLowerCase().contains(q);
      }).toList();
    }

    switch (_filter) {
      case TaskFilter.pending:
        result = result.where((t) => !t.completed).toList();
        break;
      case TaskFilter.completed:
        result = result.where((t) => t.completed).toList();
        break;
      case TaskFilter.all:
        break;
    }

    switch (_sort) {
      case TaskSort.upcoming:
        result.sort((a, b) {
          final ad = DateTime(
            a.date.year,
            a.date.month,
            a.date.day,
            a.startTime.hour,
            a.startTime.minute,
          );
          final bd = DateTime(
            b.date.year,
            b.date.month,
            b.date.day,
            b.startTime.hour,
            b.startTime.minute,
          );
          return ad.compareTo(bd);
        });
        break;
      case TaskSort.priority:
        int priorityValue(TaskPriority p) {
          switch (p) {
            case TaskPriority.high:
              return 3;
            case TaskPriority.medium:
              return 2;
            case TaskPriority.low:
              return 1;
          }
        }

        result.sort(
          (a, b) => priorityValue(b.priority).compareTo(
            priorityValue(a.priority),
          ),
        );
        break;
      case TaskSort.subject:
        result.sort((a, b) => a.subject.compareTo(b.subject));
        break;
      case TaskSort.completedLast:
        result.sort((a, b) {
          if (a.completed == b.completed) {
            final ad = DateTime(
              a.date.year,
              a.date.month,
              a.date.day,
              a.startTime.hour,
              a.startTime.minute,
            );
            final bd = DateTime(
              b.date.year,
              b.date.month,
              b.date.day,
              b.startTime.hour,
              b.startTime.minute,
            );
            return ad.compareTo(bd);
          }
          return a.completed ? 1 : -1;
        });
        break;
    }

    return result;
  }

  String _filterLabel(TaskFilter filter) {
    switch (filter) {
      case TaskFilter.all:
        return 'All';
      case TaskFilter.pending:
        return 'Pending';
      case TaskFilter.completed:
        return 'Completed';
    }
  }

  String _sortLabel(TaskSort sort) {
    switch (sort) {
      case TaskSort.upcoming:
        return 'Upcoming';
      case TaskSort.priority:
        return 'Priority';
      case TaskSort.subject:
        return 'Subject';
      case TaskSort.completedLast:
        return 'Completed Last';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _filteredTasks();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageTitle(
              title: 'All Tasks',
              subtitle: 'Search, filter, and sort your study plan.',
            ),
            const SizedBox(height: 18),

            TextField(
              decoration: InputDecoration(
                hintText: 'Search task, subject, or note...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          setState(() {
                            _search = '';
                          });
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
              onChanged: (value) {
                setState(() {
                  _search = value;
                });
              },
            ),

            const SizedBox(height: 14),

            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                PopupMenuButton<TaskFilter>(
                  onSelected: (value) {
                    setState(() {
                      _filter = value;
                    });
                  },
                  itemBuilder: (context) => TaskFilter.values
                      .map(
                        (filter) => PopupMenuItem(
                          value: filter,
                          child: Text(_filterLabel(filter)),
                        ),
                      )
                      .toList(),
                  child: _ActionChip(
                    icon: Icons.filter_list_rounded,
                    label: 'Filter: ${_filterLabel(_filter)}',
                  ),
                ),
                PopupMenuButton<TaskSort>(
                  onSelected: (value) {
                    setState(() {
                      _sort = value;
                    });
                  },
                  itemBuilder: (context) => TaskSort.values
                      .map(
                        (sort) => PopupMenuItem(
                          value: sort,
                          child: Text(_sortLabel(sort)),
                        ),
                      )
                      .toList(),
                  child: _ActionChip(
                    icon: Icons.swap_vert_rounded,
                    label: 'Sort: ${_sortLabel(_sort)}',
                  ),
                ),
                _ActionChip(
                  icon: Icons.add_rounded,
                  label: 'New Task',
                  onTap: widget.onAddTaskPressed,
                ),
              ],
            ),

            const SizedBox(height: 18),

            if (tasks.isEmpty)
              const _EmptyCard(
                icon: Icons.checklist_outlined,
                title: 'No tasks match your filters',
                subtitle: 'Try changing the search, filter, or sort options.',
              )
            else
              ...tasks.map(
                (task) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TaskCard(
                    task: task,
                    onToggleComplete: () =>
                        widget.onToggleTaskComplete(task.id),
                    onEdit: () => widget.onEditTask(task),
                    onDelete: () => widget.onDeleteTask(task.id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// STATISTICS PAGE
// ======================================================

class StatisticsPage extends StatelessWidget {
  final List<StudyTask> tasks;
  final int totalMinutes;
  final int completedCount;
  final double completionRate;
  final Map<String, int> subjectMinutes;
  final Map<String, SubjectSummary> subjectSummaries;
  final int weeklyGoalMinutes;
  final int currentWeekMinutes;
  final double weeklyGoalProgress;
  final List<Map<String, dynamic>> last7DaysData;
  final Map<String, int> monthlyMinutes;
  final int completedThisMonth;
  final String bestSubjectThisMonth;
  final String mostProductiveDay;
  final double averageSessionLength;
  final String mostStudiedSubject;

  const StatisticsPage({
    super.key,
    required this.tasks,
    required this.totalMinutes,
    required this.completedCount,
    required this.completionRate,
    required this.subjectMinutes,
    required this.subjectSummaries,
    required this.weeklyGoalMinutes,
    required this.currentWeekMinutes,
    required this.weeklyGoalProgress,
    required this.last7DaysData,
    required this.monthlyMinutes,
    required this.completedThisMonth,
    required this.bestSubjectThisMonth,
    required this.mostProductiveDay,
    required this.averageSessionLength,
    required this.mostStudiedSubject,
  });

  String _formatMinutes(int total) {
    if (total >= 60) {
      final hours = total ~/ 60;
      return '${hours} ${hours == 1 ? 'hr' : 'hrs'}';
    }
    return '${total}m';
  }

  @override
  Widget build(BuildContext context) {
    final subjectEntries = subjectMinutes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final slowProgressSubjects = getSlowProgressSubjects(subjectSummaries);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageTitle(
              title: 'Statistics & Insights',
              subtitle: 'See your productivity, study trends, and habits.',
            ),
            const SizedBox(height: 18),

            Row(
              children: [
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.timer_rounded,
                    title: 'Total Study',
                    value: _formatMinutes(totalMinutes),
                    subtitle: 'completed study time',
                    color: Colors.indigo,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.task_alt_rounded,
                    title: 'Completed',
                    value: '$completedCount',
                    subtitle: 'finished tasks',
                    color: Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.flag_rounded,
                    title: 'Weekly Goal',
                    value: '${(weeklyGoalProgress * 100).round()}%',
                    subtitle:
                        '${_formatMinutes(currentWeekMinutes)} / ${_formatMinutes(weeklyGoalMinutes)}',
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.analytics_rounded,
                    title: 'Completion',
                    value: '${(completionRate * 100).round()}%',
                    subtitle: 'overall task completion',
                    color: Colors.purple,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Last 7 Days Study Time'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: _SimpleBarChart(
                data: last7DaysData,
                valueKey: 'minutes',
                labelKey: 'label',
                suffix: 'm',
              ),
            ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Monthly Study Minutes'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: _SimpleBarChart(
                data: monthlyMinutes.entries
                    .map((e) => {'label': e.key, 'minutes': e.value})
                    .toList(),
                valueKey: 'minutes',
                labelKey: 'label',
                suffix: 'm',
              ),
            ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Monthly Summary'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                children: [
                  _InsightTile(
                    icon: Icons.check_circle_rounded,
                    title: 'Completed this month',
                    value: '$completedThisMonth tasks',
                  ),
                  const SizedBox(height: 12),
                  _InsightTile(
                    icon: Icons.star_rounded,
                    title: 'Best subject this month',
                    value: bestSubjectThisMonth,
                  ),
                  const SizedBox(height: 12),
                  _InsightTile(
                    icon: Icons.today_rounded,
                    title: 'Most productive day',
                    value: mostProductiveDay,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Study Habit Insights'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                children: [
                  _InsightTile(
                    icon: Icons.menu_book_rounded,
                    title: 'Most studied subject',
                    value: mostStudiedSubject,
                  ),
                  const SizedBox(height: 12),
                  _InsightTile(
                    icon: Icons.schedule_rounded,
                    title: 'Average session length',
                    value: '${averageSessionLength.round()} minutes',
                  ),
                  const SizedBox(height: 12),
                  _InsightTile(
                    icon: Icons.insights_rounded,
                    title: 'Completion trend',
                    value:
                        '${(completionRate * 100).round()}% tasks completed overall',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Subjects Needing Attention'),
            const SizedBox(height: 10),
            if (slowProgressSubjects.isEmpty)
              const _EmptyCard(
                icon: Icons.insights_rounded,
                title: 'No slow-progress subjects',
                subtitle: 'The current study pace looks healthy.',
              )
            else
              Container(
                padding: const EdgeInsets.all(18),
                decoration: cardDecoration(context),
                child: Column(
                  children: slowProgressSubjects.take(3).map((summary) {
                    final progress = summary.totalTasks == 0
                        ? 0.0
                        : summary.completedTasks / summary.totalTasks;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  summary.subject,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text('${(progress * 100).round()}%'),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 8,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.10),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Subject Time Breakdown'),
            const SizedBox(height: 10),
            if (subjectEntries.isEmpty)
              const _EmptyCard(
                icon: Icons.bar_chart_outlined,
                title: 'No completed study sessions yet',
                subtitle: 'Complete tasks to see your subject breakdown.',
              )
            else
              Container(
                padding: const EdgeInsets.all(18),
                decoration: cardDecoration(context),
                child: Column(
                  children: subjectEntries.map((entry) {
                    final max = subjectEntries.first.value == 0
                        ? 1
                        : subjectEntries.first.value;
                    final progress = entry.value / max;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  entry.key,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(_formatMinutes(entry.value)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 10,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.10),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// FOCUS PAGE
// ======================================================

class FocusPage extends StatefulWidget {
  const FocusPage({super.key});

  @override
  State<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<FocusPage> {
  static const int _focusMinutes = 25;
  static const int _shortBreakMinutes = 5;
  static const int _longBreakMinutes = 15;

  Timer? _timer;
  int _remainingSeconds = _focusMinutes * 60;
  bool _running = false;
  bool _isFocusPhase = true;
  int _completedFocusSessions = 0;
  int _completedToday = 0;

  String _formatTime(int seconds) {
    final mins = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  String _phaseLabel() {
    if (_isFocusPhase) return 'Focus Session';
    if ((_completedFocusSessions % 4) == 0 && _completedFocusSessions > 0) {
      return 'Long Break';
    }
    return 'Short Break';
  }

  int _phaseDurationSeconds() {
    if (_isFocusPhase) return _focusMinutes * 60;
    if ((_completedFocusSessions % 4) == 0 && _completedFocusSessions > 0) {
      return _longBreakMinutes * 60;
    }
    return _shortBreakMinutes * 60;
  }

  int _currentSessionNumber() {
    final completed = _completedFocusSessions % 4;
    return completed == 0 ? 1 : completed + 1;
  }

  void _startPause() {
    if (_running) {
      _timer?.cancel();
      setState(() {
        _running = false;
      });
      return;
    }

    setState(() {
      _running = true;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds <= 1) {
        timer.cancel();
        setState(() {
          _remainingSeconds = 0;
          _running = false;
        });
        _handlePhaseComplete();
      } else {
        setState(() {
          _remainingSeconds--;
        });
      }
    });
  }

  void _handlePhaseComplete() {
    if (_isFocusPhase) {
      _completedFocusSessions += 1;
      _completedToday += 1;
      if (_completedFocusSessions % 4 == 0) {
        _isFocusPhase = false;
        _remainingSeconds = _longBreakMinutes * 60;
      } else {
        _isFocusPhase = false;
        _remainingSeconds = _shortBreakMinutes * 60;
      }
    } else {
      _isFocusPhase = true;
      _remainingSeconds = _focusMinutes * 60;
    }

    if (mounted) {
      final message = _isFocusPhase
          ? 'Focus session complete. Time to study again.'
          : 'Break is over. Ready for the next session.';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );

      // Show an immediate local notification (uses system default sound)
      final notifId = DateTime.now().millisecondsSinceEpoch.remainder(100000);
      NotificationService.showNow(
        id: notifId,
        title: 'Focus Timer',
        body: message,
      );
    }
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _remainingSeconds = _focusMinutes * 60;
      _running = false;
      _isFocusPhase = true;
    });
  }

  void _skipPhase() {
    _timer?.cancel();
    setState(() {
      _running = false;
      if (_isFocusPhase) {
        _completedFocusSessions += 1;
        _completedToday += 1;
      }
      _isFocusPhase = !_isFocusPhase;
      _remainingSeconds = _phaseDurationSeconds();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _remainingSeconds / _phaseDurationSeconds().clamp(1, 3600);
    final isBreak = !_isFocusPhase;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color focusTextColor = isDark ? const Color(0xFF00E5FF) : const Color(0xFF007EA7);
    final Color breakTextColor = isDark ? const Color(0xFFFFB800) : Colors.orange.shade800;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageTitle(
              title: 'Focus Mode',
              subtitle: 'Stay focused with a calm timer for deep work.',
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: cardDecoration(context).copyWith(
                borderRadius: BorderRadius.circular(30),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isBreak ? breakTextColor.withOpacity(0.16) : focusTextColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: isBreak ? breakTextColor.withOpacity(0.28) : focusTextColor.withOpacity(0.28)),
                    ),
                    child: Text(
                      isBreak ? 'Break Time' : 'Focus Session',
                      style: GoogleFonts.poppins(
                        color: isBreak ? breakTextColor : focusTextColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: 240,
                    height: 240,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 240,
                          height: 240,
                          child: CircularProgressIndicator(
                            value: progress.clamp(0.0, 1.0),
                            strokeWidth: 12,
                            backgroundColor: Colors.white.withOpacity(0.08),
                            valueColor: AlwaysStoppedAnimation<Color>(isBreak ? const Color(0xFFFFB800) : const Color(0xFF00E5FF)),
                          ),
                        ),
                        Container(
                          width: 182,
                          height: 182,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: isBreak
                                  ? [const Color(0xFFFFB800).withOpacity(0.16), const Color(0xFFFF4D6D).withOpacity(0.08)]
                                  : [const Color(0xFF7C4DFF).withOpacity(0.22), const Color(0xFF00E5FF).withOpacity(0.16)],
                            ),
                            border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _formatTime(_remainingSeconds),
                                style: GoogleFonts.orbitron(
                                  fontSize: 38,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _phaseLabel(),
                                style: GoogleFonts.poppins(
                                  color: Theme.of(context).hintColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Session ${_currentSessionNumber()}/4',
                                style: GoogleFonts.poppins(
                                  color: isBreak ? const Color(0xFFFFB800) : const Color(0xFF00E5FF),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _startPause,
                        icon: Icon(_running ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        label: Text(_running ? 'Pause' : 'Start'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF7C4DFF),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _reset,
                        icon: const Icon(Icons.restart_alt_rounded),
                        label: const Text('Reset'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _skipPhase,
                        icon: const Icon(Icons.skip_next_rounded),
                        label: const Text('Skip'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      _ActionChip(
                        icon: Icons.timer_rounded,
                        label: '25 min',
                        onTap: () {
                          _timer?.cancel();
                          setState(() {
                            _remainingSeconds = _focusMinutes * 60;
                            _running = false;
                            _isFocusPhase = true;
                          });
                        },
                      ),
                      _ActionChip(
                        icon: Icons.free_breakfast_rounded,
                        label: '5 min break',
                        onTap: () {
                          _timer?.cancel();
                          setState(() {
                            _remainingSeconds = _shortBreakMinutes * 60;
                            _running = false;
                            _isFocusPhase = false;
                          });
                        },
                      ),
                      _ActionChip(
                        icon: Icons.access_time_rounded,
                        label: '15 min break',
                        onTap: () {
                          _timer?.cancel();
                          setState(() {
                            _remainingSeconds = _longBreakMinutes * 60;
                            _running = false;
                            _isFocusPhase = false;
                          });
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _SectionHeader(title: 'Pomodoro Stats'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.check_circle_rounded,
                    title: 'Completed',
                    value: '$_completedToday',
                    subtitle: 'focus sessions today',
                    color: const Color(0xFF00FFA3),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.timeline_rounded,
                    title: 'Cycles',
                    value: '${(_completedFocusSessions ~/ 4) + 1}',
                    subtitle: 'rounds completed',
                    color: const Color(0xFF7C4DFF),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// PLANNER PAGE
// ======================================================

class PlannerPage extends StatelessWidget {
  final List<TimetableEntry> timetable;
  final VoidCallback onAddEntry;
  final void Function(TimetableEntry entry) onEditEntry;
  final Future<void> Function(String id) onDeleteEntry;

  const PlannerPage({
    super.key,
    required this.timetable,
    required this.onAddEntry,
    required this.onEditEntry,
    required this.onDeleteEntry,
  });

  @override
  Widget build(BuildContext context) {
    final days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageTitle(
              title: 'Class Timetable',
              subtitle: 'Organize your weekly classes and reminder-friendly study blocks.',
              trailing: FilledButton.icon(
                onPressed: onAddEntry,
                icon: const Icon(Icons.add),
                label: const Text('Add'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(64, 36),
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (timetable.isEmpty)
              const _EmptyCard(
                icon: Icons.event_available_outlined,
                title: 'No classes scheduled yet',
                subtitle: 'Add your Monday to Sunday timetable and stay on track.',
              )
            else
              ...days.map((day) {
                final entries = timetable.where((entry) => entry.day == day).toList()
                  ..sort((a, b) {
                    final aMinutes = a.startTime.hour * 60 + a.startTime.minute;
                    final bMinutes = b.startTime.hour * 60 + b.startTime.minute;
                    return aMinutes.compareTo(bMinutes);
                  });

                if (entries.isEmpty) return const SizedBox.shrink();

                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: cardDecoration(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          day,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 12),
                        ...entries.map((entry) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _TimetableCard(
                              entry: entry,
                              onEdit: () => onEditEntry(entry),
                              onDelete: () => onDeleteEntry(entry.id),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _TimetableCard extends StatelessWidget {
  final TimetableEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TimetableCard({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(entry.colorValue);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF1C2233)
            : const Color(0xFFF8F9FD),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.subject,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  '${format12HourTime(entry.startTime)} - ${format12HourTime(entry.endTime)}${entry.room.isEmpty ? '' : ' • ${entry.room}'}',
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') {
                onEdit();
              } else if (value == 'delete') {
                onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

// ======================================================
// FLASHCARDS PAGE
// ======================================================

class FlashcardsPage extends StatefulWidget {
  final List<Flashcard> flashcards;
  final VoidCallback onAddCard;
  final void Function(Flashcard card) onEditCard;
  final Future<void> Function(String id) onDeleteCard;
  final Future<void> Function(String id) onToggleMastered;

  const FlashcardsPage({
    super.key,
    required this.flashcards,
    required this.onAddCard,
    required this.onEditCard,
    required this.onDeleteCard,
    required this.onToggleMastered,
  });

  @override
  State<FlashcardsPage> createState() => _FlashcardsPageState();
}

class _FlashcardsPageState extends State<FlashcardsPage> {
  int _currentIndex = 0;
  bool _showAnswer = false;
  String? _selectedSubject;

  @override
  void initState() {
    super.initState();
    _selectedSubject = _getAvailableSubjects().firstOrNull;
  }

  @override
  void didUpdateWidget(covariant FlashcardsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final availableSubjects = _getAvailableSubjects();

    if (availableSubjects.isEmpty) {
      setState(() {
        _selectedSubject = null;
        _currentIndex = 0;
        _showAnswer = false;
      });
      return;
    }

    if (_selectedSubject == null || !availableSubjects.contains(_selectedSubject)) {
      setState(() {
        _selectedSubject = availableSubjects.first;
        _currentIndex = 0;
        _showAnswer = false;
      });
      return;
    }

    final cardsForSelected = _getCardsForSubject(_selectedSubject!);
    if (_currentIndex >= cardsForSelected.length) {
      setState(() {
        _currentIndex = 0;
        _showAnswer = false;
      });
    }
  }

  List<String> _getAvailableSubjects() {
    final subjects = <String>{};
    for (final card in widget.flashcards) {
      subjects.add(card.subject);
    }
    return subjects.toList()..sort();
  }

  List<Flashcard> _getCardsForSubject(String subject) {
    return widget.flashcards.where((card) => card.subject == subject).toList();
  }

  void _selectSubject(String subject) {
    setState(() {
      _selectedSubject = subject;
      _currentIndex = 0;
      _showAnswer = false;
    });
  }

  void _nextCard() {
    if (_selectedSubject == null) return;
    final cards = _getCardsForSubject(_selectedSubject!);
    setState(() {
      _showAnswer = false;
      _currentIndex = (_currentIndex + 1) % cards.length;
    });
  }

  void _previousCard() {
    if (_selectedSubject == null) return;
    final cards = _getCardsForSubject(_selectedSubject!);
    setState(() {
      _showAnswer = false;
      _currentIndex = (_currentIndex - 1 + cards.length) % cards.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.flashcards.isEmpty) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageTitle(
                title: 'Flashcards',
                subtitle: 'Create quick question-and-answer cards for offline review.',
                trailing: FilledButton.icon(
                  onPressed: widget.onAddCard,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(64, 36),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const _EmptyCard(
                icon: Icons.style_outlined,
                title: 'No flashcards yet',
                subtitle: 'Create cards and tap to reveal the answer.',
              ),
            ],
          ),
        ),
      );
    }

    final availableSubjects = _getAvailableSubjects();
    final selectedSubject = _selectedSubject ?? availableSubjects.first;
    final cardsForSubject = _getCardsForSubject(selectedSubject);

    if (cardsForSubject.isEmpty) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageTitle(
                title: 'Flashcards',
                subtitle: 'Review questions and reveal the answer when you are ready.',
                trailing: FilledButton.icon(
                  onPressed: widget.onAddCard,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(64, 36),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const _EmptyCard(
                icon: Icons.style_outlined,
                title: 'No cards for this subject',
                subtitle: 'Create cards for this subject to get started.',
              ),
            ],
          ),
        ),
      );
    }

    final card = cardsForSubject[_currentIndex];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageTitle(
              title: 'Flashcards',
              subtitle: 'Review questions and reveal the answer when you are ready.',
              trailing: FilledButton.icon(
                onPressed: widget.onAddCard,
                icon: const Icon(Icons.add),
                label: const Text('Add'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(64, 36),
                ),
              ),
            ),
            const SizedBox(height: 18),
            
            // Subject selector tabs
            if (availableSubjects.length > 1) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: availableSubjects.map((subject) {
                    final isSelected = subject == selectedSubject;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(subject),
                        selected: isSelected,
                        onSelected: (_) => _selectSubject(subject),
                        showCheckmark: false,
                        side: isSelected
                            ? BorderSide.none
                            : BorderSide(
                                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                              ),
                        backgroundColor: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).brightness == Brightness.dark
                                ? Colors.white.withOpacity(0.1)
                                : Colors.white,
                        labelStyle: TextStyle(
                          color: isSelected
                              ? Colors.white
                              : Theme.of(context).textTheme.bodyMedium?.color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 18),
            ],

            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Card ${_currentIndex + 1}/${cardsForSubject.length}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          card.subject,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  InkWell(
                    onTap: () => setState(() => _showAnswer = !_showAnswer),
                    borderRadius: BorderRadius.circular(24),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 320),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        layoutBuilder: (currentChild, previousChildren) {
                          return Stack(
                            alignment: Alignment.center,
                            children: [...previousChildren, if (currentChild != null) currentChild],
                          );
                        },
                        transitionBuilder: (child, animation) {
                          final rotateAnim = Tween(begin: math.pi, end: 0.0).animate(animation);
                          return AnimatedBuilder(
                            animation: rotateAnim,
                            child: child,
                            builder: (context, child) {
                              final isIncoming = child?.key == ValueKey<bool>(_showAnswer);
                              var value = rotateAnim.value;
                              if (!isIncoming) value = math.pi - value;
                              return Transform(
                                transform: Matrix4.identity()
                                  ..setEntry(3, 2, 0.001)
                                  ..rotateY(value),
                                alignment: Alignment.center,
                                child: child,
                              );
                            },
                          );
                        },
                        child: Container(
                          key: ValueKey<bool>(_showAnswer),
                          width: double.infinity,
                          height: 320,
                          padding: const EdgeInsets.all(24),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Color(0xFF6E8FFF),
                                Color(0xFFB0C5FF),
                              ],
                            ),
                          ),
                          child: Center(
                            child: SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Text(
                                  _showAnswer ? card.answer : card.question,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _showAnswer ? 'Tap to hide the answer' : 'Tap the card to reveal the answer',
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _previousCard,
                          icon: const Icon(Icons.arrow_back_rounded),
                          label: const Text('Previous'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _nextCard,
                          icon: const Icon(Icons.arrow_forward_rounded),
                          label: const Text('Next'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => widget.onToggleMastered(card.id),
                          icon: Icon(card.mastered ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded),
                          label: Text(card.mastered ? 'Mastered' : 'Mark mastered'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            widget.onEditCard(card);
                          } else if (value == 'delete') {
                            widget.onDeleteCard(card.id);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FlashcardEditorSheet extends StatefulWidget {
  final Flashcard? existingCard;
  final List<String> plannerSubjects;

  const FlashcardEditorSheet({
    super.key,
    required this.existingCard,
    required this.plannerSubjects,
  });

  @override
  State<FlashcardEditorSheet> createState() => _FlashcardEditorSheetState();
}

class _FlashcardEditorSheetState extends State<FlashcardEditorSheet> {
  late TextEditingController _questionController;
  late TextEditingController _answerController;
  String? _selectedSubject;

  @override
  void initState() {
    super.initState();
    final card = widget.existingCard;
    _questionController = TextEditingController(text: card?.question ?? '');
    _answerController = TextEditingController(text: card?.answer ?? '');
    _selectedSubject = card?.subject?.trim().isNotEmpty == true
        ? card!.subject.trim()
        : (widget.plannerSubjects.isNotEmpty ? widget.plannerSubjects.first : null);
  }

  @override
  void dispose() {
    _questionController.dispose();
    _answerController.dispose();
    super.dispose();
  }

  void _save() {
    if (_questionController.text.trim().isEmpty || _answerController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Question and answer are required.')),
      );
      return;
    }

    if (_selectedSubject == null || _selectedSubject!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please choose a subject from the planner.')),
      );
      return;
    }

    final card = Flashcard(
      id: widget.existingCard?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      question: _questionController.text.trim(),
      answer: _answerController.text.trim(),
      subject: _selectedSubject!.trim(),
      mastered: widget.existingCard?.mastered ?? false,
    );

    Navigator.pop(context, card);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(18, 18, 18, bottom + 18),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existingCard == null ? 'Add Flashcard' : 'Edit Flashcard',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _questionController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Question',
                prefixIcon: Icon(Icons.help_outline_rounded),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _answerController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Answer',
                prefixIcon: Icon(Icons.lightbulb_outline_rounded),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              isDense: true,
              value: _selectedSubject?.trim().isNotEmpty == true ? _selectedSubject!.trim() : null,
              decoration: const InputDecoration(
                labelText: 'Subject',
                prefixIcon: Icon(Icons.menu_book_rounded),
                contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              ),
              items: [
                ...widget.plannerSubjects.map(
                  (subject) => DropdownMenuItem(
                    value: subject,
                    child: Text(subject),
                  ),
                ),
                if (_selectedSubject != null &&
                    _selectedSubject!.trim().isNotEmpty &&
                    !widget.plannerSubjects.contains(_selectedSubject!.trim()))
                  DropdownMenuItem(
                    value: _selectedSubject!.trim(),
                    child: Text(_selectedSubject!.trim()),
                  ),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedSubject = value;
                });
              },
              hint: widget.plannerSubjects.isEmpty
                  ? const Text('Add a class in Class Planner first')
                  : null,
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_rounded),
              label: Text(widget.existingCard == null ? 'Create Card' : 'Save Changes'),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// DEADLINES PAGE
// ======================================================

class DeadlinesPage extends StatefulWidget {
  final List<DeadlineItem> deadlines;
  final VoidCallback onAddDeadline;
  final void Function(DeadlineItem item) onEditDeadline;
  final Future<void> Function(String id) onDeleteDeadline;
  final int Function(DateTime date) daysUntil;

  const DeadlinesPage({
    super.key,
    required this.deadlines,
    required this.onAddDeadline,
    required this.onEditDeadline,
    required this.onDeleteDeadline,
    required this.daysUntil,
  });

  @override
  State<DeadlinesPage> createState() => _DeadlinesPageState();
}

class _DeadlinesPageState extends State<DeadlinesPage> {
  final ScrollController _scrollController = ScrollController();
  bool _isRefreshing = false;
  double _pullDistance = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshDeadlinePage() async {
    if (!mounted || _isRefreshing) return;

    setState(() {
      _isRefreshing = true;
      _pullDistance = 0;
    });

    try {
      await Future<void>.delayed(const Duration(milliseconds: 240));
    } finally {
      if (mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 480));
        setState(() {
          _isRefreshing = false;
          _pullDistance = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.deadlines]..sort((a, b) => a.date.compareTo(b.date));
    final indicatorOpacity = (_pullDistance / 90).clamp(0.0, 1.0);

    return SafeArea(
      child: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification &&
                  _scrollController.offset <= 0 &&
                  notification.dragDetails != null) {
                final delta = notification.dragDetails!.delta.dy;
                if (delta > 0) {
                  setState(() {
                    _pullDistance = (_pullDistance + delta).clamp(0.0, 110.0);
                  });
                }
                if (_pullDistance >= 90 && !_isRefreshing) {
                  _refreshDeadlinePage();
                }
              }
              if (notification is ScrollEndNotification) {
                if (!_isRefreshing) {
                  setState(() {
                    _pullDistance = 0;
                  });
                }
              }
              return false;
            },
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
              children: [
                PageTitle(
                  title: 'Deadlines & Exams',
                  subtitle: 'Track quizzes, exams, projects, and due dates.',
                  trailing: FilledButton.icon(
                    onPressed: widget.onAddDeadline,
                    icon: const Icon(Icons.add),
                    label: const Text('Add'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      minimumSize: const Size(64, 36),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                if (sorted.isEmpty)
                  const _EmptyCard(
                    icon: Icons.event_busy_outlined,
                    title: 'No deadlines yet',
                    subtitle: 'Add an exam or due date to start your countdown.',
                  )
                else
                  ...sorted.map((item) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _DeadlineFullCard(
                        item: item,
                        daysLeft: widget.daysUntil(item.date),
                        onEdit: () => widget.onEditDeadline(item),
                        onDelete: () => widget.onDeleteDeadline(item.id),
                      ),
                    );
                  }),
              ],
            ),
          ),
          Positioned(
            top: 6 + _pullDistance * 0.35,
            left: 0,
            right: 0,
            child: Center(
              child: Opacity(
                opacity: indicatorOpacity,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: _isRefreshing
                            ? const CircularProgressIndicator(strokeWidth: 2)
                            : const Icon(Icons.arrow_downward_rounded, size: 16),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isRefreshing ? 'Refreshing countdowns...' : 'Pull to refresh',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ======================================================
// SETTINGS / PROFILE PAGE
// ======================================================

class SettingsPage extends StatefulWidget {
  final AppSettings settings;
  final int streakCount;
  final int currentWeekMinutes;
  final Future<void> Function() onShowDeletedItems;
  final Future<void> Function(AppSettings settings) onSaveSettings;
  final Future<void> Function() onResetData;

  const SettingsPage({
    super.key,
    required this.settings,
    required this.streakCount,
    required this.currentWeekMinutes,
    required this.onShowDeletedItems,
    required this.onSaveSettings,
    required this.onResetData,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _nameController;
  late TextEditingController _schoolController;
  late TextEditingController _yearController;
  late TextEditingController _goalController;

  late bool _darkMode;
  late bool _notifications;
  late String? _profilePhotoBase64;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.settings.displayName);
    _schoolController =
        TextEditingController(text: widget.settings.schoolOrCourse);
    _yearController =
        TextEditingController(text: widget.settings.yearLevel);
    _goalController =
        TextEditingController(text: widget.settings.weeklyGoalMinutes.toString());
    _darkMode = widget.settings.darkMode;
    _notifications = widget.settings.notificationsEnabled;
    _profilePhotoBase64 = widget.settings.profilePhotoBase64;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _schoolController.dispose();
    _yearController.dispose();
    _goalController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final goal = int.tryParse(_goalController.text.trim()) ?? 600;

    final updated = AppSettings(
      displayName: _nameController.text.trim().isEmpty
          ? 'Student'
          : _nameController.text.trim(),
      darkMode: _darkMode,
      weeklyGoalMinutes: goal,
      notificationsEnabled: _notifications,
      schoolOrCourse: _schoolController.text.trim(),
      yearLevel: _yearController.text.trim(),
      profilePhotoBase64: _profilePhotoBase64,
    );

    await widget.onSaveSettings(updated);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile and settings saved.')),
      );
    }
  }

  Future<void> _showDeletedItems() async {
    await widget.onShowDeletedItems();
  }


  Future<void> _confirmReset() async {
    final yes = await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Reset all app data?'),
              content: const Text(
                'This will remove your current tasks, notes, deadlines, and settings, then load sample data again.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Reset'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!yes) return;

    await widget.onResetData();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('App data reset complete.')),
    );
  }

  String _formatMinutes(int total) {
    if (total >= 60) {
      final hours = total ~/ 60;
      return '${hours} ${hours == 1 ? 'hr' : 'hrs'}';
    }
    return '${total}m';
  }

  Future<void> _pickProfilePhoto() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );

    if (pickedFile == null) return;

    final bytes = await pickedFile.readAsBytes();

    if (!mounted) return;

    setState(() {
      _profilePhotoBase64 = base64Encode(bytes);
    });

    final updated = AppSettings(
      displayName: _nameController.text.trim().isEmpty
          ? 'Student'
          : _nameController.text.trim(),
      darkMode: _darkMode,
      weeklyGoalMinutes: int.tryParse(_goalController.text.trim()) ?? 600,
      notificationsEnabled: _notifications,
      schoolOrCourse: _schoolController.text.trim(),
      yearLevel: _yearController.text.trim(),
      profilePhotoBase64: _profilePhotoBase64,
    );

    await widget.onSaveSettings(updated);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profile photo updated.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageTitle(
              title: 'Profile & Settings',
              subtitle: 'Personalize your planner and manage backup options.',
            ),
            const SizedBox(height: 18),

            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Row(
                children: [
                  InkWell(
                    onTap: _pickProfilePhoto,
                    borderRadius: BorderRadius.circular(30),
                    child: CircleAvatar(
                      radius: 30,
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(0.12),
                      backgroundImage: _profilePhotoBase64 != null &&
                              _profilePhotoBase64!.isNotEmpty
                          ? MemoryImage(base64Decode(_profilePhotoBase64!))
                          : null,
                      child: _profilePhotoBase64 != null &&
                              _profilePhotoBase64!.isNotEmpty
                          ? null
                          : Text(
                              (_nameController.text.trim().isEmpty
                                      ? 'S'
                                      : _nameController.text.trim()[0])
                                  .toUpperCase(),
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 24,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _nameController.text.trim().isEmpty
                              ? 'Student'
                              : _nameController.text.trim(),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _schoolController.text.trim().isEmpty
                              ? 'Add your school or course'
                              : _schoolController.text.trim(),
                          style: TextStyle(color: Theme.of(context).hintColor),
                        ),
                        if (_yearController.text.trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            _yearController.text.trim(),
                            style: TextStyle(
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            Row(
              children: [
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.local_fire_department_rounded,
                    title: 'Streak',
                    value: '${widget.streakCount}',
                    subtitle: 'days',
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MiniStatCard(
                    icon: Icons.timer_rounded,
                    title: 'This Week',
                    value: _formatMinutes(widget.currentWeekMinutes),
                    subtitle: 'study time',
                    color: Colors.indigo,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Profile'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                children: [
                  TextField(
                    controller: _nameController,
                    style: GoogleFonts.orbitron(fontSize: 14, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      labelText: 'Display name',
                      labelStyle: GoogleFonts.orbitron(fontSize: 14, fontWeight: FontWeight.w600),
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _schoolController,
                    style: GoogleFonts.orbitron(fontSize: 14, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      labelText: 'School / Course',
                      labelStyle: GoogleFonts.orbitron(fontSize: 14, fontWeight: FontWeight.w600),
                      prefixIcon: const Icon(Icons.school_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _yearController,
                    style: GoogleFonts.orbitron(fontSize: 14, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      labelText: 'Year level / Section',
                      labelStyle: GoogleFonts.orbitron(fontSize: 14, fontWeight: FontWeight.w600),
                      prefixIcon: const Icon(Icons.badge_outlined),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Study Preferences'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                children: [
                  TextField(
                    controller: _goalController,
                    keyboardType: TextInputType.number,
                    style: GoogleFonts.orbitron(fontSize: 14, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      labelText: 'Weekly study goal (minutes)',
                      labelStyle: GoogleFonts.orbitron(fontSize: 14, fontWeight: FontWeight.w600),
                      prefixIcon: const Icon(Icons.flag_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    // Reflect the actual current app theme so the switch stays
                    // in sync when navigating between pages.
                    value: Theme.of(context).brightness == Brightness.dark,
                    onChanged: (value) {
                      setState(() {
                        _darkMode = value;
                      });
                      // Apply theme immediately even if settings aren't saved
                      StudySyncScope.of(context).onThemeChanged(_darkMode);
                    },
                    title: Text(
                      'Dark mode',
                      style: GoogleFonts.orbitron(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'Use a darker app theme',
                      style: GoogleFonts.orbitron(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _notifications,
                    onChanged: (value) {
                      setState(() {
                        _notifications = value;
                      });
                    },
                    title: Text(
                      'Task reminders',
                      style: GoogleFonts.orbitron(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'Allow local study notifications',
                      style: GoogleFonts.orbitron(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),

            const _SectionHeader(title: 'Recovery'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: cardDecoration(context),
              child: Column(
                children: [
                  _SettingsActionTile(
                    icon: Icons.restore_from_trash_rounded,
                    title: 'Restore deleted items',
                    subtitle:
                        'Recover tasks, deadlines, and activities removed earlier.',
                    onTap: _showDeletedItems,
                  ),
                  const SizedBox(height: 12),
                  _SettingsActionTile(
                    icon: Icons.restart_alt_rounded,
                    title: 'Reset app data',
                    subtitle:
                        'Clear your current local data and load the sample starter data again.',
                    onTap: _confirmReset,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_rounded),
              label: Text(
                'Save Settings',
                style: GoogleFonts.orbitron(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// TASK EDITOR SHEET
// ======================================================

class TaskEditorSheet extends StatefulWidget {
  final StudyTask? existingTask;
  final DateTime? prefilledDate;
  final bool notificationsEnabled;
  final List<String> plannerSubjects;
  final int Function(String subject) autoColorForSubject;

  const TaskEditorSheet({
    super.key,
    required this.existingTask,
    required this.prefilledDate,
    required this.notificationsEnabled,
    required this.plannerSubjects,
    required this.autoColorForSubject,
  });

  @override
  State<TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends State<TaskEditorSheet> {
  late TextEditingController _titleController;
  late TextEditingController _noteController;
  String? _selectedSubject;

  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late TaskPriority _priority;
  late TaskCategory _category;
  late bool _reminderEnabled;

  bool get _isEditing => widget.existingTask != null;

  @override
  void initState() {
    super.initState();
    final task = widget.existingTask;

    _titleController = TextEditingController(text: task?.title ?? '');
    _noteController = TextEditingController(text: task?.note ?? '');
    _selectedSubject = task?.subject?.trim().isNotEmpty == true
        ? task!.subject.trim()
        : (widget.plannerSubjects.isNotEmpty ? widget.plannerSubjects.first : null);

    final now = DateTime.now();

    _date = task?.date ??
        widget.prefilledDate ??
        DateTime(now.year, now.month, now.day);

    _startTime = task?.startTime ?? const TimeOfDay(hour: 9, minute: 0);
    _endTime = task?.endTime ?? const TimeOfDay(hour: 10, minute: 0);
    _priority = task?.priority ?? TaskPriority.medium;
    _category = task?.category ?? TaskCategory.study;
    _reminderEnabled = task?.reminderEnabled ?? false;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _date = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );

    if (picked != null) {
      setState(() {
        _startTime = picked;
      });
    }
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );

    if (picked != null) {
      setState(() {
        _endTime = picked;
      });
    }
  }

  void _save() {
    if (_titleController.text.trim().isEmpty ||
        _selectedSubject == null ||
        _selectedSubject!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Task title and subject are required.'),
        ),
      );
      return;
    }

    final task = StudyTask(
      id: widget.existingTask?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      title: _titleController.text.trim(),
      subject: _selectedSubject!.trim(),
      note: _noteController.text.trim(),
      date: _date,
      startTime: _startTime,
      endTime: _endTime,
      completed: widget.existingTask?.completed ?? false,
      colorValue: widget.autoColorForSubject(_selectedSubject!.trim()),
      priority: _priority,
      reminderEnabled:
          widget.notificationsEnabled ? _reminderEnabled : false,
      category: _category,
    );

    Navigator.pop(context, task);
  }

  String _priorityLabel(TaskPriority priority) {
    switch (priority) {
      case TaskPriority.low:
        return 'Low';
      case TaskPriority.medium:
        return 'Medium';
      case TaskPriority.high:
        return 'High';
    }
  }

  String _categoryLabel(TaskCategory category) {
    switch (category) {
      case TaskCategory.study:
        return 'Study';
      case TaskCategory.assignment:
        return 'Assignment';
      case TaskCategory.quiz:
        return 'Quiz';
      case TaskCategory.exam:
        return 'Exam';
      case TaskCategory.project:
        return 'Project';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(18, 18, 18, bottom + 18),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isEditing ? 'Edit Task' : 'Add Task',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Task title',
                prefixIcon: Icon(Icons.title_rounded),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              isDense: true,
              menuMaxHeight: 320,
              value: _selectedSubject?.trim().isNotEmpty == true ? _selectedSubject!.trim() : null,
              decoration: const InputDecoration(
                labelText: 'Subject',
                prefixIcon: Icon(Icons.menu_book_rounded),
                contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              ),
              items: [
                ...widget.plannerSubjects.map(
                  (subject) => DropdownMenuItem(
                    value: subject,
                    child: Text(subject),
                  ),
                ),
                if (_selectedSubject != null &&
                    _selectedSubject!.trim().isNotEmpty &&
                    !widget.plannerSubjects.contains(_selectedSubject!.trim()))
                  DropdownMenuItem(
                    value: _selectedSubject!.trim(),
                    child: Text(_selectedSubject!.trim()),
                  ),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedSubject = value;
                });
              },
              hint: widget.plannerSubjects.isEmpty
                  ? const Text('Add a class in Class Planner first')
                  : null,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                prefixIcon: Icon(Icons.notes_rounded),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: _PickerTile(
                    icon: Icons.calendar_today_rounded,
                    title: 'Date',
                    value: DateFormat('MMM d, yyyy').format(_date),
                    onTap: _pickDate,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PickerTile(
                    icon: Icons.schedule_rounded,
                    title: 'Start',
                    value: format12HourTime(_startTime),
                    onTap: _pickStartTime,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PickerTile(
                    icon: Icons.schedule_rounded,
                    title: 'End',
                    value: _endTime.format(context),
                    onTap: _pickEndTime,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: PopupMenuButton<TaskPriority>(
                    onSelected: (value) {
                      setState(() {
                        _priority = value;
                      });
                    },
                    itemBuilder: (context) => TaskPriority.values
                        .map(
                          (priority) => PopupMenuItem(
                            value: priority,
                            child: Text(_priorityLabel(priority)),
                          ),
                        )
                        .toList(),
                    child: _PickerTile(
                      icon: Icons.priority_high_rounded,
                      title: 'Priority',
                      value: _priorityLabel(_priority),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PopupMenuButton<TaskCategory>(
                    onSelected: (value) {
                      setState(() {
                        _category = value;
                      });
                    },
                    itemBuilder: (context) => TaskCategory.values
                        .map(
                          (category) => PopupMenuItem(
                            value: category,
                            child: Text(_categoryLabel(category)),
                          ),
                        )
                        .toList(),
                    child: _PickerTile(
                      icon: Icons.category_rounded,
                      title: 'Category',
                      value: _categoryLabel(_category),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.notificationsEnabled ? _reminderEnabled : false,
              onChanged: widget.notificationsEnabled
                  ? (value) {
                      setState(() {
                        _reminderEnabled = value;
                      });
                    }
                  : null,
              title: const Text('Reminder'),
              subtitle: Text(
                widget.notificationsEnabled
                    ? 'Notify me 10 minutes before the task'
                    : 'Enable reminders in Profile / Settings first',
              ),
            ),

            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_rounded),
              label: Text(_isEditing ? 'Save Changes' : 'Create Task'),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// DEADLINE EDITOR SHEET
// ======================================================

class DeadlineEditorSheet extends StatefulWidget {
  final DeadlineItem? existingDeadline;
  final List<String> plannerSubjects;
  final int Function(String subject) autoColorForSubject;

  const DeadlineEditorSheet({
    super.key,
    required this.existingDeadline,
    required this.plannerSubjects,
    required this.autoColorForSubject,
  });

  @override
  State<DeadlineEditorSheet> createState() => _DeadlineEditorSheetState();
}

class _DeadlineEditorSheetState extends State<DeadlineEditorSheet> {
  late TextEditingController _titleController;
  late TextEditingController _noteController;
  String? _selectedSubject;
  late DateTime _date;
  late TaskCategory _category;

  bool get _isEditing => widget.existingDeadline != null;

  @override
  void initState() {
    super.initState();
    final item = widget.existingDeadline;

    _titleController = TextEditingController(text: item?.title ?? '');
    _noteController = TextEditingController(text: item?.note ?? '');
    _selectedSubject = item?.subject?.trim().isNotEmpty == true
        ? item!.subject.trim()
        : (widget.plannerSubjects.isNotEmpty ? widget.plannerSubjects.first : null);
    _date = item?.date ?? DateTime.now().add(const Duration(days: 1));
    _category = item?.category ?? TaskCategory.exam;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2024),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _date = DateTime(
          picked.year,
          picked.month,
          picked.day,
          _date.hour,
          _date.minute,
        );
      });
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _date.hour, minute: _date.minute),
    );

    if (picked != null) {
      setState(() {
        _date = DateTime(
          _date.year,
          _date.month,
          _date.day,
          picked.hour,
          picked.minute,
        );
      });
    }
  }

  String _categoryLabel(TaskCategory category) {
    switch (category) {
      case TaskCategory.study:
        return 'Study';
      case TaskCategory.assignment:
        return 'Assignment';
      case TaskCategory.quiz:
        return 'Quiz';
      case TaskCategory.exam:
        return 'Exam';
      case TaskCategory.project:
        return 'Project';
    }
  }

  void _save() {
    if (_titleController.text.trim().isEmpty ||
        _selectedSubject == null ||
        _selectedSubject!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title and subject are required.')),
      );
      return;
    }

    final item = DeadlineItem(
      id: widget.existingDeadline?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      title: _titleController.text.trim(),
      subject: _selectedSubject!.trim(),
      date: _date,
      category: _category,
      note: _noteController.text.trim(),
      colorValue: widget.autoColorForSubject(_selectedSubject!.trim()),
    );

    Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(18, 18, 18, bottom + 18),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isEditing ? 'Edit Deadline' : 'Add Deadline',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                prefixIcon: Icon(Icons.event_note_rounded),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              isDense: true,
              menuMaxHeight: 320,
              value: _selectedSubject?.trim().isNotEmpty == true ? _selectedSubject!.trim() : null,
              decoration: const InputDecoration(
                labelText: 'Subject',
                prefixIcon: Icon(Icons.menu_book_rounded),
                contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              ),
              items: [
                ...widget.plannerSubjects.map(
                  (subject) => DropdownMenuItem(
                    value: subject,
                    child: Text(subject),
                  ),
                ),
                if (_selectedSubject != null &&
                    _selectedSubject!.trim().isNotEmpty &&
                    !widget.plannerSubjects.contains(_selectedSubject!.trim()))
                  DropdownMenuItem(
                    value: _selectedSubject!.trim(),
                    child: Text(_selectedSubject!.trim()),
                  ),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedSubject = value;
                });
              },
              hint: widget.plannerSubjects.isEmpty
                  ? const Text('Add a class in Class Planner first')
                  : null,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                prefixIcon: Icon(Icons.notes_rounded),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _PickerTile(
                    icon: Icons.calendar_today_rounded,
                    title: 'Date',
                    value: DateFormat('MMM d, yyyy').format(_date),
                    onTap: _pickDate,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PickerTile(
                    icon: Icons.access_time_rounded,
                    title: 'Time',
                    value: DateFormat.jm().format(_date),
                    onTap: _pickTime,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            PopupMenuButton<TaskCategory>(
              onSelected: (value) {
                setState(() {
                  _category = value;
                });
              },
              itemBuilder: (context) => [
                TaskCategory.assignment,
                TaskCategory.quiz,
                TaskCategory.exam,
                TaskCategory.project,
              ]
                  .map(
                    (category) => PopupMenuItem(
                      value: category,
                      child: Text(_categoryLabel(category)),
                    ),
                  )
                  .toList(),
              child: _PickerTile(
                icon: Icons.category_rounded,
                title: 'Type',
                value: _categoryLabel(_category),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_rounded),
              label:
                  Text(_isEditing ? 'Save Changes' : 'Create Deadline'),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================================================
// COMMON WIDGETS
// ======================================================

BoxDecoration cardDecoration(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    gradient: LinearGradient(
      colors: isDark
          ? [const Color(0xFF1A1F2E), const Color(0xFF111827)]
          : [const Color(0xFFFFFFFF), const Color(0xFFF4F7FF)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(
      color: isDark ? const Color(0xFF2B3553) : const Color(0xFFE7EBF4),
      width: 1.2,
    ),
    boxShadow: [
      BoxShadow(
        color: isDark ? const Color(0xFF7C4DFF).withOpacity(0.16) : const Color(0xFF7C4DFF).withOpacity(0.10),
        blurRadius: 24,
        offset: const Offset(0, 12),
      ),
      BoxShadow(
        color: isDark ? const Color(0xFF00E5FF).withOpacity(0.10) : const Color(0xFF00E5FF).withOpacity(0.06),
        blurRadius: 34,
        offset: const Offset(0, 2),
      ),
    ],
  );
}

class PageTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;

  const PageTitle({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.poppins(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: GoogleFonts.poppins(
                  color: Theme.of(context).hintColor,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  final String greeting;
  final String displayName;
  final int taskCount;
  final String schoolOrCourse;
  final String yearLevel;
  final String? profilePhotoBase64;

  const _DashboardHeader({
    required this.greeting,
    required this.displayName,
    required this.taskCount,
    required this.schoolOrCourse,
    required this.yearLevel,
    this.profilePhotoBase64,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: cardDecoration(context).copyWith(
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C4DFF).withOpacity(0.16),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.28)),
                  ),
                  child: Text(
                    'STUDY DASHBOARD',
                    style: GoogleFonts.poppins(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF00E5FF)
                          : Theme.of(context).colorScheme.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$greeting, $displayName',
                  style: GoogleFonts.orbitron(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  taskCount == 0
                      ? 'No study tasks scheduled for today.'
                      : '$taskCount ${taskCount == 1 ? 'task' : 'tasks'} planned today.',
                  style: GoogleFonts.poppins(
                    color: Theme.of(context).hintColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (schoolOrCourse.trim().isNotEmpty || yearLevel.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (schoolOrCourse.trim().isNotEmpty) schoolOrCourse.trim(),
                      if (yearLevel.trim().isNotEmpty) yearLevel.trim(),
                    ].join(' • '),
                    style: GoogleFonts.poppins(
                      color: Theme.of(context).hintColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF7C4DFF), Color(0xFF00E5FF)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7C4DFF).withOpacity(0.28),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: profilePhotoBase64 != null && profilePhotoBase64!.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(29),
                    child: Image.memory(
                      base64Decode(profilePhotoBase64!),
                      fit: BoxFit.cover,
                      width: 58,
                      height: 58,
                    ),
                  )
                : Center(
                    child: Text(
                      displayName.isEmpty ? 'S' : displayName[0].toUpperCase(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _HeroSummaryCard extends StatelessWidget {
  final double completionRate;
  final int completedCount;
  final int totalCount;

  const _HeroSummaryCard({
    required this.completionRate,
    required this.completedCount,
    required this.totalCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          colors: [Color(0xFF7C4DFF), Color(0xFF1A1F2E), Color(0xFF00E5FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7C4DFF).withOpacity(0.28),
            blurRadius: 28,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'STUDY OVERVIEW',
                  style: GoogleFonts.poppins(
                    color: const Color(0xFF00E5FF),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Christian',
                  style: GoogleFonts.orbitron(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Study streak and progress',
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Weekly progress',
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: completionRate,
                    minHeight: 10,
                    backgroundColor: Colors.white.withOpacity(0.16),
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00FFA3)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${(completionRate * 100).round()}% complete',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.24), width: 2),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00E5FF).withOpacity(0.25),
                  blurRadius: 18,
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: CircularProgressIndicator(
                    value: completionRate,
                    strokeWidth: 8,
                    backgroundColor: Colors.white.withOpacity(0.12),
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00FFA3)),
                  ),
                ),
                Text(
                  '${(completionRate * 100).round()}%',
                  style: GoogleFonts.orbitron(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStatCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;
  final Color color;

  const _MiniStatCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(0.28)),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: GoogleFonts.poppins(
              color: Theme.of(context).hintColor,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.orbitron(
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: GoogleFonts.poppins(color: Theme.of(context).hintColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? actionText;
  final VoidCallback? onActionTap;

  const _SectionHeader({
    required this.title,
    this.actionText,
    this.onActionTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: GoogleFonts.orbitron(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ),
        if (actionText != null && onActionTap != null)
          TextButton(
            onPressed: onActionTap,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF00E5FF),
            ),
            child: Text(actionText!, style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: cardDecoration(context),
      child: Column(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: const Color(0xFF7C4DFF).withOpacity(0.16),
            child: Icon(
              icon,
              color: const Color(0xFF00E5FF),
              size: 28,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.orbitron(
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(color: Theme.of(context).hintColor, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _UrgentDeadlineCard extends StatelessWidget {
  final DeadlineItem item;
  final int daysLeft;

  const _UrgentDeadlineCard({
    required this.item,
    required this.daysLeft,
  });

  String _daysText() {
    if (daysLeft < 0) return 'Overdue';
    if (daysLeft == 0) return 'Today';
    if (daysLeft == 1) return 'Tomorrow';
    return '$daysLeft days left';
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(item.colorValue);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [
            color,
            color.withOpacity(0.78),
          ],
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: Colors.white.withOpacity(0.18),
            child: const Icon(Icons.event_note_rounded, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${item.subject} • ${DateFormat('MMM d, yyyy').format(item.date)}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _daysText(),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeadlinePreviewCard extends StatelessWidget {
  final DeadlineItem item;
  final int daysLeft;

  const _DeadlinePreviewCard({
    required this.item,
    required this.daysLeft,
  });

  String _daysText() {
    if (daysLeft < 0) return 'Overdue';
    if (daysLeft == 0) return 'Today';
    if (daysLeft == 1) return 'Tomorrow';
    return '$daysLeft days left';
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(item.colorValue);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 60,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${item.subject} • ${DateFormat('MMM d, yyyy').format(item.date)}',
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
          Text(
            _daysText(),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SlowProgressSubjectCard extends StatelessWidget {
  final SubjectSummary summary;

  const _SlowProgressSubjectCard({required this.summary});

  String _formatMinutes(int total) {
    if (total >= 60) {
      final hours = total ~/ 60;
      return '${hours} ${hours == 1 ? 'hr' : 'hrs'}';
    }
    return '${total}m';
  }

  @override
  Widget build(BuildContext context) {
    final progress = summary.totalTasks == 0
        ? 0.0
        : summary.completedTasks / summary.totalTasks;
    final color = Color(summary.colorValue);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withOpacity(0.14),
                child: Icon(Icons.trending_down_rounded, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.subject,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Low completion pace',
                      style: TextStyle(color: Theme.of(context).hintColor),
                    ),
                  ],
                ),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: color.withOpacity(0.12),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${summary.completedTasks}/${summary.totalTasks} tasks done • ${_formatMinutes(summary.totalMinutes)} studied',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }
}

class _SubjectOverviewCard extends StatelessWidget {
  final SubjectSummary summary;

  const _SubjectOverviewCard({required this.summary});

  String _formatMinutes(int total) {
    if (total >= 60) {
      final hours = total ~/ 60;
      return '${hours} ${hours == 1 ? 'hr' : 'hrs'}';
    }
    return '${total}m';
  }

  @override
  Widget build(BuildContext context) {
    final progress = summary.totalTasks == 0
        ? 0.0
        : summary.completedTasks / summary.totalTasks;
    final color = Color(summary.colorValue);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withOpacity(0.14),
                child: Icon(Icons.menu_book_rounded, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  summary.subject,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                '${summary.completedTasks}/${summary.totalTasks}',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: color.withOpacity(0.12),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Completed ${summary.completedTasks} tasks • ${_formatMinutes(summary.totalMinutes)} studied',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }
}

class _NextTaskCard extends StatelessWidget {
  final StudyTask task;

  const _NextTaskCard({required this.task});

  @override
  Widget build(BuildContext context) {
    final color = Color(task.colorValue);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: cardDecoration(context),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: color.withOpacity(0.14),
            child: Icon(Icons.schedule_rounded, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${task.subject} • ${DateFormat('MMM d').format(task.date)} • ${format12HourTime(task.startTime)}',
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
          _PriorityBadge(priority: task.priority),
        ],
      ),
    );
  }
}

class TaskCard extends StatelessWidget {
  final StudyTask task;
  final VoidCallback onToggleComplete;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const TaskCard({
    super.key,
    required this.task,
    required this.onToggleComplete,
    required this.onEdit,
    required this.onDelete,
  });

  String _priorityLabel(TaskPriority priority) {
    switch (priority) {
      case TaskPriority.low:
        return 'Low';
      case TaskPriority.medium:
        return 'Medium';
      case TaskPriority.high:
        return 'High';
    }
  }

  String _categoryLabel(TaskCategory category) {
    switch (category) {
      case TaskCategory.study:
        return 'Study';
      case TaskCategory.assignment:
        return 'Assignment';
      case TaskCategory.quiz:
        return 'Quiz';
      case TaskCategory.exam:
        return 'Exam';
      case TaskCategory.project:
        return 'Project';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(task.colorValue);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context).copyWith(
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onToggleComplete,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: task.completed ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color, width: 2),
                boxShadow: task.completed
                    ? [BoxShadow(color: color.withOpacity(0.28), blurRadius: 10)]
                    : null,
              ),
              child: task.completed
                  ? const Icon(Icons.check, color: Colors.white, size: 18)
                  : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.title,
                        style: GoogleFonts.orbitron(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          decoration: task.completed ? TextDecoration.lineThrough : null,
                          color: task.completed ? Theme.of(context).hintColor : null,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.16),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: color.withOpacity(0.28)),
                      ),
                      child: Text(
                        _categoryLabel(task.category),
                        style: GoogleFonts.poppins(
                          color: color,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  task.subject,
                  style: GoogleFonts.poppins(
                    color: const Color(0xFF00E5FF),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TaskInfoPill(
                      icon: Icons.calendar_today_rounded,
                      label: DateFormat('MMM d, yyyy').format(task.date),
                    ),
                    _TaskInfoPill(
                      icon: Icons.schedule_rounded,
                      label: '${format12HourTime(task.startTime)} - ${format12HourTime(task.endTime)}',
                    ),
                    _PriorityBadge(priority: task.priority),
                  ],
                ),
                if (task.note.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    task.note,
                    style: GoogleFonts.poppins(color: Theme.of(context).hintColor, fontSize: 12),
                  ),
                ],
                if (task.reminderEnabled) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.notifications_active_outlined,
                        size: 16,
                        color: const Color(0xFF00E5FF),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Reminder enabled',
                        style: GoogleFonts.poppins(
                          color: const Color(0xFF00E5FF),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') {
                onEdit();
              } else if (value == 'delete') {
                onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

class _TaskInfoPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TaskInfoPill({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? const Color(0xFF111827) : Colors.white;
    final borderColor = isDark ? const Color(0xFF2B3553) : const Color(0xFFE7EBF4);
    final textColor = isDark ? Colors.white : Theme.of(context).textTheme.bodyMedium?.color ?? Colors.black87;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF00E5FF)),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600,
              fontSize: 11,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  final TaskPriority priority;

  const _PriorityBadge({required this.priority});

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final String label;

    switch (priority) {
      case TaskPriority.low:
        color = const Color(0xFF00FFA3);
        label = 'Low';
        break;
      case TaskPriority.medium:
        color = const Color(0xFFFFB800);
        label = 'Medium';
        break;
      case TaskPriority.high:
        color = const Color(0xFFFF4D6D);
        label = 'High';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.28)),
      ),
      child: Text(
        label,
        style: GoogleFonts.poppins(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _TaskCategoryBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _TaskCategoryBadge({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _DeadlineFullCard extends StatelessWidget {
  final DeadlineItem item;
  final int daysLeft;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _DeadlineFullCard({
    required this.item,
    required this.daysLeft,
    required this.onEdit,
    required this.onDelete,
  });

  String _categoryLabel(TaskCategory category) {
    switch (category) {
      case TaskCategory.study:
        return 'Study';
      case TaskCategory.assignment:
        return 'Assignment';
      case TaskCategory.quiz:
        return 'Quiz';
      case TaskCategory.exam:
        return 'Exam';
      case TaskCategory.project:
        return 'Project';
    }
  }

  String _daysText() {
    if (daysLeft < 0) return 'Overdue';
    if (daysLeft == 0) return 'Today';
    if (daysLeft == 1) return 'Tomorrow';
    return '$daysLeft days left';
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(item.colorValue);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context).copyWith(
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 12,
            height: 84,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
              boxShadow: [BoxShadow(color: color.withOpacity(0.28), blurRadius: 12)],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: GoogleFonts.orbitron(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.subject,
                  style: GoogleFonts.poppins(
                    color: const Color(0xFF00E5FF),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TaskInfoPill(
                      icon: Icons.calendar_today_rounded,
                      label: DateFormat('MMM d, yyyy').format(item.date),
                    ),
                    _TaskCategoryBadge(
                      label: _categoryLabel(item.category),
                      color: color,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.16),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: color.withOpacity(0.28)),
                      ),
                      child: Text(
                        _daysText(),
                        style: GoogleFonts.poppins(
                          color: color,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                if (item.note.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    item.note,
                    style: GoogleFonts.poppins(color: Theme.of(context).hintColor, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') {
                onEdit();
              } else if (value == 'delete') {
                onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

class TimetableEditorSheet extends StatefulWidget {
  final TimetableEntry? existingEntry;
  final int Function(String subject) autoColorForSubject;

  const TimetableEditorSheet({
    super.key,
    required this.existingEntry,
    required this.autoColorForSubject,
  });

  @override
  State<TimetableEditorSheet> createState() => _TimetableEditorSheetState();
}

class _TimetableEditorSheetState extends State<TimetableEditorSheet> {
  late TextEditingController _subjectController;
  late TextEditingController _roomController;
  late String _day;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;

  @override
  void initState() {
    super.initState();
    final entry = widget.existingEntry;
    _subjectController = TextEditingController(text: entry?.subject ?? '');
    _roomController = TextEditingController(text: entry?.room ?? '');
    _day = entry?.day ?? 'Monday';
    _startTime = entry?.startTime ?? const TimeOfDay(hour: 8, minute: 0);
    _endTime = entry?.endTime ?? const TimeOfDay(hour: 9, minute: 0);
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _roomController.dispose();
    super.dispose();
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(context: context, initialTime: _startTime);
    if (picked != null) {
      setState(() {
        _startTime = picked;
      });
    }
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(context: context, initialTime: _endTime);
    if (picked != null) {
      setState(() {
        _endTime = picked;
      });
    }
  }

  void _save() {
    if (_subjectController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Subject is required.')),
      );
      return;
    }

    final entry = TimetableEntry(
      id: widget.existingEntry?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      subject: _subjectController.text.trim(),
      day: _day,
      startTime: _startTime,
      endTime: _endTime,
      room: _roomController.text.trim(),
      colorValue: widget.autoColorForSubject(_subjectController.text.trim()),
    );

    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(18, 18, 18, bottom + 18),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existingEntry == null ? 'Add Class' : 'Edit Class',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _subjectController,
              decoration: const InputDecoration(
                labelText: 'Subject',
                prefixIcon: Icon(Icons.menu_book_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _roomController,
              decoration: const InputDecoration(
                labelText: 'Room / Link (optional)',
                prefixIcon: Icon(Icons.location_on_outlined),
              ),
            ),
            const SizedBox(height: 12),
            PopupMenuButton<String>(
              onSelected: (value) {
                setState(() {
                  _day = value;
                });
              },
              itemBuilder: (context) => ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday']
                  .map((day) => PopupMenuItem(value: day, child: Text(day)))
                  .toList(),
              child: _PickerTile(
                icon: Icons.calendar_view_week_rounded,
                title: 'Day',
                value: _day,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _PickerTile(
                    icon: Icons.schedule_rounded,
                    title: 'Start',
                    value: format12HourTime(_startTime),
                    onTap: _pickStartTime,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PickerTile(
                    icon: Icons.schedule_rounded,
                    title: 'End',
                    value: format12HourTime(_endTime),
                    onTap: _pickEndTime,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_rounded),
              label: Text(widget.existingEntry == null ? 'Create Class' : 'Save Changes'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1C2233)
              : const Color(0xFFF8F9FD),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor:
                  Theme.of(context).colorScheme.primary.withOpacity(0.12),
              child: Icon(icon, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.orbitron(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: GoogleFonts.poppins(
                      color: Theme.of(context).hintColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;

  const _PickerTile({
    required this.icon,
    required this.title,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF1C2233)
            : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF263049)
              : const Color(0xFFE7EBF4),
        ),
      ),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return child;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: child,
    );
  }
}

// ======================================================
// EXAM COUNTDOWN CARD
// ======================================================

class _ExamCountdownCard extends StatefulWidget {
  final DeadlineItem exam;
  final int daysLeft;

  const _ExamCountdownCard({
    required this.exam,
    required this.daysLeft,
  });

  @override
  State<_ExamCountdownCard> createState() => _ExamCountdownCardState();
}

class _ExamCountdownCardState extends State<_ExamCountdownCard> {
  String _getCountdownText() {
    final now = DateTime.now();
    final difference = widget.exam.date.difference(now);

    if (difference.isNegative) {
      return 'Exam Over';
    }

    final days = difference.inDays;
    final hours = difference.inHours % 24;
    final minutes = difference.inMinutes % 60;

    if (days > 0) {
      return '$days days, $hours hours';
    } else if (hours > 0) {
      return '$hours hours, $minutes min';
    } else {
      return '$minutes minutes left';
    }
  }

  Color _getCountdownColor() {
    final now = DateTime.now();
    final difference = widget.exam.date.difference(now);
    final daysLeft = difference.inDays;

    if (daysLeft < 0) return Colors.grey;
    if (daysLeft == 0) return Colors.red;
    if (daysLeft <= 3) return Colors.orange;
    if (daysLeft <= 7) return Colors.amber;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(widget.exam.colorValue);
    final countdownColor = _getCountdownColor();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withOpacity(0.08)
            : Colors.white,
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.1),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [color.withOpacity(0.8), color.withOpacity(0.4)],
                  ),
                ),
                child: Icon(
                  widget.exam.category == TaskCategory.exam
                      ? Icons.school_rounded
                      : Icons.event_note_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.exam.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.exam.subject,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: countdownColor.withOpacity(0.12),
              border: Border.all(
                color: countdownColor.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  color: countdownColor,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _getCountdownText(),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: countdownColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.exam.note.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              widget.exam.note,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AchievementPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _AchievementPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF1C2233)
            : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF263049)
              : const Color(0xFFE7EBF4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );

    if (onTap == null) return chip;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: chip,
    );
  }
}

class _InsightTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _InsightTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor:
              Theme.of(context).colorScheme.primary.withOpacity(0.12),
          child: Icon(icon, color: Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: Theme.of(context).hintColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _SimpleBarChart extends StatelessWidget {
  final List<Map<String, dynamic>> data;
  final String valueKey;
  final String labelKey;
  final String suffix;

  const _SimpleBarChart({
    required this.data,
    required this.valueKey,
    required this.labelKey,
    required this.suffix,
  });

  String _formatChartValue(int value) {
    if (suffix == 'm' && value >= 60) {
      final hours = value ~/ 60;
      return '$hours ${hours == 1 ? 'hr' : 'hrs'}';
    }
    return '$value$suffix';
  }

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const _EmptyCard(
        icon: Icons.bar_chart_outlined,
        title: 'No chart data',
        subtitle: 'Complete tasks to generate analytics.',
      );
    }

    final maxValue = data
        .map((e) => (e[valueKey] as num).toDouble())
        .fold<double>(0, (a, b) => a > b ? a : b);

    final safeMax = maxValue <= 0 ? 1.0 : maxValue;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: data.map((entry) {
        final value = (entry[valueKey] as num).toDouble();
        final label = entry[labelKey].toString();
        final heightFactor = value / safeMax;

        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value.round() == 0 ? '0' : _formatChartValue(value.round()),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).hintColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: heightFactor),
                  duration: const Duration(milliseconds: 700),
                  builder: (context, animatedValue, _) {
                    return Container(
                      height: 120 * animatedValue.clamp(0.0, 1.0),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xFF7C4DFF),
                            const Color(0xFF00E5FF),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00E5FF).withOpacity(0.22),
                            blurRadius: 10,
                            spreadRadius: 0.5,
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}