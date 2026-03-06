import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

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
  String serverUrl = "http://192.168.134.1:3000";
  String playerName = "ANDROID-BOX";

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
  int currentIndex = 0;

  VideoPlayerController? _videoController;
  bool _showImage = false;
  String _imageUrl = "";

  @override
  void initState() {
    super.initState();
    boot();
  }

  @override
  void dispose() {
    heartbeatTimer?.cancel();
    configTimer?.cancel();
    _videoController?.dispose();
    super.dispose();
  }

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
        setState(() {
          lastError = "Heartbeat error: $e";
        });
      }
    });
  }

  void startConfigPolling() {
    configTimer?.cancel();

    configTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
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
      final newItems = data["items"] is List ? data["items"] as List : [];

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
      setState(() {
        lastError = "Config error: $e";
      });
    }
  }

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

  Future<void> playCurrentItem() async {
    if (items.isEmpty) return;

    final item = items[currentIndex];
    final url = absoluteUrl((item["url"] ?? "").toString());

    if (isImageFile(url)) {
      await _videoController?.dispose();
      _videoController = null;

      setState(() {
        _showImage = true;
        _imageUrl = url;
      });

      Future.delayed(const Duration(seconds: 8), () async {
        if (!mounted || items.isEmpty) return;
        currentIndex = (currentIndex + 1) % items.length;
        await playCurrentItem();
      });
      return;
    }

    if (isVideoFile(url)) {
      await _videoController?.dispose();
      _videoController = VideoPlayerController.networkUrl(Uri.parse(url));

      try {
        await _videoController!.initialize();
        await _videoController!.setLooping(false);
        await _videoController!.play();

        _videoController!.addListener(() async {
          if (!mounted || _videoController == null) return;
          final controller = _videoController!;
          if (controller.value.isInitialized &&
              !controller.value.isPlaying &&
              controller.value.position >= controller.value.duration) {
            controller.removeListener(() {});
            currentIndex = (currentIndex + 1) % items.length;
            await playCurrentItem();
          }
        });

        setState(() {
          _showImage = false;
        });
      } catch (e) {
        setState(() {
          lastError = "Video error: $e";
        });
      }
      return;
    }

    setState(() {
      lastError = "Formato no soportado: $url";
    });
  }

  Future<void> resetPlayer() async {
    heartbeatTimer?.cancel();
    configTimer?.cancel();
    await _videoController?.dispose();
    _videoController = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("token");
    await prefs.remove("pair_code");

    setState(() {
      token = "";
      pairCode = "----";
      paired = false;
      screenName = "-";
      playlistName = "-";
      items = [];
      status = "Reiniciando...";
      lastError = "";
      _showImage = false;
      _imageUrl = "";
      currentIndex = 0;
    });

    await registerPlayer();
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (paired && items.isNotEmpty) {
      if (_showImage && _imageUrl.isNotEmpty) {
        content = Positioned.fill(
          child: Image.network(
            _imageUrl,
            fit: BoxFit.contain,
            alignment: Alignment.topLeft,
            errorBuilder: (_, __, ___) => const Center(
              child: Text(
                "Error cargando imagen",
                style: TextStyle(color: Colors.red),
              ),
            ),
          ),
        );
      } else if (_videoController != null &&
          _videoController!.value.isInitialized) {
        content = Positioned.fill(
          child: FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: _videoController!.value.size.width,
              height: _videoController!.value.size.height,
              child: VideoPlayer(_videoController!),
            ),
          ),
        );
      } else {
        content = const Center(
          child: Text(
            "Cargando contenido...",
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
