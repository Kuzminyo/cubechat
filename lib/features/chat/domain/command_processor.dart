import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/nickname_controller.dart';
import '../../../core/identity/wipe_service.dart';
import '../../channels/data/channel_controller.dart';
import '../../channels/models/channel.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/messages_controller.dart';

/// Outcome of running a `/command` typed into the chat input.
///
/// All IRC commands are local-only — they don't go on the wire. Their result
/// is rendered as a snackbar in the chat screen.
class CommandResult {
  CommandResult.ok(this.message) : success = true;
  CommandResult.fail(this.message) : success = false;

  final bool success;
  final String message;
}

/// Parses and executes `/cmd args` from the chat input.
///
/// Supported:
///   - `/nick <name>`   — change the user's display name
///   - `/who`           — list known peers (online + offline)
///   - `/join #x [pw]`  — join a shared-key group channel
///   - `/leave [#x]`    — leave a channel (the current one if omitted)
///   - `/channels`      — list joined channels
///   - `/clear`         — wipe the current chat's message history
///   - `/wipe`          — emergency wipe (with a guard against accidents)
///   - `/help`          — print available commands
///
/// Returns null if the input is NOT a command (regular message — let the
/// chat screen send it through MessagingService as usual).
class CommandProcessor {
  CommandProcessor(this._ref, this._currentChatId);

  final WidgetRef _ref;
  final String _currentChatId;

  /// Tries to parse [input] as a slash-command. Returns null for regular
  /// messages so the caller falls through to the normal send path.
  Future<CommandResult?> tryExecute(String input) async {
    final trimmed = input.trim();
    if (!trimmed.startsWith('/')) return null;

    final parts = trimmed.substring(1).split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return null;

    final cmd = parts.first.toLowerCase();
    final args = parts.skip(1).join(' ').trim();

    switch (cmd) {
      case 'nick':
        return _nick(args);
      case 'who':
        return _who();
      case 'join':
        return _join(args);
      case 'leave':
      case 'part':
        return _leave(args);
      case 'channels':
        return _channels();
      case 'clear':
        return _clear();
      case 'wipe':
        return _wipe(args);
      case 'help':
      case '?':
        return _help();
      default:
        return CommandResult.fail('Unknown command: /$cmd');
    }
  }

  Future<CommandResult> _nick(String name) async {
    if (name.isEmpty) {
      return CommandResult.fail('Usage: /nick <name>');
    }
    if (name.length > NicknameController.maxLength) {
      return CommandResult.fail(
          'Nickname too long (max ${NicknameController.maxLength} chars)');
    }
    await _ref.read(nicknameControllerProvider.notifier).set(name);
    return CommandResult.ok('Nickname set to "$name"');
  }

  CommandResult _who() {
    final peers = _ref.read(knownPeersControllerProvider);
    if (peers.isEmpty) {
      return CommandResult.ok('No known peers yet');
    }
    final names = peers.values.map((p) {
      final verified = p.isVerified ? ' ✓' : '';
      return '${p.displayName}$verified';
    }).join(', ');
    return CommandResult.ok('${peers.length} peer(s): $names');
  }

  Future<CommandResult> _join(String args) async {
    if (args.isEmpty) {
      return CommandResult.fail('Usage: /join #channel [password]');
    }
    final parts = args.split(RegExp(r'\s+'));
    final name = parts.first;
    final password = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    try {
      final ch = await _ref
          .read(channelControllerProvider.notifier)
          .join(name, password: password);
      return CommandResult.ok('Joined ${ch.name} — open it from Chats');
    } catch (e) {
      return CommandResult.fail('Could not join: $e');
    }
  }

  Future<CommandResult> _leave(String args) async {
    final raw = args.isNotEmpty ? args : _currentChatId;
    final normalized = normalizeChannelName(raw);
    // Reject an empty name, or a no-arg call from a 1:1 chat (nothing to
    // leave — the current conversation isn't a channel).
    if (normalized.isEmpty ||
        (args.isEmpty && !_currentChatId.startsWith('#'))) {
      return CommandResult.fail('Usage: /leave #channel');
    }
    await _ref.read(channelControllerProvider.notifier).leave(normalized);
    return CommandResult.ok('Left $normalized');
  }

  CommandResult _channels() {
    final chans = _ref.read(channelControllerProvider);
    if (chans.isEmpty) {
      return CommandResult.ok('No channels joined. Use /join #name');
    }
    return CommandResult.ok(
        '${chans.length} channel(s): ${chans.keys.join(', ')}');
  }

  Future<CommandResult> _clear() async {
    final messages = _ref.read(messagesControllerProvider.notifier);
    await messages.clearForChat(_currentChatId);
    return CommandResult.ok('Cleared this chat');
  }

  Future<CommandResult> _wipe(String args) async {
    // Require '/wipe yes' to guard against typos.
    if (args.toLowerCase() != 'yes') {
      return CommandResult.fail(
          'Type "/wipe yes" to confirm Emergency Wipe (or use triple-tap on the cube)');
    }
    await emergencyWipe(_ref);
    return CommandResult.ok('Everything wiped');
  }

  CommandResult _help() {
    const lines = [
      '/nick <name> · set your nickname',
      '/who · list known peers',
      '/join #name [pw] · join a group channel',
      '/leave [#name] · leave a channel',
      '/channels · list joined channels',
      '/clear · clear this chat history',
      '/wipe yes · emergency wipe everything',
      '/help · this list',
    ];
    return CommandResult.ok(lines.join('\n'));
  }
}
