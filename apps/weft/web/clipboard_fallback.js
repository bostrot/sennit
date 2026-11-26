// Copying in Sennit Web when the page is not a secure context.
//
// The phone serves Sennit Web over plain http on the local network, and there
// browsers leave `navigator.clipboard` out altogether. Flutter's web engine
// copies through nothing else, so every copy — a selection, "Copy" on a
// message, a pairing code — failed with "Clipboard is not available".
//
// This puts a small `navigator.clipboard` in its place that copies the old
// way, with `execCommand('copy')`. The engine calls `writeText` within the
// key press or tap that asked for it, which is the user gesture
// `execCommand` needs. Reading is left to the browser: a paste into the
// composer is the browser's own paste, and that needs no clipboard API.
//
// Loaded before the engine, and a no-op wherever the real API exists.
(function () {
  'use strict';
  if (navigator.clipboard) return;

  function notAllowed(message) {
    return Promise.reject(new DOMException(message, 'NotAllowedError'));
  }

  // First without touching the focus: a copy event the page answers itself.
  // Chrome and Firefox fire it even with nothing selected.
  function copyThroughEvent(text) {
    var answered = false;
    function onCopy(event) {
      event.clipboardData.setData('text/plain', text);
      event.preventDefault();
      answered = true;
    }
    document.addEventListener('copy', onCopy, true);
    try {
      return document.execCommand('copy') && answered;
    } catch (_) {
      return false;
    } finally {
      document.removeEventListener('copy', onCopy, true);
    }
  }

  // Safari fires no copy event without a selection, so give it one: a
  // hidden field holding the text, selected, copied, removed, and the focus
  // handed back to wherever it was.
  function copyThroughSelection(text) {
    var previous = document.activeElement;
    var area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.setAttribute('aria-hidden', 'true');
    area.style.cssText =
      'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;' +
      'pointer-events:none;';
    document.body.appendChild(area);
    try {
      area.select();
      area.setSelectionRange(0, text.length);
      return document.execCommand('copy');
    } catch (_) {
      return false;
    } finally {
      area.remove();
      if (previous && typeof previous.focus === 'function') {
        previous.focus({ preventScroll: true });
      }
    }
  }

  var clipboard = {
    writeText: function (text) {
      text = String(text);
      return copyThroughEvent(text) || copyThroughSelection(text)
        ? Promise.resolve()
        : notAllowed('The browser refused to copy.');
    },
    readText: function () {
      return notAllowed('Reading the clipboard needs a secure context.');
    },
  };

  try {
    Object.defineProperty(navigator, 'clipboard', {
      value: clipboard,
      configurable: true,
    });
  } catch (_) {
    // A browser that will not take it copies as it did before: not at all.
  }
})();
