# MODASR VPS Migration — Private Installer

این ریپو برای انتقال کامل سایت، پنل، ربات‌ها، دیتابیس‌ها و n8n از VPS فعلی به VPS جدید است. فایل `migrate.sh` اطلاعات به‌روز را از VPS قدیمی می‌گیرد و `install.sh` همان فرایند را از روی ریپوی Private اجرا می‌کند.

## اجرای انتقال روی هر تعداد VPS

یک Fine-grained GitHub Token با مجوز **read:contents** روی همین ریپو بسازید و روی هر VPS اجرا کنید:

```bash
export GITHUB_TOKEN="YOUR_READ_ONLY_GITHUB_TOKEN"
curl -fsSL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.raw" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/modasrdorkhane11251-alt/modasr-vps-migration/contents/install.sh" | sudo -E bash
```

توکن فقط برای خواندن محتوای ریپوی Private لازم است. پسورد VPS و Tokenهای ربات‌ها داخل ریپو یا لاگ ذخیره نمی‌شوند.

## ورودی‌های لازم

- IP، یوزرنیم و پسورد SSH سرور قدیمی
- دامنه سایت و دامنه پنل/ربات
- ایمیل SSL
- شناسه عددی ادمین تلگرام و در صورت نیاز Admin ID بله، روبیکا و سروش
- Token تلگرام، بله، روبیکا و سروش‌پلاس
- انتخاب Start production services و رمز root جدید MySQL

## بررسی بدون تغییر

```bash
MIGRATE_DRY_RUN=1 bash MODASR-انتقال-به-سرور-جدید.txt
```

Dry Run هیچ دانلود، نصب پکیج، تغییر دیتابیس یا Start سرویس انجام نمی‌دهد.

## اجرای واقعی

```bash
sudo bash MODASR-انتقال-به-سرور-جدید.txt
```

اگر DNS آماده نیست، گزینه `N` برای Start انتخاب کنید و بعداً دوباره اجرا کنید. Login پنل و اطلاعات کاربران از دیتابیس قدیمی حفظ می‌شوند.

## ساخت سایت مشابه روی VPS و دامنه کاملاً جدا (Clone)

حالت `clone` برای ساخت یک نسخه مشابه با VPS و دامنه جدید است، **بدون توقف سرویس VPS اصلی**:

```bash
MIGRATION_MODE=clone sudo -E bash MODASR-انتقال-به-سرور-جدید.sh
```

در این حالت، کد، دیتابیس و فایلها به VPS جدید منتقل می‌شوند، اما دامنه، Tokenها و Admin IDهای جدید را جدا وارد کنید. سرویس و دامنه اصلی شما روشن و بدون تغییر می‌ماند و فقط نمونه جدید راه‌اندازی می‌شود. اگر Health Check نمونه جدید شکست بخورد، سرویس اصلی دست نمی‌خورد و فقط نمونه جدید متوقف می‌شود.

برای Clone نیز باید DNS دامنه و زیردامنه‌های جدید را به IP VPS جدید برسانید و SSL جدید صادر کنید. اگر هنوز آماده نیست، ابتدا انتقال را بدون Start انجام دهید و بعداً همان `MIGRATION_MODE=clone` را اجرا کنید.

## کارهای انجام‌شده

- نصب Apache، PHP، Node 20، Docker و Certbot
- دریافت کد فعلی سایت، پنل، Bot Factory، Tenantها و n8n
- Dump و Restore تمام دیتابیس‌ها و Grantهای MySQL
- تنظیم دامنه، Tokenها و Admin IDها
- صدور SSL در صورت آماده بودن DNS
- به‌روزرسانی Webhookها و Endpointهای روبیکا
- Health Check و بازگرداندن سرویس قدیمی در صورت شکست نصب جدید

## Rollback

هیچ دیتابیس یا فایل روی VPS قدیمی حذف نمی‌شود. برای بازگشت، سرویس‌های قدیمی را دوباره Start کنید:

```bash
sudo systemctl start modasr-site modasr-hosting-staging modasr-hosting-full-php modasr-hosting-tenant-1.service modasr-hosting-tenant-2.service
sudo docker start n8n
```

سپس DNS را به IP قبلی برگردانید و Webhookهای قبلی را فعال کنید.

فایلهای بررسی:

- `/var/backups/modasr-migration/all-databases.sql.gz`
- `/var/log/modasr-migrate.log`

## وضعیت تست

- Syntax و Dry Run بررسی شده‌اند.
- اجرای واقعی روی VPS جدید و Live Verify انجام نشده است.
- هیچ Secret یا بکاپ حاوی اطلاعات حساس در ریپو قرار ندارد.
