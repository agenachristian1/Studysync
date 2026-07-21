// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_finals/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('preserves deadline time when serializing and restoring', () {
    final deadline = DeadlineItem(
      id: 'deadline_1',
      title: 'Final Review',
      subject: 'Math',
      date: DateTime(2026, 7, 16, 16, 30),
      category: TaskCategory.exam,
      note: 'Bring notes',
      colorValue: 0xFF00E5FF,
    );

    final restored = DeadlineItem.fromMap(deadline.toMap());

    expect(restored.date.year, deadline.date.year);
    expect(restored.date.month, deadline.date.month);
    expect(restored.date.day, deadline.date.day);
    expect(restored.date.hour, deadline.date.hour);
    expect(restored.date.minute, deadline.date.minute);
  });

  testWidgets('dashboard supports pull-to-refresh', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardPage(
            settings: AppSettings(
              displayName: 'Student',
              darkMode: false,
              weeklyGoalMinutes: 600,
              notificationsEnabled: true,
              schoolOrCourse: 'CS',
              yearLevel: '12',
            ),
            tasks: const [],
            todayTasks: const [],
            notes: const [],
            completionRate: 0.0,
            completedCount: 0,
            totalCount: 0,
            nextTask: null,
            weeklyGoalMinutes: 600,
            currentWeekMinutes: 0,
            weeklyGoalProgress: 0.0,
            streakCount: 0,
            deadlines: const [],
            nearestDeadline: null,
            subjectSummaries: const {},
            onAddNote: (_) async {},
            onUpdateNote: (_, __) async {},
            onDeleteNote: (_) async {},
            onAddTaskPressed: () {},
            onToggleTaskComplete: (_) async {},
            onEditTask: (_) {},
            onDeleteTask: (_) async {},
            onOpenDeadlinePage: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RefreshIndicator), findsOneWidget);

    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 240));
    await tester.pump();

    expect(find.byType(RefreshIndicator), findsOneWidget);
  });

  testWidgets('shows the daily study quote on the dashboard', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const StudySyncApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();

    expect(find.text('Daily Study Quote'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Tasks'), findsOneWidget);
  });
}
