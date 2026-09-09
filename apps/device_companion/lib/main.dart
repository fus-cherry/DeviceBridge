import 'package:flutter/material.dart';

void main() {
  runApp(const DeviceCompanionApp());
}

class DeviceCompanionApp extends StatelessWidget {
  const DeviceCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Device Companion',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
        useMaterial3: true,
      ),
      home: const _CompanionSetupScreen(),
    );
  }
}

class _CompanionSetupScreen extends StatelessWidget {
  const _CompanionSetupScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device Companion')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: const Card(
            margin: EdgeInsets.all(24),
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.phonelink_ring, size: 56),
                  SizedBox(height: 20),
                  Text(
                    'Waiting for desktop',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Clipboard, file access, and wireless keep-alive are not active yet.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
