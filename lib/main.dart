import 'dart:math';
import 'dart:io';
import 'config.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;


void main() {
  runApp(const TalkyApp());
}

class TalkyApp extends StatelessWidget {
  const TalkyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}

/// ---------------- AUTH GATE ----------------
/// Decides whether to show Login or Profile
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool isLoggedIn = false;
  String? displayName;
  String? photoPath;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      isLoggedIn = prefs.getBool('loggedIn') ?? false;
      displayName = prefs.getString('displayName');
      photoPath = prefs.getString('photoPath');
      final userId = prefs.getInt('userId');
      print('Loaded userId: $userId');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!isLoggedIn) {
      return LoginScreen(onLogin: _onLogin);
    } else {
      return ProfileScreen(
        displayName: displayName!,
        photoPath: photoPath,
        onLogout: _logout,
        onUpdateName: _updateName,
        onUpdatePhoto: _updatePhoto,
      );
    }
  }

  Future<void> _onLogin(GoogleSignInAccount user) async {
    final prefs = await SharedPreferences.getInstance();

    final randomName = _generateRandomName();

    await prefs.setBool('loggedIn', true);
    await prefs.setString('displayName', randomName);
    final response = await http.post(
      Uri.parse('$API_BASE_URL/user'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'googleId': user.id,
        'email': user.email,
        'displayName': randomName,
        'photoUrl': user.photoUrl,
      }),
    );

    final data = jsonDecode(response.body);
    await prefs.setInt('userId', data['id']);

    print('Backend user id: ${data['id']}');


    setState(() {
      isLoggedIn = true;
      displayName = randomName;
    });
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    setState(() {
      isLoggedIn = false;
    });
  }

  Future<void> _updateName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('displayName', name);
    setState(() => displayName = name);
  }

  Future<void> _updatePhoto(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('photoPath', path);
    setState(() => photoPath = path);
  }
}

/// ---------------- LOGIN SCREEN ----------------
class LoginScreen extends StatelessWidget {
  final Function(GoogleSignInAccount) onLogin;

  LoginScreen({super.key, required this.onLogin});

  final GoogleSignIn _googleSignIn = GoogleSignIn();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          child: const Text('Sign in with Google'),
          onPressed: () async {
            final user = await _googleSignIn.signIn();
            if (user != null) {
              onLogin(user);
            }
          },
        ),
      ),
    );
  }
}

/// ---------------- PROFILE SCREEN ----------------
class ProfileScreen extends StatelessWidget {
  final String displayName;
  final String? photoPath;
  final VoidCallback onLogout;
  final Function(String) onUpdateName;
  final Function(String) onUpdatePhoto;

  ProfileScreen({
    super.key,
    required this.displayName,
    required this.photoPath,
    required this.onLogout,
    required this.onUpdateName,
    required this.onUpdatePhoto,
  });

  final TextEditingController _controller = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  @override
  Widget build(BuildContext context) {
    _controller.text = displayName;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Profile'),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: onLogout),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            GestureDetector(
              onTap: () async {
                final picked =
                await _picker.pickImage(source: ImageSource.gallery);
                if (picked != null) {
                  onUpdatePhoto(picked.path);
                }
              },
              child: CircleAvatar(
                radius: 50,
                backgroundImage:
                photoPath != null ? FileImage(File(photoPath!)) : null,
                child:
                photoPath == null ? const Icon(Icons.person, size: 50) : null,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              child: const Text('Save Name'),
              onPressed: () => onUpdateName(_controller.text),
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------------- RANDOM NAME ----------------
String _generateRandomName() {
  const adjectives = ['Silent', 'Blue', 'Brave', 'Swift', 'Calm'];
  const nouns = ['Falcon', 'River', 'Tiger', 'Voice', 'Speaker'];
  final r = Random();
  return '${adjectives[r.nextInt(adjectives.length)]}'
      '${nouns[r.nextInt(nouns.length)]}';
}
