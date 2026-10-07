import re

file_path = r'C:\Users\User\Projects\flutter_chromium_webview\packages\flutter_chromium_webview\test\youtube_player_test.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    code = f.read()

test_code = '''
  test('dispatches playlist commands correctly', () async {
    await player.initialize();
    
    final load = player.loadPlaylist(playlistId: 'PL1234567890', index: 1, startSeconds: 10);
    expect(commands.last['method'], 'loadPlaylist');
    expect((commands.last['args'] as List).first['list'], 'PL1234567890');
    expect((commands.last['args'] as List).first['listType'], 'playlist');
    expect((commands.last['args'] as List).first['index'], 1);
    expect((commands.last['args'] as List).first['startSeconds'], 10);
    
    await load;
    
    final cue = player.cuePlaylist(playlistId: 'PL0987654321', index: 2, startSeconds: 20);
    expect(commands.last['method'], 'cuePlaylist');
    expect((commands.last['args'] as List).first['list'], 'PL0987654321');
    expect((commands.last['args'] as List).first['listType'], 'playlist');
    expect((commands.last['args'] as List).first['index'], 2);
    expect((commands.last['args'] as List).first['startSeconds'], 20);
    
    await cue;
    
    final next = player.nextVideo();
    expect(commands.last['method'], 'nextVideo');
    await next;
    
    final prev = player.previousVideo();
    expect(commands.last['method'], 'previousVideo');
    await prev;
    
    final playAt = player.playVideoAt(5);
    expect(commands.last['method'], 'playVideoAt');
    expect((commands.last['args'] as List).first, 5);
    await playAt;
  });
'''

# insert before the last }
code = code[:code.rfind('}')] + test_code + '}\n'

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(code)

print("Done")
