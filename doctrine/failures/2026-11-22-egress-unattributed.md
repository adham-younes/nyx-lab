---
id: F-001
card: OPSEC-C2-01
utc: 2026-11-22T16:07:00Z
failures: egress leak check declared PASS with non-zero counts and no PID attribution
---
## ما جُرِّب
`tcpdump` يعدّ SYNs/DNS في نافذتين: نافذة proxychains ونافذة «ضابط إيجابي» مباشر.
الحكم كان: neg==0 && pos>0 ⇒ ok.

## سبب الفشل الحقيقي
1. النص المنشور (`direct SYNs=2`) لم يُسمِّ الضابط الإيجابي، فقُرئ كتسريب.
2. لا إسناد: الحزم غير مرتبطة بـPID+cmdline، فأي حزمة غريبة تُحسب ضابطًا أو تُهمَل.
3. لم يُختبر المسار الخام أصلًا (nmap -sS/masscan) — وهذا كان P0-1 الحقيقي.

## قاعدة جديدة تُضاف للبطاقة
- عدّ > 0 ⇒ FAIL أو INVALID، لا PASS.
- كل ضابط إيجابي يُكتب بكلمة control في النص.
- اختبار التسريب يُثبت بالامتناع (deny-all + استثناء الوسيط) لا بالعدّ.
- إن لم يكن للحزمة مالك (ss -tanp / strace) ⇒ INVALID.
