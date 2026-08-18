import 'package:flutter/material.dart';

import '../../gateway/novelia/novelia_auth_gateway.dart';

typedef AccountLogin =
    Future<void> Function({required String username, required String password});

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    required this.onLogin,
    this.onHostedAccountHelp,
    super.key,
  });

  final AccountLogin onLogin;
  final VoidCallback? onHostedAccountHelp;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  var _submitting = false;
  var _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _passwordController.clear();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.onLogin(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      _passwordController.clear();
      if (mounted) Navigator.of(context).pop();
    } on NoveliaAuthException catch (error) {
      if (!mounted) return;
      setState(() => _error = _messageFor(error));
    } on Object {
      if (!mounted) return;
      setState(() => _error = '登录失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  static String _messageFor(NoveliaAuthException error) {
    return switch (error.kind) {
      NoveliaAuthFailureKind.invalidCredentials => '用户名或密码不正确',
      NoveliaAuthFailureKind.timeout => '账号服务响应超时，请稍后重试',
      NoveliaAuthFailureKind.network => '无法连接账号服务，请检查网络',
      NoveliaAuthFailureKind.sessionExpired => '登录会话已失效，请重新登录',
      NoveliaAuthFailureKind.invalidResponse => switch (error.diagnosticCode) {
        'login_missing_refresh_cookie' =>
          '登录响应没有建立刷新会话（login_missing_refresh_cookie）',
        'refresh_invalid_access_token' =>
          '刷新响应不是可识别的访问令牌（refresh_invalid_access_token）',
        'refresh_missing_refresh_cookie' =>
          '刷新响应移除了登录会话（refresh_missing_refresh_cookie）',
        'response_too_large' => '账号服务响应过大（response_too_large）',
        _ => '账号服务返回了无法识别的数据',
      },
      NoveliaAuthFailureKind.server => '账号服务暂时不可用，请稍后重试',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录 Novelia 账号')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.account_circle_outlined,
                        size: 54,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '登录后可使用远程收藏夹与阅读历史。密码只用于本次登录，不会保存。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        key: const ValueKey('account-username-field'),
                        controller: _usernameController,
                        enabled: !_submitting,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '请输入用户名'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const ValueKey('account-password-field'),
                        controller: _passwordController,
                        enabled: !_submitting,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: '密码',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            key: const ValueKey('toggle-account-password'),
                            tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                            onPressed: _submitting
                                ? null
                                : () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (value) =>
                            value == null || value.isEmpty ? '请输入密码' : null,
                      ),
                      if (_error case final error?) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            error,
                            key: const ValueKey('account-login-error'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        key: const ValueKey('account-login-button'),
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.login),
                        label: Text(_submitting ? '正在登录' : '登录'),
                      ),
                      if (widget.onHostedAccountHelp != null) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          key: const ValueKey('hosted-account-help-button'),
                          onPressed: _submitting
                              ? null
                              : widget.onHostedAccountHelp,
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('注册或找回密码'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
