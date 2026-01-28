import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

// Assuming config.dart contains: const String API_BASE_URL = 'http://your-ip:3000';
import 'config.dart';

void main() => runApp(const TalkyApp());

class TalkyApp extends StatelessWidget {
  const TalkyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Talky',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
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
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            colors: [Colors.deepPurple.shade800, Colors.deepPurple.shade400],
          ),
        ),
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
  late IO.Socket socket;

  @override
  void initState() {
    super.initState();
    currentName = widget.displayName;
    currentPhotoUrl = widget.photoUrl;
    _initSocket();
  }

  void _initSocket() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('userId');

    socket = IO.io(API_BASE_URL,
        IO.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build());

    socket.connect();
    socket.onConnect((_) {
      if (userId != null) socket.emit('user-online', userId);
    });

    socket.on('matched', (data) {
      if (!mounted) return;
      setState(() => isSearching = false);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CallScreen(
            callId: data['callId'],
            isInitiator: data['initiator'],
            socket: socket,
          ),
        ),
      );
    });
  }

  Future<String?> _uploadPhoto(File file, int userId) async {
    final request = http.MultipartRequest('POST', Uri.parse('$API_BASE_URL/user/upload-photo'))
      ..fields['userId'] = userId.toString()
      ..files.add(await http.MultipartFile.fromPath('photo', file.path));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    return jsonDecode(response.body)['photoUrl'];
  }

  Future<void> _updateProfile(String newName, File? imageFile) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('userId');
    if (userId == null) return;
    String? updatedUrl = currentPhotoUrl;

    try {
      if (imageFile != null) {
        final uploadedLink = await _uploadPhoto(imageFile, userId);
        if (uploadedLink != null) {
          await PaintingBinding.instance.imageCache.evict(NetworkImage(uploadedLink));
          updatedUrl = "$uploadedLink?t=${DateTime.now().millisecondsSinceEpoch}";
        }
      }
      await http.put(Uri.parse('$API_BASE_URL/user/profile'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'userId': userId, 'displayName': newName}));
      await prefs.setString('displayName', newName);
      if (updatedUrl != null) await prefs.setString('photoUrl', updatedUrl.split('?')[0]);
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
                  Navigator.pop(context);
                  await _updateProfile(currentName, File(picked.path));
                  _showEditProfile();
                }
              },
              child: CircleAvatar(
                radius: 40,
                backgroundImage: (currentPhotoUrl != null && currentPhotoUrl!.isNotEmpty)
                    ? NetworkImage(currentPhotoUrl!) : null,
                child: (currentPhotoUrl == null || currentPhotoUrl!.isEmpty) ? const Icon(Icons.camera_alt) : null,
              ),
            ),
            const SizedBox(height: 20),
            TextField(controller: controller, decoration: const InputDecoration(labelText: "Name")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(onPressed: () { _updateProfile(controller.text, null); Navigator.pop(context); }, child: const Text("Save")),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Talky'),
        leading: IconButton(
          onPressed: _showEditProfile,
          icon: CircleAvatar(
            radius: 15,
            backgroundImage: (currentPhotoUrl != null && currentPhotoUrl!.isNotEmpty) ? NetworkImage(currentPhotoUrl!) : null,
            child: (currentPhotoUrl == null || currentPhotoUrl!.isEmpty) ? const Icon(Icons.person, size: 18) : null,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.power_settings_new, color: Colors.red),
            onPressed: () async {
              socket.disconnect();
              (await SharedPreferences.getInstance()).clear();
              Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AuthGate()), (r) => false);
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text("Logged in as", style: TextStyle(color: Colors.grey[600])),
            Text(currentName, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 80),
            if (isSearching) ...[
              const CircularProgressIndicator(strokeWidth: 6),
              const SizedBox(height: 20),
              const Text("Looking for a match..."),
              TextButton(onPressed: () => setState(() => isSearching = false), child: const Text("Cancel", style: TextStyle(color: Colors.red))),
            ] else
              SizedBox(
                width: 250, height: 120,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                  onPressed: () {
                    setState(() => isSearching = true);
                    socket.emit('find-stranger');
                  },
                  child: const Text("Find a Stranger", style: TextStyle(fontSize: 20)),
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

/// ---------------- CALL SCREEN (WebRTC) ----------------
class CallScreen extends StatefulWidget {
  final String callId;
  final bool isInitiator;
  final IO.Socket socket;

  const CallScreen({super.key, required this.callId, required this.isInitiator, required this.socket});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  final _remoteRenderer = RTCVideoRenderer();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _remoteRenderer.initialize();
    await Permission.microphone.request();
    await _createPeerConnection();
    _registerSocketEvents();
    if (widget.isInitiator) await _createOffer();
  }

  Future<void> _createPeerConnection() async {
    _peer = await createPeerConnection({'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}]});
    _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    _localStream!.getTracks().forEach((track) => _peer!.addTrack(track, _localStream!));

    _peer!.onIceCandidate = (candidate) {
      widget.socket.emit('signal', {'callId': widget.callId, 'data': {'type': 'ice', 'candidate': candidate.toMap()}});
    };
    _peer!.onTrack = (event) => _remoteRenderer.srcObject = event.streams.first;
  }

  void _registerSocketEvents() {
    widget.socket.on('signal', (payload) async {
      final data = payload['data'];
      if (data['type'] == 'offer') {
        await _peer!.setRemoteDescription(RTCSessionDescription(data['sdp'], 'offer'));
        await _createAnswer();
      } else if (data['type'] == 'answer') {
        await _peer!.setRemoteDescription(RTCSessionDescription(data['sdp'], 'answer'));
      } else if (data['type'] == 'ice') {
        await _peer!.addCandidate(RTCIceCandidate(data['candidate']['candidate'], data['candidate']['sdpMid'], data['candidate']['sdpMLineIndex']));
      }
    });
    widget.socket.on('call-ended', (_) => _endCall(local: false));
  }

  Future<void> _createOffer() async {
    final offer = await _peer!.createOffer();
    await _peer!.setLocalDescription(offer);
    widget.socket.emit('signal', {'callId': widget.callId, 'data': {'type': 'offer', 'sdp': offer.sdp}});
  }

  Future<void> _createAnswer() async {
    final answer = await _peer!.createAnswer();
    await _peer!.setLocalDescription(answer);
    widget.socket.emit('signal', {'callId': widget.callId, 'data': {'type': 'answer', 'sdp': answer.sdp}});
  }

  void _endCall({bool local = true}) {
    if (local) widget.socket.emit('leave-call', widget.callId);
    _peer?.close();
    _localStream?.dispose();
    _remoteRenderer.dispose();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black87,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person, size: 100, color: Colors.white24),
            const SizedBox(height: 20),
            const Text("In Call with Stranger", style: TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 50),
            FloatingActionButton(onPressed: _endCall, backgroundColor: Colors.red, child: const Icon(Icons.call_end)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.socket.off('signal');
    widget.socket.off('call-ended');
    super.dispose();
  }
}

String _generateRandomName() {
  final adj = ['Swift', 'Neon', 'Happy'], noun = ['Panda', 'Echo', 'Pixel'];
  final r = Random();
  return '${adj[r.nextInt(adj.length)]}${noun[r.nextInt(noun.length)]}';
}