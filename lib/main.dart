import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

void main() {
  runApp(const MegaSignagePlayerApp());
}

class MegaSignagePlayerApp extends StatelessWidget {
  const MegaSignagePlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PlayerScreen(),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // =========================
  // CONFIG
  // =========================
  String serverUrl = "http://192.168.134.1:3000";
  String playerName = "ANDROID-BOX";

  // =========================
  // ESTADO GENERAL
  // =========================
  String token = "";
  String pairCode = "----";
  String status = "Iniciando...";
  String lastError = "";

  bool paired = false;
  String screenName = "-";
  String playlistName = "-";
  List<dynamic> items = [];

  Timer? heartbeatTimer;
  Timer? configTimer;
  Timer? imageTimer;
  Timer? playbackWatchdogTimer;

  int currentIndex = 0;

  // =========================
  // VLC / MEDIA
  // =========================
  VlcPlayerController? vlcController;
  bool showingImage = false;
  String currentImageUrl = "";
  bool loadingContent = false;
  int vlcWidgetVersion = 0; // fuerza recreación del widget VLC

  @override
  void initState() {
    super.initState();
    boot();
  }

  @override
  void dispose() {
    heartbeatTimer?.cancel();
    configTimer?.cancel();
    imageTimer?.cancel();
    playbackWatchdogTimer?.cancel();
    safeDisposeVlc();
    super.dispose();
  }

  // =========================
  // INICIO
  // =========================
  Future<void> boot() async {
    final prefs = await SharedPreferences.getInstance();

    final savedToken = prefs.getString("token") ?? "";
    final savedPairCode = prefs.getString("pair_code") ?? "";
    final savedPlayerName = prefs.getString("player_name") ?? "";

    if (savedPlayerName.isNotEmpty) {
      playerName = savedPlayerName;
    } else {
      await prefs.setString("player_name", playerName);
    }

    if (savedToken.isNotEmpty && savedPairCode.isNotEmpty) {
      token = savedToken;
      pairCode = savedPairCode;

      setState(() {
        status = "Reconectando...";
      });

      startHeartbeat();
      startConfigPolling();
      await fetchConfig();
      return;
    }

    await registerPlayer();
  }

  Future<void> registerPlayer() async {
    try {
      setState(() {
        status = "Registrando en CMS...";
        lastError = "";
      });

      final res = await http
          .post(
            Uri.parse("$serverUrl/api/player/register"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"name": playerName}),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode < 200 || res.statusCode >= 300) {
        setState(() {
          status = "Error HTTP ${res.statusCode}";
          lastError = res.body;
        });
        return;
      }

      final data = jsonDecode(res.body);

      token = (data["token"] ?? "").toString();
      pairCode = (data["pairing_code"] ?? "").toString();

      if (token.isEmpty || pairCode.isEmpty) {
        setState(() {
          status = "Respuesta inválida del servidor";
          lastError = res.body;
        });
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("token", token);
      await prefs.setString("pair_code", pairCode);
      await prefs.setString("player_name", playerName);

      setState(() {
        status = "Esperando vinculación...";
      });

      startHeartbeat();
      startConfigPolling();
      await fetchConfig();
    } catch (e) {
      setState(() {
        status = "Error de red";
        lastError = e.toString();
      });
    }
  }

  // =========================
  // HEARTBEAT
  // =========================
  void startHeartbeat() {
    heartbeatTimer?.cancel();

    heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (token.isEmpty) return;

      try {
        await http.post(
          Uri.parse("$serverUrl/api/player/heartbeat"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"token": token}),
        );
      } catch (e) {
        if (!mounted) return;
        setState(() {
          lastError = "Heartbeat error: $e";
        });
      }
    });
  }

  // =========================
  // CONFIG POLLING
  // =========================
  void startConfigPolling() {
    configTimer?.cancel();

    configTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      await fetchConfig();
    });
  }

  Future<void> fetchConfig() async {
    if (token.isEmpty) return;

    try {
      final res = await http
          .get(Uri.parse("$serverUrl/api/player/config?token=$token"))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode < 200 || res.statusCode >= 300) {
        setState(() {
          status = "Config HTTP ${res.statusCode}";
          lastError = res.body;
        });
        return;
      }

      final data = jsonDecode(res.body);
      final bool isPaired = data["paired"] == true;

      if (!isPaired) {
        setState(() {
          paired = false;
          screenName = "-";
          playlistName = "-";
          items = [];
          status = "Esperando vinculación...";
        });
        return;
      }

      final playlist = data["playlist"];
      final List<dynamic> newItems = data["items"] is List
          ? List<dynamic>.from(data["items"])
          : [];

      final changed = jsonEncode(items) != jsonEncode(newItems);

      setState(() {
        paired = true;
        screenName = (data["screen"] ?? "-").toString();
        playlistName = playlist != null
            ? (playlist["name"] ?? "-").toString()
            : "-";
        items = newItems;
        status = "Vinculado";
        lastError = "";
      });

      if (changed && items.isNotEmpty) {
        currentIndex = 0;
        await playCurrentItem();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        lastError = "Config error: $e";
      });
    }
  }

  // =========================
  // HELPERS
  // =========================
  String absoluteUrl(String url) {
    if (url.startsWith("http://") || url.startsWith("https://")) return url;
    return "$serverUrl$url";
  }

  bool isImageFile(String url) {
    final u = url.toLowerCase();
    return u.endsWith(".jpg") ||
        u.endsWith(".jpeg") ||
        u.endsWith(".png") ||
        u.endsWith(".webp");
  }

  bool isVideoFile(String url) {
    final u = url.toLowerCase();
    return u.endsWith(".mp4") ||
        u.endsWith(".webm") ||
        u.endsWith(".mov") ||
        u.endsWith(".m4v");
  }

  Future<void> safeDisposeVlc() async {
    final old = vlcController;
    vlcController = null;

    if (old != null) {
      try {
        await old.stop();
      } catch (_) {}

      try {
        await old.dispose();
      } catch (_) {}
    }
  }

  // =========================
  // REPRODUCCIÓN
  // =========================
  Future<void> playCurrentItem() async {
    if (items.isEmpty) return;

    imageTimer?.cancel();
    playbackWatchdogTimer?.cancel();

    final item = items[currentIndex];
    final url = absoluteUrl((item["url"] ?? "").toString());

    if (!mounted) return;
    setState(() {
      loadingContent = true;
      lastError = "";
    });

    if (isImageFile(url)) {
      await safeDisposeVlc();

      if (!mounted) return;
      setState(() {
        showingImage = true;
        currentImageUrl = url;
        loadingContent = false;
      });

      imageTimer = Timer(const Duration(seconds: 8), () async {
        if (!mounted || items.isEmpty) return;
        currentIndex = (currentIndex + 1) % items.length;
        await playCurrentItem();
      });
      return;
    }

    if (isVideoFile(url)) {
      try {
        await safeDisposeVlc();

        // importante: primero vaciar UI de video anterior
        if (!mounted) return;
        setState(() {
          showingImage = false;
          currentImageUrl = "";
          loadingContent = true;
          vlcWidgetVersion++;
        });

        // pequeña pausa para que Flutter destruya el widget anterior
        await Future.delayed(const Duration(milliseconds: 250));

        final controller = VlcPlayerController.network(
          url,
          autoPlay: true,
          hwAcc: HwAcc.auto,
          options: VlcPlayerOptions(),
        );

        vlcController = controller;

        if (!mounted) return;
        setState(() {
          loadingContent = false;
        });

        playbackWatchdogTimer = Timer.periodic(const Duration(seconds: 1), (
          timer,
        ) async {
          if (!mounted) {
            timer.cancel();
            return;
          }

          final c = vlcController;
          if (c == null) {
            timer.cancel();
            return;
          }

          final value = c.value;

          if (!paired || items.isEmpty) {
            timer.cancel();
            return;
          }

          if (value.hasError) {
            timer.cancel();
            setState(() {
              lastError = "VLC error: ${value.errorDescription}";
            });

            Future.delayed(const Duration(seconds: 2), () async {
              if (!mounted || items.isEmpty) return;
              currentIndex = (currentIndex + 1) % items.length;
              await playCurrentItem();
            });
            return;
          }

          if (value.isEnded == true) {
            timer.cancel();
            currentIndex = (currentIndex + 1) % items.length;
            await playCurrentItem();
          }
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          loadingContent = false;
          lastError = "No se pudo iniciar video: $e";
        });

        Future.delayed(const Duration(seconds: 2), () async {
          if (!mounted || items.isEmpty) return;
          currentIndex = (currentIndex + 1) % items.length;
          await playCurrentItem();
        });
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      loadingContent = false;
      lastError = "Formato no soportado: $url";
    });

    Future.delayed(const Duration(seconds: 2), () async {
      if (!mounted || items.isEmpty) return;
      currentIndex = (currentIndex + 1) % items.length;
      await playCurrentItem();
    });
  }

  // =========================
  // RESET PLAYER
  // =========================
  Future<void> resetPlayer() async {
    heartbeatTimer?.cancel();
    configTimer?.cancel();
    imageTimer?.cancel();
    playbackWatchdogTimer?.cancel();
    await safeDisposeVlc();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("token");
    await prefs.remove("pair_code");

    if (!mounted) return;
    setState(() {
      token = "";
      pairCode = "----";
      paired = false;
      screenName = "-";
      playlistName = "-";
      items = [];
      status = "Reiniciando...";
      lastError = "";
      showingImage = false;
      currentImageUrl = "";
      currentIndex = 0;
      loadingContent = false;
      vlcWidgetVersion++;
    });

    await registerPlayer();
  }

  // =========================
  // UI
  // =========================
  @override
  Widget build(BuildContext context) {
    Widget content;

    if (paired && items.isNotEmpty) {
      if (loadingContent) {
        content = const Center(
          child: Text(
            "Cargando contenido...",
            style: TextStyle(color: Colors.white, fontSize: 24),
          ),
        );
      } else if (showingImage && currentImageUrl.isNotEmpty) {
        content = Positioned.fill(
          child: Image.network(
            currentImageUrl,
            fit: BoxFit.contain,
            alignment: Alignment.topLeft,
            errorBuilder: (_, __, ___) => const Center(
              child: Text(
                "Error cargando imagen",
                style: TextStyle(color: Colors.red, fontSize: 22),
              ),
            ),
          ),
        );
      } else if (vlcController != null) {
        content = Positioned.fill(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: double.infinity,
              height: double.infinity,
              child: VlcPlayer(
                key: ValueKey("vlc_$vlcWidgetVersion"),
                controller: vlcController!,
                aspectRatio: 9 / 16,
                placeholder: const Center(child: CircularProgressIndicator()),
              ),
            ),
          ),
        );
      } else {
        content = const Center(
          child: Text(
            "Sin contenido cargado",
            style: TextStyle(color: Colors.white, fontSize: 24),
          ),
        );
      }
    } else if (paired) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "PLAYER VINCULADO",
              style: TextStyle(color: Colors.white, fontSize: 28),
            ),
            const SizedBox(height: 20),
            Text(
              screenName,
              style: const TextStyle(
                color: Color(0xFF00FF99),
                fontSize: 96,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              playlistName,
              style: const TextStyle(color: Colors.white, fontSize: 22),
            ),
            const SizedBox(height: 12),
            const Text(
              "Sin items en playlist",
              style: TextStyle(color: Colors.white70, fontSize: 18),
            ),
          ],
        ),
      );
    } else {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "CÓDIGO DE VINCULACIÓN",
              style: TextStyle(color: Colors.white, fontSize: 28),
            ),
            const SizedBox(height: 20),
            Text(
              pairCode,
              style: const TextStyle(
                color: Color(0xFF00FF99),
                fontSize: 96,
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          content,
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(14),
              color: Colors.black.withOpacity(0.70),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Servidor:\n$serverUrl",
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Player:\n$playerName",
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Estado:\n$status",
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  if (paired) ...[
                    const SizedBox(height: 8),
                    Text(
                      "Pantalla:\n$screenName",
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Playlist:\n$playlistName",
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Items:\n${items.length}",
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Índice actual:\n$currentIndex",
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                  if (lastError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      "Detalle:\n$lastError",
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: resetPlayer,
                    child: const Text("Regenerar código"),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
