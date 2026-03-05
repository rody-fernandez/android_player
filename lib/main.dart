import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MegaSignagePlayerApp());

class MegaSignagePlayerApp extends StatelessWidget {
  const MegaSignagePlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PairingScreen(),
    );
  }
}

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  String serverUrl = "http://192.168.134.1:3000";

  String playerName = "ANDROID-BOX";
  String pairCode = "----";
  String status = "Iniciando…";

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final prefs = await SharedPreferences.getInstance();

    final savedCode = prefs.getString("pair_code");
    if (savedCode != null && savedCode.isNotEmpty) {
      setState(() => pairCode = savedCode);
    }

    final savedName = prefs.getString("player_name");
    if (savedName != null && savedName.isNotEmpty) {
      playerName = savedName;
    } else {
      await prefs.setString("player_name", playerName);
    }

    await _register(prefs);
  }

  Future<void> _register(SharedPreferences prefs) async {
    try {
      setState(() => status = "Registrando en CMS…");

      final res = await http.post(
        Uri.parse("$serverUrl/api/player/register"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"name": playerName}),
      );

      final j = jsonDecode(res.body);
      final token = (j["token"] ?? "").toString();
      final code = (j["pairing_code"] ?? "").toString();

      if (token.isEmpty || code.isEmpty) {
        setState(() => status = "Respuesta inválida del servidor");
        return;
      }

      await prefs.setString("token", token);
      await prefs.setString("pair_code", code);

      setState(() {
        pairCode = code;
        status = "Esperando vinculación…";
      });
    } catch (e) {
      setState(() => status = "Error de red: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        alignment: Alignment.topLeft, // ✅ 0,0
        children: [
          // overlay arriba-izquierda
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              padding: const EdgeInsets.all(14),
              color: Colors.black.withOpacity(0.65),
              child: Text(
                "$status\n\nServidor:\n$serverUrl\n\nPlayer:\n$playerName",
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),

          // código grande
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "CÓDIGO DE VINCULACIÓN",
                  style: TextStyle(color: Colors.white, fontSize: 22),
                ),
                const SizedBox(height: 14),
                Text(
                  pairCode,
                  style: const TextStyle(
                    color: Color(0xFF00FFCC),
                    fontSize: 84,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
