import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const SkycastApp());
}

class SkycastApp extends StatelessWidget {
  const SkycastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Skycast',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2980B9),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
