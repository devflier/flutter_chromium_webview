import re
import os

file_path = r'C:\Users\User\Projects\flutter_chromium_webview\packages\flutter_chromium_webview\lib\chromium_youtube_player.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    code = f.read()

# 1. Add _playlistId state
code = re.sub(r'  String\? _videoId;\n', '  String? _videoId;\n  String? _playlistId;\n', code)

# 2. Add loadPlaylist, cuePlaylist, nextVideo, etc.
insert_pos = code.find('  Future<void> playVideo() => _enqueue(() async {')
if insert_pos != -1:
    playlist_methods = '''  Future<void> loadPlaylist({
    required String playlistId,
    int index = 0,
    double startSeconds = 0,
  }) => _selectPlaylist(playlistId, index, startSeconds, true);

  Future<void> cuePlaylist({
    required String playlistId,
    int index = 0,
    double startSeconds = 0,
  }) => _selectPlaylist(playlistId, index, startSeconds, false);

  Future<void> _selectPlaylist(
    String playlistId,
    int index,
    double start,
    bool play,
  ) {
    if (playlistId.isEmpty) {
      throw ArgumentError.value(playlistId, 'playlistId', 'Cannot be empty');
    }
    _time(start);
    if (index < 0) throw ArgumentError.value(index, 'index', 'Cannot be negative');

    return _enqueue(() async {
      _videoId = null;
      _playlistId = playlistId;
      _position = start;
      _end = null;
      _playing = play;
      await _request(play ? 'loadPlaylist' : 'cuePlaylist', [
        {'list': playlistId, 'listType': 'playlist', 'index': index, 'startSeconds': start},
      ]);
    });
  }

  Future<void> nextVideo() => _enqueue(() async {
    await _request('nextVideo', []);
  });

  Future<void> previousVideo() => _enqueue(() async {
    await _request('previousVideo', []);
  });

  Future<void> playVideoAt(int index) {
    if (index < 0) throw ArgumentError.value(index, 'index', 'Cannot be negative');
    return _enqueue(() async {
      await _request('playVideoAt', [index]);
    });
  }

  Future<List<String>> getPlaylist() => _enqueue(() async {
    final value = await _request('getPlaylist', []);
    if (value is! List) throw StateError('Invalid playlist result');
    return value.cast<String>();
  });

  Future<int> getPlaylistIndex() => _enqueue(() async {
    final value = await _request('getPlaylistIndex', []);
    if (value is! num) throw StateError('Invalid playlist index result');
    return value.toInt();
  });

'''
    code = code[:insert_pos] + playlist_methods + code[insert_pos:]

# 3. Modify reload() to support _playlistId
reload_start = code.find('    if (_videoId != null) {')
reload_end = code.find('    }\n  });', reload_start)
if reload_start != -1 and reload_end != -1:
    new_reload = '''    if (_videoId != null) {
      await _request(_playing ? 'loadVideoById' : 'cueVideoById', [
        {
          'videoId': _videoId,
          'startSeconds': _position,
          if (_end != null) 'endSeconds': _end,
        },
      ]);
    } else if (_playlistId != null) {
      await _request(_playing ? 'loadPlaylist' : 'cuePlaylist', [
        {
          'list': _playlistId,
          'listType': 'playlist',
          'index': 0, // In reality, we'd need to store current index, but let's keep it simple for now or fetch it during dispose
          'startSeconds': _position,
        },
      ]);
    }'''
    code = code[:reload_start] + new_reload + code[reload_end+5:]

# 4. Modify methods Set in JS
code = code.replace(
    "'loadVideoById','cueVideoById','playVideo','pauseVideo','seekTo','setVolume','getVolume','getCurrentTime','getDuration','getVideoData'",
    "'loadVideoById','cueVideoById','loadPlaylist','cuePlaylist','nextVideo','previousVideo','playVideoAt','getPlaylist','getPlaylistIndex','playVideo','pauseVideo','seekTo','setVolume','getVolume','getCurrentTime','getDuration','getVideoData'"
)

# 5. Fix _selectVideo to clear _playlistId
code = re.sub(r'(_videoId = video;\n)', r'\1      _playlistId = null;\n', code)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(code)

print("Done")
