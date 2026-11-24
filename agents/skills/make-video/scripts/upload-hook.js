(() => {
  if (!window.__origClick) {
    window.__origClick = HTMLInputElement.prototype.click;
    HTMLInputElement.prototype.click = function () {
      if (this.type === 'file') {
        document.querySelectorAll('#vids-upload-input').forEach(e => { if (e !== this) e.removeAttribute('id'); });
        this.id = 'vids-upload-input';
        this.style.display = 'block'; this.style.position = 'fixed'; this.style.top = '0'; this.style.left = '-10000px';
        if (!this.isConnected) document.body.appendChild(this);
        return;
      }
      return window.__origClick.apply(this, arguments);
    };
  }
  return "ok";
})()
