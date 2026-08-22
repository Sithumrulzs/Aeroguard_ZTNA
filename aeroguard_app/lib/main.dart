import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// --- CORE SCREENS & CONFIG ---
import 'screens/intro_video_screen.dart';
import 'config/environment_config.dart';
import 'config/theme.dart';
import 'services/theme_controller.dart';

void main() async {
  // Ensure the Flutter engine is fully booted before initializing native hardware
  WidgetsFlutterBinding.ensureInitialized();

  // Load the persisted light/dark preference before the first frame, so
  // the app never flashes light-then-dark (or vice versa) on a cold start.
  await ThemeController.instance.load();

  // Print active gateway config to debug console on every launch
  EnvironmentConfig.printActive();

  // Lock the app in portrait mode for a consistent, terminal-like dashboard experience
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Make the top OS status bar transparent for a cinematic edge-to-edge look
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // --- INITIALIZE HARDWARE & SECURITY SERVICES ---
  // (Uncomment these once your Python backend is ready to receive data)
  // await EnclaveService.initializeDevice("system_init");
  // await NotificationService.initialize();

  runApp(const AeroGuardApp());
}

// True only until the intro video has been shown once. A real cold start
// resets this (fresh process); backgrounding and resuming the app (a "hot
// resume") keeps the process alive, so the flag stays flipped and the video
// never replays.
bool _introShown = false;

// Decides between the intro video and resolving the auth destination
// directly — skips the video on a hot resume or when the OS has animations
// disabled, in both cases with no loading animation of its own (the video
// is the only one in the app now).
class _LaunchGate extends StatelessWidget {
  const _LaunchGate();

  @override
  Widget build(BuildContext context) {
    if (_introShown || MediaQuery.disableAnimationsOf(context)) {
      return const _DirectBoot();
    }
    _introShown = true;
    return const IntroVideoScreen();
  }
}

// Skips the intro video (hot resume / reduce motion) and lands on the
// resolved auth screen with no animation of its own — just the shared
// background color while the (normally near-instant, local-storage-only)
// resolution completes.
class _DirectBoot extends StatelessWidget {
  const _DirectBoot();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: IntroVideoScreen.resolveDestination(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(backgroundColor: kBootBackgroundColor);
        }
        return snapshot.data!;
      },
    );
  }
}

class AeroGuardApp extends StatelessWidget {
  const AeroGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuilds on every toggle. The `key: ValueKey(isDark)` below matters —
    // AppColors.* are plain static getters, not an InheritedWidget, so
    // nothing automatically propagates a "theme changed" notification down
    // into whatever screen is currently on top of the Navigator stack.
    // Changing MaterialApp's key forces Flutter to tear down and rebuild
    // the entire tree from scratch instead of reconciling it, which is the
    // only way to guarantee every already-mounted screen re-reads the new
    // colors. The toggle itself lives on BiometricAuthScreen, right near
    // the start of navigation, so losing in-flight state on deeper screens
    // essentially never happens in practice.
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeController.instance.isDark,
      builder: (context, isDark, _) {
        return MaterialApp(
          key: ValueKey(isDark),
          title: 'AeroGuard ZTNA',
          debugShowCheckedModeBanner: false,

          // --- DEFINING THE GLOBAL AEROGUARD THEME ---
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'Roboto',
            scaffoldBackgroundColor: AppColors.surfaceMuted,
            colorScheme: ColorScheme(
              brightness: isDark ? Brightness.dark : Brightness.light,
              primary: AppColors.brandBlue,
              onPrimary: Colors.white,
              secondary: Colors.orangeAccent,
              onSecondary: Colors.white,
              error: AppColors.danger,
              onError: Colors.white,
              surface: AppColors.surface,
              onSurface: AppColors.inkPrimary,
            ),
          ),

          home: const _LaunchGate(),
        );
      },
    );
  }
}
