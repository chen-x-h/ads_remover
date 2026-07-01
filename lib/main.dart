import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ui/home_page.dart';
import 'ui/processing_state.dart';
import 'db/database.dart';

/// Disables semantics at the binding level to suppress
/// Flutter Windows engine AXTree errors ("will not be in the tree").
class _NoSemanticsBinding extends WidgetsFlutterBinding {
  @override
  bool get semanticsEnabled => false;
}

void main() async {
  _NoSemanticsBinding();
  await DatabaseHelper.instance.init();
  runApp(const AdsRemoverApp());
}

class AdsRemoverApp extends StatelessWidget {
  const AdsRemoverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ProcessingState(),
      child: MaterialApp(
        title: 'Ads Remover',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.blue,
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}
