import 'package:flutter/material.dart';

import 'main_page.dart';

void main() {
  runApp(const AppRoot());
}

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'QR App Installer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed( seedColor: Colors.black ),
        useMaterial3: true,
      ),
      home: const MainPage(title: 'QR App Installer'),

    );
  }
}


