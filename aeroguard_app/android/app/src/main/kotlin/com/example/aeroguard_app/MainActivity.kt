package com.example.aeroguard_app

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity is required for local_auth's BiometricPrompt fragment
// to attach correctly. FlutterActivity lacks the FragmentManager integration
// needed by BiometricPrompt on API 28+, causing crashes on in-display sensors.
class MainActivity : FlutterFragmentActivity()
