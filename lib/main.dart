import 'dart:math';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

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

  @override
  void initState() {
    super.initState();
    currentName = widget.displayName;
    currentPhotoUrl = widget.photoUrl;
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
      // 1. Upload if there's a new file
      if (imageFile != null) {
        final uploadedLink = await _uploadPhoto(imageFile, userId);
        if (uploadedLink != null) {
          // Clear the cache for the base URL
          await PaintingBinding.instance.imageCache.evict(NetworkImage(uploadedLink));

          // Add a timestamp 'Cache Buster' so the UI refreshes instantly
          updatedUrl = "$uploadedLink?t=${DateTime.now().millisecondsSinceEpoch}";
        }
      }

      // 2. Update DB (Name only)
      await http.put(
        Uri.parse('$API_BASE_URL/user/profile'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': userId, 'displayName': newName}),
      );

      // 3. Update Local Cache (Save the BASE url without the timestamp)
      await prefs.setString('displayName', newName);
      if (updatedUrl != null) {
        // Save the clean URL for next session
        String cleanUrl = updatedUrl.split('?')[0];
        await prefs.setString('photoUrl', cleanUrl);
      }

      setState(() {
        currentName = newName;
        currentPhotoUrl = updatedUrl; // State gets the timestamped version
      });
    } catch (e) {
      debugPrint("Profile update error: $e");
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
                backgroundImage: (currentPhotoUrl != null && currentPhotoUrl!.isNotEmpty) ? NetworkImage(currentPhotoUrl!) : null,
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
            const Text("Logged in as", style: TextStyle(color: Colors.grey)),
            Text(currentName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 60),
            if (isSearching) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              const Text("Looking for a match..."),
              TextButton(onPressed: () => setState(() => isSearching = false), child: const Text("Cancel")),
            ] else
              SizedBox(
                width: 250, height: 100,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
                  onPressed: () => setState(() => isSearching = true),
                  child: const Text("Find a Stranger", style: TextStyle(fontSize: 18)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _generateRandomName() {
  final adj = ['Swift', 'Neon', 'Happy'], noun = ['Panda', 'Echo', 'Pixel'];
  final r = Random();
  return '${adj[r.nextInt(adj.length)]}${noun[r.nextInt(noun.length)]}';
}