import 'package:flutter/material.dart';
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
      Icon(Icons.lock_rounded, size: 64, color: widget.accent), const SizedBox(height: 16),
      Text('Zenith is Locked', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w800, color: cs.onSurface)), const SizedBox(height: 24),
      ElevatedButton.icon(onPressed: () async { await _doBio(); if (mounted) setState(() {}); }, icon: const Icon(Icons.fingerprint_rounded), label: const Text('Unlock'),
        style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))])));
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
    return Scaffold(body: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: Column(children: [
      const SizedBox(height: 40),
      Image.asset('assets/icon.png', width: 100, height: 100),
      Text('ZENITH', style: GoogleFonts.outfit(fontSize: 26, fontWeight: FontWeight.w900, color: cs.onSurface, letterSpacing: 4)),
      const SizedBox(height: 6),
      Text('Smart Budget Tracker', style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.5))),
      const SizedBox(height: 40),
      TextField(onChanged: (v) => setState(() => _name = v), textCapitalization: TextCapitalization.words, style: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w600),
        decoration: InputDecoration(hintText: 'Enter your name', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none), contentPadding: const EdgeInsets.all(18))),
      const SizedBox(height: 16),
      Row(children: [Switch(value: _bio, onChanged: (v) => setState(() => _bio = v), activeColor: widget.accent), const SizedBox(width: 8),
        Expanded(child: Text('Enable fingerprint lock', style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.7)))), Icon(Icons.fingerprint_rounded, color: cs.onSurface.withOpacity(0.3))]),
      const SizedBox(height: 24),
      SizedBox(width: double.infinity, height: 56, child: ElevatedButton(
        onPressed: _name.trim().length >= 2 ? () => widget.onDone(_name.trim(), _bio) : null,
        style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        child: const Text("Let's go!", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))),
      const SizedBox(height: 40)]))));
  }
}