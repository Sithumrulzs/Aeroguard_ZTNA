import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// --- CORE SCREENS & CONFIG ---
import 'screens/home_load_page.dart';
import 'screens/intro_video_screen.dart';
import 'config/environment_config.dart';

void main() async {
  // Ensure the Flutter engine is fully booted before initializing native hardware
  WidgetsFlutterBinding.ensureInitialized();

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

// Decides between the intro video and jumping straight to HomeLoadPage —
// skips the video on a hot resume or when the OS has animations disabled.
class _LaunchGate extends StatelessWidget {
  const _LaunchGate();

  @override
  Widget build(BuildContext context) {
    if (_introShown || MediaQuery.disableAnimationsOf(context)) {
      return const HomeLoadPage();
    }
    _introShown = true;
    return const IntroVideoScreen();
  }
}

class AeroGuardApp extends StatelessWidget {
  const AeroGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AeroGuard ZTNA',
      debugShowCheckedModeBanner: false,

      // --- DEFINING THE GLOBAL AEROGUARD THEME ---
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',

        colorScheme: const ColorScheme(
          brightness: Brightness.dark,
          primary: Color(0xFF00C3FF),
          onPrimary: Colors.black,
          secondary: Colors.orangeAccent,
          onSecondary: Colors.black,
          error: Color(0xFFCF6679),
          onError: Colors.white,
          surface: Color(0xFF1E1E1E),
          onSurface: Colors.white,
        ),

        scaffoldBackgroundColor: const Color(0xFF0A0A0A),

        textTheme: const TextTheme(
          displayLarge: TextStyle(
            fontSize: 28,
            color: Colors.white,
            letterSpacing: 3.0,
            fontWeight: FontWeight.bold,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            color: Colors.white70,
            letterSpacing: 1.5,
          ),
          bodyLarge: TextStyle(
            fontSize: 14,
            color: Colors.white,
            letterSpacing: 0.5,
          ),
          bodyMedium: TextStyle(fontSize: 12, color: Colors.white70),
        ),
      ),

      home: const _LaunchGate(),
    );
  }
}
