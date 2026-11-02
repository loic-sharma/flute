import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flute example',
      home: const SignInPage(),
    );
  }
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _error;

  void _login() {
    if (_email.text.isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your email and password');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => HomePage(email: _email.text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(header: true, child: const Text('Sign in', style: TextStyle(fontSize: 24))),
              TextField(
                key: const ValueKey<String>('email'),
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                key: const ValueKey<String>('password'),
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _login, child: const Text('Login')),
            ],
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.email});

  final String email;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Welcome, $email')),
      body: ListView(
        children: <Widget>[
          const ListTile(leading: CircularProgressIndicator(), title: Text('Syncing')),
          for (int i = 0; i < 11; i++) ListTile(title: Text('Item $i')),
          ElevatedButton(
            onPressed: () {
              debugPrint('Crash pressed');
              throw StateError('Crash button pressed');
            },
            child: const Text('Crash'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
