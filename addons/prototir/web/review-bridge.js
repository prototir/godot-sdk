(function () {
  'use strict';
  let pending;
  window.__prototirReviewBridge = {
    enable(json, visibility, capture) {
      const options = JSON.parse(json);
      options.onOpenChange = open => visibility(open);
      options.capture = () => new Promise((resolve, reject) => {
        if (pending) { reject(new Error('Capture already pending.')); return; }
        const timer = setTimeout(() => { pending = undefined; reject(new Error('Godot capture timed out.')); }, 8000);
        pending = { resolve: data => { clearTimeout(timer); resolve(data); }, cancel: () => { clearTimeout(timer); reject(new Error('Review closed.')); } };
        capture();
      });
      window.Prototir.review.enable(options);
    },
    captured(data) { const request = pending; pending = undefined; request?.resolve(data); },
    disable() { pending?.cancel(); pending = undefined; window.Prototir.review.disable(); }
  };
})();
