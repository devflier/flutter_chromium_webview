/// Local page for checking native input without a network dependency.
final inputTestUrl = Uri.dataFromString(
  '''
<!doctype html><meta charset="utf-8"><title>Keyboard and focus test</title>
<style>
body { font: 20px sans-serif; margin: 40px; background: #f5f7fa; }
input, textarea { display: block; font: inherit; width: 80%; padding: 12px; margin: 15px 0; }
output { display: block; white-space: pre-wrap; padding: 20px; background: white; }
</style>
<h1>Keyboard and focus test</h1>
<p>Click a field, type, use Ctrl+A/C/X/V, arrows, Backspace, and Tab.
Try accented characters or an input method. Click the Flutter URL field to test focus transfer.</p>
<input id="first" placeholder="First field" aria-label="First field">
<textarea id="second" placeholder="Second field" aria-label="Second field" rows="4"></textarea>
<select id="third" aria-label="Dropdown test">
  <option>Option 1 (HTML popup)</option>
  <option>Option 2</option>
  <option>Option 3</option>
  <option>Option 4</option>
</select>
<br><br>
<button onclick="alert('Hello from Chromium!')">Alert</button>
<button onclick="document.getElementById('status').innerText = 'Confirm: ' + confirm('Are you sure?')">Confirm</button>
<button onclick="document.getElementById('status').innerText = 'Prompt: ' + prompt('What is your name?', 'Flutter')">Prompt</button>
<output id="status">Ready</output>
<script>
for (const element of document.querySelectorAll('input, textarea')) {
  for (const event of ['input', 'keyup', 'focus', 'compositionupdate', 'compositionend']) {
    element.addEventListener(event, e => {
      document.getElementById('status').textContent =
        'Field: ' + element.id + '\\nValue: ' + element.value +
        '\\nEvent: ' + e.type + '\\nKey: ' + (e.key || '') +
        '\\nSelection: ' + element.selectionStart + ':' + element.selectionEnd;
    });
  }
}
</script>
''',
  mimeType: 'text/html',
  encoding: null,
).toString();
