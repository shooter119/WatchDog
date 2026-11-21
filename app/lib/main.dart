import 'package:flutter/material.dart';

import 'app/app_bootstrap.dart';
import 'app/shell/command_app_shell.dart';
import 'services/audio_service.dart';
import 'services/local_asr_service.dart';
import 'state/app_controller.dart';

void main() {
  AppBootstrap.run(appBuilder: () => const WatchDogApp());
}

/// 应用根组件：默认并唯一挂载 Design System v3.0 [CommandAppShell]。
class WatchDogApp extends StatefulWidget {
  const WatchDogApp({
    super.key,
    this.controller,
    this.chatAudioService,
  });

  final AppController? controller;
  final AudioService? chatAudioService;

  @override
  State<WatchDogApp> createState() => _WatchDogAppState();
}

class _WatchDogAppState extends State<WatchDogApp> {
  late AppController _controller;
  late bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ?? AppController(localAsr: LocalAsrService());
  }

  @override
  void didUpdateWidget(covariant WatchDogApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (_ownsController) {
        _controller.dispose();
      }
      _ownsController = widget.controller == null;
      _controller =
          widget.controller ?? AppController(localAsr: LocalAsrService());
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CommandAppShell(
      controller: _controller,
      chatAudioService: widget.chatAudioService,
      disposeController: false,
    );
  }
}
