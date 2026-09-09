import 'package:device_companion/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the companion setup state', (WidgetTester tester) async {
    await tester.pumpWidget(const DeviceCompanionApp());

    expect(find.text('Device Companion'), findsOneWidget);
    expect(find.text('Waiting for desktop'), findsOneWidget);
  });
}
