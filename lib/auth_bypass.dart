import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_auth/local_auth.dart';
import 'package:google_fonts/google_fonts.dart';

class SimpleAuthGate extends StatefulWidget {
  final Color accent;
  final Widget Function(String userName) onAuthenticated;
  const SimpleAuthGate({super.key, required this.accent, required this.onAuthenticated});
  @override State<SimpleAuthGate> createState() => _SimpleAuthGateState();
}

class _SimpleAuthGateState extends State<SimpleAuthGate> {
  bool _loading = true, _authenticated = false, _bioInProgress = false;
  String _userName = '';

  @override void initState() { super.initState(); _init(); }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _userName = p.getString('user_name') ?? '';
    if (_userName.isNotEmpty) {
      final bioEnabled = p.getBool('biometric') ?? false;
      if (bioEnabled) {
        await _doBio();
      } else {
        _authenticated = true;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _doBio() async {
    if (_bioInProgress) return;
    _bioInProgress = true;
    try {
      final a = LocalAuthentication();
      final can = await a.canCheckBiometrics || await a.isDeviceSupported();
      if (!can) { _authenticated = true; _bioInProgress = false; return; }
      final ok = await a.authenticate(
        localizedReason: 'Unlock Zenith',
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false, useErrorDialogs: true, sensitiveTransaction: true));
      _authenticated = ok;
    } catch (e) {
      debugPrint('Bio err: $e');
      _authenticated = true;
    }
    _bioInProgress = false;
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return Scaffold(body: Center(child: CircularProgressIndicator(color: widget.accent)));
    if (_userName.isEmpty) return _Welcome(accent: widget.accent, onDone: (n, b) async {
      final p = await SharedPreferences.getInstance(); p.setString('user_name', n); p.setBool('biometric', b);
      _userName = n;
      if (b) { await _doBio(); } else { _authenticated = true; }
      if (mounted) setState(() {});
    });
    if (!_authenticated) return Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text('ZENITH', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: widget.accent, letterSpacing: 3)),
      const SizedBox(height: 6),
      Text('Track Less. Know More.', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.35))),
      const SizedBox(height: 40),
      Icon(Icons.lock_rounded, size: 48, color: cs.onSurface.withOpacity(0.15)),
      const SizedBox(height: 16),
      Text('Locked', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.5))),
      const SizedBox(height: 28),
      ElevatedButton.icon(onPressed: () async { HapticFeedback.lightImpact(); await _doBio(); if (mounted) setState(() {}); }, icon: const Icon(Icons.fingerprint_rounded), label: const Text('Unlock'),
        style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))))])));
    return widget.onAuthenticated(_userName);
  }
}

class _Welcome extends StatefulWidget {
  final Color accent; final Function(String, bool) onDone;
  const _Welcome({required this.accent, required this.onDone});
  @override State<_Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<_Welcome> {
  String _name = ''; bool _bio = false;
  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 32), child: Column(children: [
      const SizedBox(height: 60),
      Text('ZENITH', style: GoogleFonts.outfit(fontSize: 36, fontWeight: FontWeight.w800, color: widget.accent, letterSpacing: 4)),
      const SizedBox(height: 8),
      Text('Track Less. Know More.', style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.4))),
      const SizedBox(height: 56),
      TextField(onChanged: (v) => setState(() => _name = v), textCapitalization: TextCapitalization.words, style: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w600),
        decoration: InputDecoration(hintText: 'Your name', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none), contentPadding: const EdgeInsets.all(20))),
      const SizedBox(height: 16),
      Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Row(children: [Icon(Icons.fingerprint_rounded, color: cs.onSurface.withOpacity(0.4), size: 22), const SizedBox(width: 12),
          Expanded(child: Text('Fingerprint lock', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface))),
          Switch(value: _bio, onChanged: (v) { HapticFeedback.lightImpact(); setState(() => _bio = v); }, activeColor: widget.accent)])),
      const SizedBox(height: 32),
      SizedBox(width: double.infinity, height: 56, child: ElevatedButton(
        onPressed: _name.trim().length >= 2 ? () { HapticFeedback.lightImpact(); widget.onDone(_name.trim(), _bio); } : null,
        style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, disabledBackgroundColor: widget.accent.withOpacity(0.15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        child: Text("Let's go", style: GoogleFonts.outfit(fontWeight: FontWeight.w800, fontSize: 16)))),
      const SizedBox(height: 48),
      Text('Created by Siddharth Ganesh', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.2))),
      const SizedBox(height: 4),
      Text('Built with Flutter & Dart', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.15))),
      const SizedBox(height: 32)]))));
  }
}
