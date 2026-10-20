# Box

AYD Works'ün müzik oynatıcısı ve dosya yöneticisi. Native SwiftUI iOS uygulaması, hostingde PHP + MySQL backend ve admin paneli.

## Klasörler

| Klasör | İçerik |
|---|---|
| `ios/` | SwiftUI uygulaması (XcodeGen ile proje üretilir, Mac gerekmez) |
| `backend/api/` | Hesap, premium, arama ve indirme linki API'si |
| `backend/admin/` | Kullanıcı yönetimi ve premium açma paneli |
| `backend/schema.sql` | MySQL tabloları |
| `.github/workflows/` | Derleme kontrolü ve TestFlight yükleme |

## 1. Backend kurulumu (hosting)

1. Hosting panelinden boş bir MySQL veritabanı ve kullanıcı oluştur.
2. phpMyAdmin'den `backend/schema.sql` dosyasını içe aktar.
3. `backend` klasörünü hostinge `box` adıyla yükle. Sonuç:
   - `https://dev.aydworks.com.tr/box/api/index.php`
   - `https://dev.aydworks.com.tr/box/admin/`
4. `box/api/config.sample.php` dosyasını aynı klasörde `config.php` olarak kopyala ve doldur:
   - Veritabanı bilgileri
   - `YT_DATA_API_KEY`: Google YouTube Data API v3 anahtarı
   - `VDS_SIGNING_KEY`: VDS'deki `/etc/yt-api.env` içindeki `YT_API_KEY` ile birebir aynı
   - `ADMIN_USERNAME` / `ADMIN_PASSWORD`: admin paneli girişi (şifre en az 10 karakter)
5. Kontrol: `https://dev.aydworks.com.tr/box/api/index.php?action=ping` → `{"ok":true,...}`

> `config.php` ilk satırda direkt `<?php` ile başlamalı, öncesinde boş satır ya da BOM olmamalı.

Başka bir adrese kurarsan `ios/Box/Core/AppConfig.swift` içindeki `apiBase` değerini değiştir.

## 2. Premium açma

`/box/admin/` adresine gir. Kullanıcıyı bul, süre seç (süresiz / 30 gün / 90 gün / 1 yıl) ve **Premium aç**'a bas. Uygulama bir sonraki açılışta ya da ön plana geldiğinde **Keşfet** sekmesini gösterir. Premium kapatılınca sekme kaybolur, sunucu da arama ve indirmeyi reddeder.

## 3. iOS derleme ve TestFlight

### Bir kerelik Apple tarafı

1. developer.apple.com → Identifiers → yeni App ID: `com.aydworks.box`
2. Profiles → **App Store** dağıtım profili oluştur (App ID: `com.aydworks.box`, mevcut Apple Distribution sertifikan), indir.
3. App Store Connect → Uygulamalar → **+** → yeni uygulama, Bundle ID `com.aydworks.box`, adı "Box" (dolu bir isimse "Box Player" gibi bir varyasyon).

### GitHub secret'ları (repo → Settings → Secrets and variables → Actions)

OtoSinyal'dekiyle aynı isimler:

| Secret | Değer |
|---|---|
| `IOS_P12_BASE64` | OtoSinyal'deki ile aynı (dağıtım sertifikası) |
| `IOS_P12_PASSWORD` | OtoSinyal'deki ile aynı |
| `IOS_PROFILE_BASE64` | **Yeni** Box profilinin base64 hali |
| `APPSTORE_KEY_ID` | OtoSinyal'deki ile aynı |
| `APPSTORE_ISSUER_ID` | OtoSinyal'deki ile aynı |
| `APPSTORE_KEY_P8_BASE64` | OtoSinyal'deki ile aynı |

Windows'ta profilin base64'ü (PowerShell):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\yol\Box.mobileprovision")) | Set-Clipboard
```

### Çalıştırma

- Her push'ta **iOS Build Check** imzasız derleyip hataları gösterir.
- **Actions → iOS TestFlight → Run workflow**: imzalar, IPA üretir ve App Store Connect'e yükler. Build numarası otomatik artar.
- Build işlendikten sonra App Store Connect → TestFlight → **Internal Testing** grubuna ekle.

> Sadece **internal** test grubunu kullan. External test (herkese açık link) Apple'ın Beta App Review incelemesinden geçer.

## Uygulama özellikleri

- **Kitaplık:** son eklenenler, çalma listeleri, beğenilenler, tüm şarkılar, kitaplıkta arama, sıralama
- **Dosyalar:** klasör oluşturma, içe aktarma, yeniden adlandırma, taşıma, silme, paylaşma; Dosyalar uygulamasında ve Finder'da "Box" olarak görünür; başka uygulamalardan "Box ile aç"
- **Oynatıcı:** arka planda çalma, kilit ekranı ve Denetim Merkezi kontrolleri, AirPlay, karıştır, tekrar, sıra düzenleme, kulaklık çıkınca durdurma
- **Hesap:** kayıt, giriş, isim değiştirme, çıkış, hesap silme
- **Keşfet (premium):** arama, tek dokunuşla m4a indirme; indirilen dosyaya başlık, sanatçı ve kapak yazılır, `İndirilenler` klasörüne kaydedilir
