(function () {
  'use strict';

  // Mobil menü
  var side = document.getElementById('side');
  var scrim = document.getElementById('scrim');
  var btn = document.getElementById('menuBtn');
  function toggle(open) {
    if (!side) return;
    side.classList.toggle('open', open);
    scrim.classList.toggle('open', open);
  }
  if (btn) btn.addEventListener('click', function () { toggle(!side.classList.contains('open')); });
  if (scrim) scrim.addEventListener('click', function () { toggle(false); });

  // Onay isteyen formlar (data-confirm)
  document.querySelectorAll('form[data-confirm]').forEach(function (form) {
    form.addEventListener('submit', function (e) {
      if (!window.confirm(form.getAttribute('data-confirm'))) e.preventDefault();
    });
  });

  // Çift gönderimi engelle
  document.querySelectorAll('form').forEach(function (form) {
    form.addEventListener('submit', function (e) {
      if (e.defaultPrevented) return;
      if (form.dataset.sent) { e.preventDefault(); return; }
      form.dataset.sent = '1';
      setTimeout(function () { delete form.dataset.sent; }, 4000);
    });
  });

  // 2FA kurulum QR kodu
  var qr = document.getElementById('qr');
  if (qr && window.QRCode) {
    new window.QRCode(qr, { text: qr.getAttribute('data-uri'), width: 180, height: 180, correctLevel: window.QRCode.CorrectLevel.M });
  }

  // Kopyala butonları
  document.querySelectorAll('[data-copy]').forEach(function (el) {
    el.addEventListener('click', function () {
      var text = el.getAttribute('data-copy');
      if (navigator.clipboard) navigator.clipboard.writeText(text);
      var old = el.textContent; el.textContent = 'Kopyalandı';
      setTimeout(function () { el.textContent = old; }, 1400);
    });
  });

  // Flash mesajını birkaç saniye sonra soldur
  var flash = document.querySelector('.flash.ok');
  if (flash) setTimeout(function () { flash.classList.add('fade'); flash.remove(); }, 6000);
})();
