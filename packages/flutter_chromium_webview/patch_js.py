import sys

path = '/Users/veneno/Projects/packages/flutter_chromium_webview/packages/flutter_chromium_webview/lib/chromium_youtube_player.dart'
with open(path, 'r') as f:
    content = f.read()

target = """window.onYouTubeIframeAPIReady=function(){
 player=new YT.Player('player',{host:'https://www.youtube.com',playerVars:{enablejsapi:1,playsinline:1,origin:config.origin,widget_referrer:config.referrer},events:{
 onReady:()=>send('Ready',true),"""

replacement = """window.onYouTubeIframeAPIReady=function(){
 player=new YT.Player('player',{host:'https://www.youtube.com',playerVars:{enablejsapi:1,playsinline:1,origin:config.origin,widget_referrer:config.referrer},events:{
 onReady:()=>{
   send('Ready',true);
   // Phase B: Debug Heartbeat
   setInterval(()=>{
     const state = player && player.getPlayerState ? player.getPlayerState() : null;
     const time = player && player.getCurrentTime ? player.getCurrentTime() : null;
     const idx = player && player.getPlaylistIndex ? player.getPlaylistIndex() : null;
     send('DebugHeartbeat', JSON.stringify({
       perfTimestamp: performance.now(),
       state: state,
       currentTime: time,
       playlistIndex: idx,
       hidden: document.hidden,
       visibility: document.visibilityState
     }));
   }, 1000);
 },"""

content = content.replace(target, replacement)

with open(path, 'w') as f:
    f.write(content)
