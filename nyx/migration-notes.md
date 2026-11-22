# Migration 2.1 -> 3.0

## ما خُفِّف عمدًا
- استجواب الملكية: من بوابة توقف إلى إقرار في التوكن + تسجيل شذوذ.
- حظر «الرفض» المطلق: من منع بلا استثناء إلى تصنيف + سلّم أربع خطوات.
- الاستمرارية: من توكن لكل فعل إلى علم في الـgrant (`persistence: true`).

## ما شُدِّد
- التنفيذ: مسار واحد `nyx-exec.sh` لا استدعاء أدوات حر.
- الأدلة: `meta.json` + sha256 + سلسلة تدقيق `prev_sha256`.
- السياسة: digests موقّعة (`seal`) + `integrity` عند كل إقلاع.
- الاختبارات: قابلة للفشل (regex + negative cases) بدل نص حر.

## تصحيحات فرضها الاختبار (v3.0 lab build)
1. `nyx-exec.sh`: كان ينفّذ `"$@"` بعد `shift` — أي `-sV` بدل `nmap -sV`.
   صار `"$TOOL" "$@"`. وبناء `--step-up` بـarray بدل `${VAR:+--step-up "$VAR"}`
   (اقتباس داخل التوسيع لا ينتج كلمتين).
2. step-up: التوكن كان `HMAC(key,"SU|nonce")[:32]` ويُتحقق منه بـ
   `HMAC(key,"SU|"+token)` — لا يتطابق أبدًا. صار `<nonce>.<mac>` ويُعاد الحساب.
3. `chattr +i`: غير متاح (لا e2fsprogs، overlayfs). البديل الموقّع:
   `/lab/etc/policy.sha256` = {sha256 للملفين, HMAC}. `integrity` يرفض أي تعديل
   بـ`deny_policy_tampered` أو `deny_seal_signature`.
4. `/lab` كان على الجذر غير الدائم. صار symlink إلى `/workspace/lab`،
   و`nyx`/`bootstrap` يعيدان إنشاءه بعد أي إقلاع.
5. `manifest.json`: كل البصمات محسوبة فعلًا بـ`nyx/seal.sh` (لا COMPUTE_AT_BUILD
   متبقٍ). التحقق: `bash nyx/seal.sh --check`.

## ما زال غير قابل للتحقق في هذه الحزمة
- `og-relay.mjs` الأصلي (هنا هيكل أدنى: healthz + Bearer + 0600 log، بلا upstream).
- `nyx-policy-mcp.py`, hooks, صورة Kali المختمومة.
