/* Keep Android TV logical sizes readable on Full HD and larger TV viewports.
 * Native AVPlay remains outside this scaled presentation layer. Its adapter
 * consumes getBoundingClientRect() values in the physical DOM viewport. */
(function () {
  'use strict';
  var viewport = document.getElementById('ui-viewport');
  var previewRect = null;
  function maskPane(name, x, y, width, height) {
    var pane = document.getElementById('preview-mask-' + name);
    pane.style.left = x + 'px'; pane.style.top = y + 'px';
    pane.style.width = width + 'px'; pane.style.height = height + 'px';
  }
  function setPreviewRect(rect) {
    if (!rect || !isFinite(rect.x) || !isFinite(rect.y) || !isFinite(rect.width) || !isFinite(rect.height) || rect.width <= 0 || rect.height <= 0) return;
    previewRect = {x:rect.x, y:rect.y, width:rect.width, height:rect.height};
    var width = window.innerWidth, height = window.innerHeight;
    var left = Math.max(0, Math.min(width, Math.round(rect.x)));
    var top = Math.max(0, Math.min(height, Math.round(rect.y)));
    var right = Math.max(left, Math.min(width, Math.round(rect.x + rect.width)));
    var bottom = Math.max(top, Math.min(height, Math.round(rect.y + rect.height)));
    // These opaque panes cover the native plane outside the preview. Keeping
    // them outside the transformed UI preserves physical viewport coordinates.
    maskPane('top', 0, 0, width, top);
    maskPane('left', 0, top, left, bottom - top);
    maskPane('right', right, top, width - right, bottom - top);
    maskPane('bottom', 0, bottom, width, height - bottom);
  }
  function resize() {
    var width = window.innerWidth, height = window.innerHeight;
    var scale = Math.max(1, Math.min(width / 1280, height / 720));
    var logicalWidth = width / scale, logicalHeight = height / scale;
    viewport.style.width = logicalWidth + 'px';
    viewport.style.height = logicalHeight + 'px';
    viewport.style.transform = 'scale(' + scale + ')';
    viewport.classList.toggle('compact-height', logicalHeight <= 760);
    viewport.classList.toggle('short-height', logicalHeight <= 560);
    viewport.setAttribute('data-ui-scale', String(scale));
    if (previewRect) setPreviewRect(previewRect);
  }
  window.TVBroSamsungViewport = {setPreviewRect:setPreviewRect};
  resize();
  window.addEventListener('resize', resize);
}());
