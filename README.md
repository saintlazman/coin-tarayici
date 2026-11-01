# Saatlik coin tarayıcı

Deneysel Binance spot tarayıcısı. Emir vermez. Adaylarda OI ve fonlama verilerini ek bilgi olarak gösterir. Başarı oranı ölçülmemiştir.

## Kurulum

1. Bu klasörün içeriğini (gizli `.github` klasörü dahil) GitHub deposunun köküne yükleyin. ZIP dosyasının kendisini yüklemeyin.
2. Settings → Secrets and variables → Actions → New repository secret altında `TELEGRAM_BOT_TOKEN` ve `TELEGRAM_CHAT_ID` ekleyin. Anahtarları kod dosyasına yazmayın.
3. Telegram'da kendi botunuza `/start` gönderin. Chat ID bot anahtarıyla `getUpdates` üzerinden belirlenebilir; bot anahtarını sohbetlere veya ekran görüntülerine koymayın.
4. Actions → Saatlik coin taramasi → Run workflow ile önce bağlantı testi yapın. Başarılı çalışmayı ve Telegram test mesajını doğrulamadan otomasyon tamamlandı sayılmaz.

Her saatin 7. dakikasında çalışmak üzere ayarlanmıştır; GitHub zamanlaması gecikebilir veya yoğunlukta atlanabilir. Public depolarda 60 gün etkinlik olmazsa zamanlama durabilir. Cache silinirse aynı aday yeniden bildirilebilir. Kayıtlar bu sürümde her çalışmada kalıcı arşivlenmez; sadece bildirim durumu cache ile taşınır. Actions özeti tarama kapsamını gösterir.

Binance erişimi GitHub sunucusunun bölgesine göre engellenebilir. Böyle bir durumda sonuç üretmek yerine çalışma hata verir; bölgesel erişim kısıtını aşma girişimi yapmaz. Önce gerçek GitHub çalışmasında erişimi doğrulayın.

Public depolarda standart runner çalıştırması ücretsizdir. Private depolar plan kotasını tüketir. Ücretli ek kullanım açmadan önce hesap limitlerini kontrol edin. Bu dosyalar hazırlık paketidir; tek başına bulutta etkin değildir.

Kurallar: >=10M USDT günlük hacimde en yüksek hacimli 60 spot USDT paritesi; BTC'ye göre 4 saatte >=0,5 puan güç, saatlik hacim >=1,5 kat, önceki 6 saatlik aralık <=%4, son saatlik getiri <%5 ve 24 saatlik getiri <%12. Kapanış önceki 6 saatlik tepeyi aşarsa KIRILMA; en fazla %1 altındaysa ve saatlik getiri pozitifse İZLE. OI eleme şartı değildir.
