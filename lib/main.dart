import 'dart:math';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_webrtc/flutter_webrtc.dart';



void main() => runApp(const TalkyApp());

class TalkyApp extends StatelessWidget {
  const TalkyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple), useMaterial3: true),
      home: const AuthGate(),
    );
  }
}

/// ---------------- AUTH GATE ----------------
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool isLoading = true, isLoggedIn = false;
  String? displayName, photoUrl;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      isLoggedIn = prefs.getBool('loggedIn') ?? false;
      displayName = prefs.getString('displayName');
      photoUrl = prefs.getString('photoUrl');
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return isLoggedIn
        ? HomeScreen(displayName: displayName ?? "Stranger", photoUrl: photoUrl)
        : LoginScreen(onLoginSuccess: _checkLoginStatus);
  }
}

/// ---------------- LOGIN SCREEN ----------------
class LoginScreen extends StatelessWidget {
  final VoidCallback onLoginSuccess;
  const LoginScreen({super.key, required this.onLoginSuccess});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, colors: [Colors.deepPurple.shade800, Colors.deepPurple.shade400])),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.forum_rounded, size: 100, color: Colors.white),
            const Text("Talky", style: TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold)),
            const SizedBox(height: 50),
            ElevatedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Sign in with Google'),
              onPressed: () => _handleSignIn(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleSignIn(BuildContext context) async {
    try {
      final user = await GoogleSignIn().signIn();
      if (user == null) return;
      final prefs = await SharedPreferences.getInstance();

      final response = await http.post(
        Uri.parse('$API_BASE_URL/user'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'googleId': user.id, 'email': user.email, 'displayName': _generateRandomName()}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        await prefs.setBool('loggedIn', true);
        await prefs.setInt('userId', data['id']);
        await prefs.setString('displayName', data['display_name']);
        await prefs.setString('photoUrl', data['photo_url'] ?? '');
        onLoginSuccess();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Login Failed: $e")));
    }
  }
}

/// ---------------- HOME SCREEN ----------------
class HomeScreen extends StatefulWidget {
  final String displayName;
  final String? photoUrl;

  const HomeScreen({super.key, required this.displayName, this.photoUrl});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late String currentName;
  String? currentPhotoUrl;
  bool isSearching = false;
  final ImagePicker _picker = ImagePicker();

  // Socket instance
  late IO.Socket socket;

  @override
  void initState() {
    super.initState();
    currentName = widget.displayName;
    currentPhotoUrl = widget.photoUrl;
    _initSocket();
  }

  /// ---------------- SOCKET LOGIC ----------------
  void _initSocket() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('userId');

    // Initialize Socket Connection
    socket = IO.io(API_BASE_URL,
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .disableAutoConnect()
            .build()
    );

    socket.connect();

    socket.onConnect((_) {
      debugPrint('Connected to Socket Server');
      if (userId != null) {
        socket.emit('user-online', userId);
      }
    });

    // LISTEN FOR MATCH FROM SERVER
    socket.on('matched', (data) {
      final callId = data['callId'];
      final initiator = data['initiator'];

      setState(() => isSearching = false);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CallPage(
            callId: callId,
            initiator: initiator,
            socket: socket,
          ),
        ),
      );
    });


    socket.onDisconnect((_) => debugPrint('Socket Disconnected'));
  }

  /// ---------------- PROFILE LOGIC ----------------

  Future<String?> _uploadPhoto(File file, int userId) async {
    final request = http.MultipartRequest('POST', Uri.parse('$API_BASE_URL/user/upload-photo'))
      ..fields['userId'] = userId.toString()
      ..files.add(await http.MultipartFile.fromPath('photo', file.path));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    final data = jsonDecode(response.body);
    return data['photoUrl'];
  }

  Future<void> _updateProfile(String newName, File? imageFile) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('userId');
    if (userId == null) return;

    String? updatedUrl = currentPhotoUrl;

    try {
      // 1. Handle Image Upload
      if (imageFile != null) {
        final uploadedLink = await _uploadPhoto(imageFile, userId);
        if (uploadedLink != null) {
          // Clear old cache so the image refreshes instantly
          await PaintingBinding.instance.imageCache.evict(NetworkImage(uploadedLink));
          // Use Cache-Buster for immediate UI update
          updatedUrl = "$uploadedLink?t=${DateTime.now().millisecondsSinceEpoch}";
        }
      }

      // 2. Update Name in Database
      await http.put(
        Uri.parse('$API_BASE_URL/user/profile'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': userId, 'displayName': newName}),
      );

      // 3. Update Local Cache (Save clean URL for next boot)
      await prefs.setString('displayName', newName);
      if (updatedUrl != null) {
        String cleanUrl = updatedUrl.split('?')[0];
        await prefs.setString('photoUrl', cleanUrl);
      }

      setState(() {
        currentName = newName;
        currentPhotoUrl = updatedUrl;
      });
    } catch (e) {
      debugPrint("Update error: $e");
    }
  }

  void _showEditProfile() {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Edit Profile"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () async {
                final picked = await _picker.pickImage(source: ImageSource.gallery);
                if (picked != null) {
                  Navigator.pop(context); // Close and reopen to refresh dialog UI
                  await _updateProfile(currentName, File(picked.path));
                  _showEditProfile();
                }
              },
              child: CircleAvatar(
                radius: 40,
                backgroundColor: Colors.grey[200],
                backgroundImage: (currentPhotoUrl != null && currentPhotoUrl!.isNotEmpty)
                    ? NetworkImage(currentPhotoUrl!) : null,
                child: (currentPhotoUrl == null || currentPhotoUrl!.isEmpty)
                    ? const Icon(Icons.camera_alt) : null,
              ),
            ),
            const SizedBox(height: 20),
            TextField(controller: controller, decoration: const InputDecoration(labelText: "Display Name")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              _updateProfile(controller.text, null);
              Navigator.pop(context);
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }

  /// ---------------- UI BUILD ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Talky'),
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: GestureDetector(
            onTap: _showEditProfile,
            child: CircleAvatar(
              backgroundImage: (currentPhotoUrl != null && currentPhotoUrl!.isNotEmpty)
                  ? NetworkImage(currentPhotoUrl!) : null,
              child: (currentPhotoUrl == null || currentPhotoUrl!.isEmpty)
                  ? const Icon(Icons.person, size: 20) : null,
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.power_settings_new, color: Colors.red),
            onPressed: () async {
              socket.disconnect();
              (await SharedPreferences.getInstance()).clear();
              Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const AuthGate()), (r) => false);
            },
          ),
        ],
      ),
      body: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("Logged in as", style: TextStyle(color: Colors.grey)),
            Text(currentName, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 80),

            if (isSearching) ...[
              const CircularProgressIndicator(strokeWidth: 6),
              const SizedBox(height: 25),
              const Text("Searching for a stranger...", style: TextStyle(fontSize: 16)),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => setState(() => isSearching = false),
                child: const Text("Cancel", style: TextStyle(color: Colors.red)),
              ),
            ] else
              SizedBox(
                width: double.infinity,
                height: 120,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  onPressed: () {
                    setState(() => isSearching = true);
                    socket.emit('find-stranger');
                  },
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bolt, size: 40),
                      Text("Find a Stranger", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    socket.dispose();
    super.dispose();
  }
}

String _generateRandomName() {
  final adj = ['Swift', 'Neon', 'Happy'], noun = ['Panda', 'Echo', 'Pixel'];
  final r = Random();
  return '${adj[r.nextInt(adj.length)]}${noun[r.nextInt(noun.length)]}';
}




class CallPage extends StatefulWidget {
  final String callId;
  final bool initiator;
  final IO.Socket socket;

  const CallPage({
    super.key,
    required this.callId,
    required this.initiator,
    required this.socket,
  });

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  bool _micEnabled = true;

  @override
  void initState() {
    super.initState();
    _setupWebRTC();
  }

  @override
  void dispose() {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _peer?.close();
    widget.socket.emit('leave-call', widget.callId);
    super.dispose();
  }

  // ---------------- WEBRTC SETUP ----------------

  Future<void> _setupWebRTC() async {
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };

    _peer = await createPeerConnection(config);

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false, // AUDIO ONLY (stable)
    });

    for (final track in _localStream!.getTracks()) {
      await _peer!.addTrack(track, _localStream!);
    }

    // ICE candidates → server
    _peer!.onIceCandidate = (candidate) {
      if (candidate != null) {
        widget.socket.emit('signal', {
          'callId': widget.callId,
          'data': {
            'type': 'candidate',
            'candidate': candidate.toMap(),
          }
        });
      }
    };

    // Remote track received
    _peer!.onTrack = (event) {
      // Audio plays automatically; no renderer needed
      debugPrint("Remote track received");
    };

    // Socket signaling listener
    widget.socket.on('signal', (payload) async {
      final data = payload['data'];

      switch (data['type']) {
        case 'offer':
          await _peer!.setRemoteDescription(
            RTCSessionDescription(data['sdp'], 'offer'),
          );
          final answer = await _peer!.createAnswer();
          await _peer!.setLocalDescription(answer);
          widget.socket.emit('signal', {
            'callId': widget.callId,
            'data': {
              'type': 'answer',
              'sdp': answer.sdp,
            }
          });
          break;

        case 'answer':
          await _peer!.setRemoteDescription(
            RTCSessionDescription(data['sdp'], 'answer'),
          );
          break;

        case 'candidate':
          final c = data['candidate'];
          await _peer!.addCandidate(
            RTCIceCandidate(
              c['candidate'],
              c['sdpMid'],
              c['sdpMLineIndex'],
            ),
          );
          break;
      }
    });

    // Initiator creates offer
    if (widget.initiator) {
      final offer = await _peer!.createOffer();
      await _peer!.setLocalDescription(offer);
      widget.socket.emit('signal', {
        'callId': widget.callId,
        'data': {
          'type': 'offer',
          'sdp': offer.sdp,
        }
      });
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Voice Call"),
        backgroundColor: Colors.black,
        automaticallyImplyLeading: false,
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.call, color: Colors.green, size: 80),
          const SizedBox(height: 20),
          const Text(
            "Connected to Stranger",
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 60),

          // CONTROLS
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FloatingActionButton(
                backgroundColor: _micEnabled ? Colors.grey : Colors.red,
                onPressed: _toggleMic,
                child: Icon(_micEnabled ? Icons.mic : Icons.mic_off),
              ),
              FloatingActionButton(
                backgroundColor: Colors.red,
                onPressed: () => Navigator.pop(context),
                child: const Icon(Icons.call_end),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _toggleMic() {
    _micEnabled = !_micEnabled;
    for (var track in _localStream!.getAudioTracks()) {
      track.enabled = _micEnabled;
    }
    setState(() {});
  }
}
