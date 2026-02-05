import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_webrtc/flutter_webrtc.dart';

// Ensure config.dart has: const String API_BASE_URL = 'http://your-ip:3000';
import 'config.dart';

void main() => runApp(const TalkyApp());

class TalkyApp extends StatelessWidget {
  const TalkyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.light),
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
            const SizedBox(height: 10),
            const Text("Talky", style: TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.bold)),
            const Text("Voice chat with strangers anonymously", style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 60),
            ElevatedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Sign in with Google'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(220, 50)),
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

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late String currentName;
  String? currentPhotoUrl;
  bool isSearching = false;
  final ImagePicker _picker = ImagePicker();
  late IO.Socket socket;
  late AnimationController _pulseController;

  // Reputation stats
  double avgRating = 0;
  int totalReviews = 0;
  int totalReports = 0;
  bool isLoadingStats = true;

  @override
  void initState() {
    super.initState();
    currentName = widget.displayName;
    currentPhotoUrl = widget.photoUrl;
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _initSocket();
    _loadUserStats();
  }

  Future<void> _loadUserStats() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('userId');

    if (userId == null) return;

    try {
      final res = await http.get(Uri.parse('$API_BASE_URL/user/$userId/stats'));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);

        setState(() {
          avgRating = (data['averageRating'] ?? 0).toDouble();
          totalReviews = data['totalReviews'] ?? 0;
          totalReports = data['totalReports'] ?? 0;
          isLoadingStats = false;
        });
      }
    } catch (e) {
      debugPrint("Error loading stats: $e");
      setState(() => isLoadingStats = false);
    }
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
          builder: (_) => CallPage(
            callId: data['callId'],
            initiator: data['initiator'],
            socket: socket,
            peerId: data['peerId'],
          ),
        ),
      ).then((_) {
        // Refresh stats after call
        _loadUserStats();
      });
    });
  }

  Future<void> _updateProfile(String newName, File? imageFile) async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('userId');
    if (userId == null) return;
    String? updatedUrl = currentPhotoUrl;

    try {
      if (imageFile != null) {
        final request = http.MultipartRequest('POST', Uri.parse('$API_BASE_URL/user/upload-photo'))
          ..fields['userId'] = userId.toString()
          ..files.add(await http.MultipartFile.fromPath('photo', imageFile.path));

        final streamedResponse = await request.send();
        final response = await http.Response.fromStream(streamedResponse);
        final data = jsonDecode(response.body);
        updatedUrl = data['photoUrl'];
        await PaintingBinding.instance.imageCache.evict(NetworkImage(updatedUrl!));
        updatedUrl = "$updatedUrl?t=${DateTime.now().millisecondsSinceEpoch}";
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
            TextField(controller: controller, decoration: const InputDecoration(labelText: "Display Name")),
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
        title: const Text("Talky", style: TextStyle(fontWeight: FontWeight.bold)),
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: GestureDetector(
            onTap: _showEditProfile,
            child: CircleAvatar(
              backgroundImage: (currentPhotoUrl != null && currentPhotoUrl!.isNotEmpty)
                  ? NetworkImage(currentPhotoUrl!) : null,
              child: (currentPhotoUrl == null || currentPhotoUrl!.isEmpty) ? const Icon(Icons.person, size: 20) : null,
            ),
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
            Text("Welcome back,", style: TextStyle(color: Colors.grey[600], fontSize: 16)),
            Text(currentName, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),

            const SizedBox(height: 30),

            // Reputation Stats Card
            if (!isLoadingStats)
              Container(
                padding: const EdgeInsets.all(20),
                margin: const EdgeInsets.symmetric(horizontal: 32),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.deepPurple.withOpacity(0.1), Colors.deepPurple.withOpacity(0.05)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.deepPurple.withOpacity(0.3), width: 1),
                ),
                child: Column(
                  children: [
                    const Text(
                      "Your Reputation",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildStatColumn(
                          icon: Icons.star,
                          iconColor: Colors.amber,
                          value: avgRating > 0 ? avgRating.toStringAsFixed(1) : "N/A",
                          label: "Avg Rating",
                        ),
                        Container(
                          height: 50,
                          width: 1,
                          color: Colors.grey[300],
                        ),
                        _buildStatColumn(
                          icon: Icons.reviews,
                          iconColor: Colors.blue,
                          value: "$totalReviews",
                          label: "Reviews",
                        ),
                        Container(
                          height: 50,
                          width: 1,
                          color: Colors.grey[300],
                        ),
                        _buildStatColumn(
                          icon: Icons.report,
                          iconColor: Colors.red,
                          value: "$totalReports",
                          label: "Reports",
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              const CircularProgressIndicator(),

            const SizedBox(height: 40),

            if (isSearching) ...[
              ScaleTransition(
                scale: Tween(begin: 1.0, end: 1.2).animate(_pulseController),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.deepPurple.withOpacity(0.1)),
                  child: const CircularProgressIndicator(strokeWidth: 8),
                ),
              ),
              const SizedBox(height: 40),
              const Text("Searching for a friendly stranger...", style: TextStyle(fontSize: 16, fontStyle: FontStyle.italic)),
              TextButton(onPressed: () => setState(() => isSearching = false), child: const Text("Cancel Search", style: TextStyle(color: Colors.red))),
            ] else
              SizedBox(
                width: 250,
                height: 150,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    elevation: 8,
                  ),
                  onPressed: () {
                    setState(() => isSearching = true);
                    socket.emit('find-stranger');
                  },
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bolt, size: 50),
                      SizedBox(height: 10),
                      Text("Start Talking", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatColumn({
    required IconData icon,
    required Color iconColor,
    required String value,
    required String label,
  }) {
    return Column(
      children: [
        Icon(icon, color: iconColor, size: 32),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    socket.dispose();
    super.dispose();
  }
}

/// ---------------- CALL PAGE (WebRTC with Video Support) ----------------
class CallPage extends StatefulWidget {
  final String callId;
  final bool initiator;
  final IO.Socket socket;
  final int peerId;

  const CallPage({
    super.key,
    required this.callId,
    required this.initiator,
    required this.socket,
    required this.peerId,
  });

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  bool _micEnabled = true;
  bool _speakerEnabled = false;
  Duration _callDuration = Duration.zero;
  Timer? _timer;
  bool _ended = false;

  // Video variables
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _videoEnabled = false;
  bool _videoRequested = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    _initRenderers();
    _setupWebRTC();
    _setupVideoSignals();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() => _callDuration += const Duration(seconds: 1));
      }
    });
  }

  String _formatDuration(Duration d) {
    return "${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  void _setupVideoSignals() {
    widget.socket.on('video-request', (_) {
      if (!mounted) return;
      _showIncomingVideoDialog();
    });

    widget.socket.on('video-accepted', (_) async {
      if (!_videoEnabled) {
        await _enableVideo();
      }
    });

    widget.socket.on('video-rejected', (_) {
      if (!mounted) return;
      setState(() => _videoRequested = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Video request rejected")),
      );
    });

    widget.socket.on('video-offer', (data) async {
      if (!mounted || _peer == null) return;
      try {
        await _peer!.setRemoteDescription(
            RTCSessionDescription(data['sdp'], 'offer')
        );
        final answer = await _peer!.createAnswer();
        await _peer!.setLocalDescription(answer);

        widget.socket.emit('video-answer', {
          'callId': widget.callId,
          'sdp': answer.sdp,
        });
      } catch (e) {
        debugPrint("Error handling video offer: $e");
      }
    });

    widget.socket.on('video-answer', (data) async {
      if (!mounted || _peer == null) return;
      try {
        await _peer!.setRemoteDescription(
            RTCSessionDescription(data['sdp'], 'answer')
        );
      } catch (e) {
        debugPrint("Error handling video answer: $e");
      }
    });
  }

  void _showIncomingVideoDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text("Video Call Request"),
        content: const Text("The other user wants to start a video call"),
        actions: [
          TextButton(
            onPressed: () {
              widget.socket.emit('video-rejected', {
                'callId': widget.callId,
              });
              Navigator.pop(context);
            },
            child: const Text("Reject"),
          ),
          ElevatedButton(
            onPressed: () async {
              widget.socket.emit('video-accepted', {
                'callId': widget.callId,
              });
              Navigator.pop(context);
              await _enableVideo();
            },
            child: const Text("Accept"),
          ),
        ],
      ),
    );
  }

  Future<void> _enableVideo() async {
    if (_videoEnabled) return;

    try {
      setState(() => _videoEnabled = true);

      final videoStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {
          'facingMode': 'user',
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
          'frameRate': {'ideal': 30},
        },
      });

      final videoTrack = videoStream.getVideoTracks().first;
      final audioTrack = videoStream.getAudioTracks().first;

      final senders = await _peer!.getSenders();

      for (var sender in senders) {
        if (sender.track?.kind == 'video') {
          await sender.replaceTrack(videoTrack);
        } else if (sender.track?.kind == 'audio') {
          await sender.replaceTrack(audioTrack);
        }
      }

      if (!senders.any((s) => s.track?.kind == 'video')) {
        await _peer!.addTrack(videoTrack, videoStream);
      }

      _localRenderer.srcObject = videoStream;

      if (widget.initiator) {
        final offer = await _peer!.createOffer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': true,
        });

        String sdp = offer.sdp!;
        sdp = sdp.replaceAll(
          'useinbandfec=1',
          'useinbandfec=1;maxaveragebitrate=1500000',
        );

        await _peer!.setLocalDescription(
          RTCSessionDescription(sdp, 'offer'),
        );

        widget.socket.emit('video-offer', {
          'callId': widget.callId,
          'sdp': sdp,
        });
      }

      setState(() {});
    } catch (e) {
      debugPrint("Error enabling video: $e");
      setState(() => _videoEnabled = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to enable video: $e")),
        );
      }
    }
  }

  Future<void> _setupWebRTC() async {

    _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final config = {
      'iceServers': [
        {
          'urls': 'stun:stun.l.google.com:19302',
        },
        {
          'urls': 'turn:global.relay.metered.ca:80',
          'username': 'ea24271f9ddff1627a3ae3ce',
          'credential': 'ukWA9hz3E1E42iV0',
        },
        {
          'urls': 'turn:global.relay.metered.ca:443',
          'username': 'ea24271f9ddff1627a3ae3ce',
          'credential': 'ukWA9hz3E1E42iV0',
        },
      ],
      'sdpSemantics': 'unified-plan',
    };
    _peer = await createPeerConnection(config);
    Helper.setSpeakerphoneOn(false);
    _localStream!.getTracks().forEach((track) => _peer!.addTrack(track, _localStream!));
    _peer = await createPeerConnection(config);
    _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    _localStream!.getTracks().forEach((track) => _peer!.addTrack(track, _localStream!));

    _peer!.onIceCandidate = (candidate) {
      if (candidate != null) {
        widget.socket.emit('signal', {'callId': widget.callId, 'data': {'type': 'candidate', 'candidate': candidate.toMap()}});
      }
    };

    _peer!.onTrack = (event) {
      if (mounted) {
        setState(() {
          _remoteRenderer.srcObject = event.streams.first;
        });
      }
    };

    _peer!.onConnectionState = (state) {
      debugPrint("Connection state: $state");
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _endCall();
      }
    };

    widget.socket.on('signal', (data) async {
      try {
        if (data['type'] == 'offer') {
          await _peer!.setRemoteDescription(RTCSessionDescription(data['sdp'], 'offer'));
          final answer = await _peer!.createAnswer();
          await _peer!.setLocalDescription(answer);
          widget.socket.emit('signal', {'callId': widget.callId, 'data': {'type': 'answer', 'sdp': answer.sdp}});
        } else if (data['type'] == 'answer') {
          await _peer!.setRemoteDescription(RTCSessionDescription(data['sdp'], 'answer'));
        } else if (data['type'] == 'candidate') {
          final c = data['candidate'];
          await _peer!.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
        }
      } catch (e) {
        debugPrint("Signal handling error: $e");
      }
    });

    widget.socket.on('call-ended', (_) => _endCall(notifyServer: false));

    if (widget.initiator) {
      final offer = await _peer!.createOffer();
      await _peer!.setLocalDescription(offer);
      widget.socket.emit('signal', {'callId': widget.callId, 'data': {'type': 'offer', 'sdp': offer.sdp}});
    }

    _peer!.onIceConnectionState = (state) {
      debugPrint("ICE STATE: $state");
    };
  }

  void _endCall({bool notifyServer = true}) {
    if (_ended) return;
    _ended = true;

    if (notifyServer) {
      widget.socket.emit('leave-call', widget.callId);
    }

    _timer?.cancel();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _peer?.close();

    if (mounted) {
      _showReviewDialog(); // ALWAYS show for both users
    }
  }

  void _showReviewDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ReviewDialog(
        peerId: widget.peerId,
        callDuration: _callDuration.inSeconds,
        onComplete: () {
          Navigator.of(context).pop(); // Close dialog
          Navigator.of(context).pop(); // Close call page
        },
      ),
    );
  }

  void _toggleMic() {
    setState(() => _micEnabled = !_micEnabled);
    _localStream?.getAudioTracks().forEach((t) => t.enabled = _micEnabled);
  }

  void _toggleSpeaker() {
    setState(() {
      _speakerEnabled = !_speakerEnabled;
    });
    // This helper from the flutter_webrtc package controls the routing
    Helper.setSpeakerphoneOn(_speakerEnabled);
  }

  void _requestVideo() {
    if (_videoRequested || _videoEnabled) return;

    setState(() => _videoRequested = true);

    widget.socket.emit('video-request', {
      'callId': widget.callId,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Stack(
          children: [
            if (_videoEnabled)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              Positioned.fill(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(40),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.deepPurple, width: 2),
                        color: Colors.deepPurple.withOpacity(0.1),
                      ),
                      child: const Icon(Icons.person, size: 100, color: Colors.white54),
                    ),
                    const SizedBox(height: 30),
                    const Text("Talking with a Stranger", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                    Text(_formatDuration(_callDuration), style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 18, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),

            if (_videoEnabled)
              Positioned(
                right: 20,
                top: 80,
                width: 120,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.deepPurple, width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: RTCVideoView(_localRenderer, mirror: true),
                  ),
                ),
              ),

            if (_videoEnabled)
              Positioned(
                top: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _formatDuration(_callDuration),
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
              ),

            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
                decoration: BoxDecoration(
                  color: _videoEnabled ? Colors.black.withOpacity(0.7) : const Color(0xFF1E1E1E),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildCallAction(
                      icon: _micEnabled ? Icons.mic : Icons.mic_off,
                      label: "Mute",
                      color: _micEnabled ? Colors.white24 : Colors.red,
                      onTap: _toggleMic,
                    ),
                    _buildCallAction(
                      icon: _videoEnabled ? Icons.videocam : Icons.videocam_outlined,
                      label: "Video",
                      color: _videoEnabled
                          ? Colors.deepPurple
                          : (_videoRequested ? Colors.grey : Colors.blue),
                      onTap: _videoEnabled ? null : _requestVideo,
                    ),
                    _buildCallAction(
                      icon: Icons.call_end,
                      label: "End",
                      color: Colors.red,
                      onTap: _endCall,
                      isLarge: true,
                    ),
                    _buildCallAction(
                      icon: _speakerEnabled ? Icons.volume_up : Icons.volume_down,
                      label: "Speaker",
                      color: _speakerEnabled ? Colors.deepPurple : Colors.white24,
                      onTap: _toggleSpeaker,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallAction({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
    bool isLarge = false,
  }) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.5 : 1.0,
            child: CircleAvatar(
              radius: isLarge ? 35 : 28,
              backgroundColor: color,
              child: Icon(icon, color: Colors.white, size: isLarge ? 32 : 24),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  @override
  void dispose() {
    _ended = true;
    _timer?.cancel();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _peer?.close();
    widget.socket.off('signal');
    widget.socket.off('call-ended');
    widget.socket.off('video-request');
    widget.socket.off('video-accepted');
    widget.socket.off('video-rejected');
    widget.socket.off('video-offer');
    widget.socket.off('video-answer');
    super.dispose();
  }
}

/// ---------------- REVIEW DIALOG ----------------
class ReviewDialog extends StatefulWidget {
  final int peerId;
  final int callDuration;
  final VoidCallback onComplete;

  const ReviewDialog({
    super.key,
    required this.peerId,
    required this.callDuration,
    required this.onComplete,
  });

  @override
  State<ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<ReviewDialog> {
  int selectedRating = 5;
  bool isSubmitting = false;

  Future<void> _submitRating() async {
    setState(() => isSubmitting = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('userId');

      await http.post(
        Uri.parse('$API_BASE_URL/review'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'reviewerId': userId,
          'reviewedUserId': widget.peerId,
          'rating': selectedRating,
          'callDuration': widget.callDuration,
        }),
      );

      widget.onComplete();
    } catch (e) {
      debugPrint("Error submitting review: $e");
      widget.onComplete();
    }
  }

  Future<void> _reportUser() async {
    final reportReasonController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Report User"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Please describe the issue:"),
            const SizedBox(height: 16),
            TextField(
              controller: reportReasonController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: "Inappropriate behavior, harassment, etc.",
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await _submitReport(reportReasonController.text);
            },
            child: const Text("Submit Report"),
          ),
        ],
      ),
    );
  }

  Future<void> _submitReport(String reason) async {
    if (reason.trim().isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('userId');

      await http.post(
        Uri.parse('$API_BASE_URL/report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'reporterId': userId,
          'reportedUserId': widget.peerId,
          'reason': reason,
          'callDuration': widget.callDuration,
        }),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Report submitted successfully")),
        );
      }
    } catch (e) {
      debugPrint("Error submitting report: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_border, size: 60, color: Colors.deepPurple),
            const SizedBox(height: 16),
            const Text(
              "Rate Your Experience",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              "How was your conversation?",
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
            const SizedBox(height: 24),

            // Rating Slider
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("1", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Expanded(
                  child: Slider(
                    value: selectedRating.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    label: selectedRating.toString(),
                    activeColor: Colors.deepPurple,
                    onChanged: (value) {
                      setState(() => selectedRating = value.toInt());
                    },
                  ),
                ),
                const Text("10", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),

            // Rating Display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.deepPurple.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                selectedRating.toString(),
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.deepPurple,
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.report, color: Colors.red),
                    label: const Text("Report", style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: isSubmitting ? null : _reportUser,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: isSubmitting ? null : _submitRating,
                    child: isSubmitting
                        ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                        : const Text("Submit"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _generateRandomName() {
  final adj = ['Swift', 'Neon', 'Happy', 'Mystic', 'Silent'];
  final noun = ['Panda', 'Echo', 'Pixel', 'River', 'Star'];
  final r = Random();
  return '${adj[r.nextInt(adj.length)]}${noun[r.nextInt(noun.length)]}';
}