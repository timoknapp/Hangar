// Mobile toolbar for Copilot Workstation
// Sends input directly via ttyd's WebSocket (not keyboard events)
(function() {
  if (document.getElementById('mt')) return;

  // === Send input to the terminal ===
  // Strategy: use window.term.input() (xterm.js API exposed by ttyd)
  // Fallback: WebSocket send with ttyd's binary protocol
  var ttyWs = null;

  // Hook WebSocket constructor + send as fallback
  var OrigWS = window.WebSocket;
  var origSend = OrigWS.prototype.send;
  window.WebSocket = function(url, protocols) {
    var ws = protocols ? new OrigWS(url, protocols) : new OrigWS(url);
    if (!ttyWs && url && String(url).indexOf('/ws') !== -1) ttyWs = ws;
    return ws;
  };
  window.WebSocket.prototype = OrigWS.prototype;
  window.WebSocket.CONNECTING = OrigWS.CONNECTING;
  window.WebSocket.OPEN = OrigWS.OPEN;
  window.WebSocket.CLOSING = OrigWS.CLOSING;
  window.WebSocket.CLOSED = OrigWS.CLOSED;
  OrigWS.prototype.send = function(data) {
    if (!ttyWs && this.url && this.url.indexOf('/ws') !== -1) ttyWs = this;
    return origSend.call(this, data);
  };

  function sendInput(text) {
    // Primary: xterm.js input() — most reliable, no WebSocket needed
    if (window.term && typeof window.term.input === 'function') {
      window.term.input(text);
      return;
    }
    // Fallback: raw WebSocket send
    if (ttyWs && ttyWs.readyState === 1) {
      var enc = new TextEncoder();
      var bytes = enc.encode(text);
      var msg = new Uint8Array(bytes.length + 1);
      msg[0] = 0;
      origSend.call(ttyWs, msg.buffer);
    }
  }

  // === Wait for DOM to be ready before touching it ===
  function init() {
    if (document.getElementById('mt')) return;

    // === Styles ===
    var style = document.createElement('style');
  style.textContent = [
    /* Toolbar hidden by default, fixed at top when visible */
    '#mt{position:fixed;top:0;left:0;right:0;z-index:99999;',
    'background:#181825;border-bottom:1px solid #313244;',
    'padding:env(safe-area-inset-top,4px) 4px 4px 4px;',
    'display:none;flex-direction:column;gap:4px;',
    '-webkit-user-select:none;user-select:none}',
    /* Mobile only: show toolbar */
    '@media(max-width:768px),(pointer:coarse){#mt{display:flex}}',
    '.tr{display:flex;gap:3px;overflow-x:auto;scrollbar-width:none;padding:0 2px}',
    '.tr::-webkit-scrollbar{display:none}',
    '.b{flex-shrink:0;background:#313244;color:#cdd6f4;border:1px solid #45475a;border-radius:6px;',
    'padding:8px 10px;font-size:13px;font-family:-apple-system,system-ui,sans-serif;cursor:pointer;',
    'touch-action:manipulation;-webkit-tap-highlight-color:transparent;white-space:nowrap;',
    'min-width:38px;text-align:center}',
    '.b:active{background:#585b70;transform:scale(.95)}',
    '.a{background:#89b4fa;color:#1e1e2e;border-color:#89b4fa;font-weight:600}',
    '.a:active{background:#74c7ec}',
    '.w{background:#f38ba8;color:#1e1e2e;border-color:#f38ba8;font-weight:600}',
    '.m{background:#45475a;border-color:#585b70}',
    '.m.on{background:#89b4fa;color:#1e1e2e}'
  ].join('');
  document.head.appendChild(style);

  // === Toolbar HTML ===
  var toolbar = document.createElement('div');
  toolbar.id = 'mt';
  toolbar.innerHTML = [
    '<div class="tr">',
    '<button class="b m" id="bc">Ctrl</button>',
    '<button class="b" data-seq="&#9;">Tab</button>',
    '<button class="b" data-seq="&#27;[Z">⇧Tab</button>',
    '<button class="b" data-seq="&#27;">Esc</button>',
    '<button class="b" data-t="/">/</button>',
    '<button class="b" data-seq="&#27;[A">↑</button>',
    '<button class="b" data-seq="&#27;[B">↓</button>',
    '<button class="b" data-seq="&#27;[D">←</button>',
    '<button class="b" data-seq="&#27;[C">→</button>',
    '<button class="b" data-seq="&#13;">⏎</button>',
    '</div>',
    '<div class="tr">',
    '<button class="b a" data-cmd="copilot">copilot</button>',
    '<button class="b a" data-cmd="/plan">/plan</button>',
    '<button class="b a" data-cmd="/resume">/resume</button>',
    '<button class="b a" data-cmd="/fleet">/fleet</button>',
    '<button class="b a" data-cmd="/model">/model</button>',
    '<button class="b" data-cmd="/agent">/agent</button>',
    '<button class="b" data-cmd="/skills">/skills</button>',
    '<button class="b" data-cmd="/mcp">/mcp</button>',
    '<button class="b" data-t="y">y</button>',
    '<button class="b" data-t="n">n</button>',
    '<button class="b w" data-seq="&#3;">^C</button>',
    '</div>',
    '<div class="tr">',
    '<button class="b a" data-cmd="squad">squad</button>',
    '<button class="b" data-cmd="/status">/status</button>',
    '<button class="b" data-cmd="/agents">/agents</button>',
    '<button class="b" data-cmd="/sessions">/sessions</button>',
    '<button class="b" data-cmd="/history">/history</button>',
    '<button class="b" data-cmd="/help">/help</button>',
    '</div>'
  ].join('');

  // Insert toolbar at top of page
  document.body.insertBefore(toolbar, document.body.firstChild);

  // Adjust terminal container so it doesn't sit behind the fixed toolbar
  function adjustTerminal() {
    var tb = document.getElementById('mt');
    if (!tb || getComputedStyle(tb).display === 'none') return;
    var h = tb.offsetHeight;
    // ttyd's terminal container is the first non-toolbar child of body
    var kids = document.body.children;
    for (var i = 0; i < kids.length; i++) {
      if (kids[i].id === 'mt') continue;
      kids[i].style.position = 'fixed';
      kids[i].style.top = h + 'px';
      kids[i].style.left = '0';
      kids[i].style.right = '0';
      kids[i].style.bottom = '0';
      kids[i].style.height = 'calc(100% - ' + h + 'px)';
      break;
    }
    window.dispatchEvent(new Event('resize'));
  }
  // Run after ttyd finishes rendering
  setTimeout(adjustTerminal, 200);
  setTimeout(adjustTerminal, 1000);
  // Re-adjust on orientation change
  window.addEventListener('orientationchange', function() { setTimeout(adjustTerminal, 300); });

  // === Ctrl modifier state ===
  var ctrlOn = false;
  var ctrlBtn = document.getElementById('bc');

  function clearCtrl() { ctrlOn = false; ctrlBtn.classList.remove('on'); }

  // === Click handler ===
  toolbar.addEventListener('pointerdown', function(e) {
    var btn = e.target.closest('.b');
    if (!btn) return;
    e.preventDefault();
    e.stopPropagation();

    // Ctrl toggle
    if (btn.id === 'bc') {
      ctrlOn = !ctrlOn;
      ctrlBtn.classList.toggle('on', ctrlOn);
      return;
    }

    // Raw escape sequence (Tab, Enter, Esc, arrows, ^C)
    if (btn.dataset.seq) {
      sendInput(btn.dataset.seq);
      clearCtrl();
      return;
    }

    // Command (type text + Enter)
    if (btn.dataset.cmd) {
      sendInput(btn.dataset.cmd + '\r');
      clearCtrl();
      return;
    }

    // Single character
    if (btn.dataset.t) {
      if (ctrlOn) {
        // Ctrl+char: send control code (e.g. Ctrl+C = 0x03)
        var code = btn.dataset.t.toUpperCase().charCodeAt(0) - 64;
        if (code > 0 && code < 32) sendInput(String.fromCharCode(code));
      } else {
        sendInput(btn.dataset.t);
      }
      clearCtrl();
      return;
    }
  });
  } // end init()

  // Run init when DOM is ready, or immediately if already loaded
  if (document.body) {
    init();
  } else {
    document.addEventListener('DOMContentLoaded', init);
  }
})();
