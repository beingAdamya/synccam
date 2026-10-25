import 'dart:async';

import 'package:flutter/widgets.dart';

/// Rebuilds only its own subtree on a timer (REC clocks, countdowns), so a
/// running timer never rebuilds a whole screen of live views.
class Every extends StatefulWidget {
  const Every(this.period, {super.key, required this.builder});
  final Duration period;
  final WidgetBuilder builder;

  @override
  State<Every> createState() => _EveryState();
}

class _EveryState extends State<Every> {
  late final Timer _t = Timer.periodic(widget.period, (_) => setState(() {}));

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
