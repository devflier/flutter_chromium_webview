/// Local page for checking popup and new window requests.
final popupTestUrl = Uri.dataFromString(
  '''
<!doctype html><meta charset="utf-8"><title>Popup Test</title>
<style>
body { font: 20px sans-serif; margin: 40px; background: #f5f7fa; }
button { display: inline-block; font: inherit; padding: 10px; margin: 10px 0; }
a { display: block; margin: 10px 0; }
</style>
<h1>Popup and New Window Test</h1>

<a href="https://flutter.dev" target="_blank">Target _blank link to Flutter</a>

<button id="btn-open-url">window.open() with HTTPS URL</button><br>
<button id="btn-open-empty">window.open() without URL</button><br>
<button id="btn-open-multiple">window.open() multiple times</button><br>

<script>
document.getElementById('btn-open-url').addEventListener('click', () => {
  window.open('https://dart.dev', '_blank');
});

document.getElementById('btn-open-empty').addEventListener('click', () => {
  window.open('', '_blank');
});

document.getElementById('btn-open-multiple').addEventListener('click', () => {
  window.open('https://pub.dev', '_blank');
  window.open('https://flutter.dev', '_blank');
});

// Script-initiated popup without a user gesture
setTimeout(() => {
  window.open('https://example.com/no-gesture', '_blank');
}, 500);
</script>
''',
  mimeType: 'text/html',
  encoding: null,
).toString();
