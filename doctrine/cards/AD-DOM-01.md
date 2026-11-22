---
id: AD-DOM-01
triggers: [kerberos, asrep, ad_delegation, domain_joined]
phase: 2-3
timebox_min: 50
---
## الهدف القابل للقياس
«أي مسار في النطاق يمنح حقًا إضافيًا، بأقل كلفة وأقل ضجيج؟»

## الأسبقية الاقتصادية
1. تعداد بلا اعتماد: null session، LDAP anonymous، SMB guest.
2. AS-REP roasting: حسابات بلا preauth — كلفة منخفضة، ضجيج منخفض.
3. Kerberoasting: SPN لحسابات خدمة — كلفة كسر تعتمد على قوة كلمة الخدمة.
4. ACLs: من يملك GenericAll/WriteDACL/ForceChangePassword على من.
5. Delegation: unconstrained أوسع أثرًا من constrained؛ ابدأ بالمقيّد.
6. بعد الاعتماد فقط: مسارات DCSync/Shadow Credentials داخل الحدود.

## أرخص مُميِّز
`GetUserSPNs`/AS-REP بلا اعتماد + قراءة ACL واحدة. يحسم وجود المسار قبل أي كسر.

## ما يُبطل الفرضية
- لا SPN، لا AS-REP، ACLs نظيفة، delegation معطّل = النطاق مقفل؛ انتقل للمضيف.
- كل الحسابات بكلمات قوية + لا مسار كتابة = لا تصعيد أفقي.

## أخطاء شائعة
- كسر SPN ضعيف ثم عدم استخدامه (كلفة بلا بتّ).
- بدء unconstrained delegation قبل قراءة ACL (ضجيج عالٍ).
- نسيان أن الوقت/الضجيج جزء من الكلفة.

## الدليل المطلوب
تذكرة/هاش، الحساب، المسار، وأثر كل طلب على السجلات.

## مدة الحظر
50 دقيقة بلا مسار مفتوح = سجّل وأعد الترتيب بالكلفة.
