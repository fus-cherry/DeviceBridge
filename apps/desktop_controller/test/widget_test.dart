import 'package:desktop_controller/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the controller setup state', (WidgetTester tester) async {
    await tester.pumpWidget(const DesktopControllerApp());

    expect(find.text('Device Debug Utility'), findsOneWidget);
    expect(find.text('Workspace ready'), findsOneWidget);
  });
}
