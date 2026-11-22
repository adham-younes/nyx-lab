# مؤشرات الإنتاج (تُقاس من usage.jsonl والـartifacts)

| المؤشر | التعريف | الهدف |
|---|---|---|
| signal_ratio | تأكيدات ÷ أوامر شبكية | > 0.15 |
| attempts_per_claim | محاولات ÷ ادعاء مؤكد | < 6 |
| false_positive_rate | ادعاءات نقضها المدقق ÷ الإجمالي | < 0.10 |
| time_to_first_proof | دقائق حتى أول أمر يعود من الهدف | يُقاس لكل مهمة |
| rerun_rate | تقنيات أُعيدت > 3 مرات بلا سبب جديد | 0 |
| doctrine_hit_rate | استدعاءات ناجحة ÷ إجمالي الاستدعاءات | > 0.8 |
| coverage | فرضيات مُختبرة ÷ فرضيات مطروحة | > 0.7 |

## المصدر
`/lab/state/doctrine/usage.jsonl` — سطر لكل استدعاء: `utc<TAB>hit|miss|fail<TAB>trigger`.
`doctrine.sh usage` يحسب doctrine_hit_rate من الملف مباشرة.

## قاعدة
المؤشر الذي لا يُقاس من ملف = ادعاء. `doctrine_hit_rate` قريب من الصفر يعني
أن المرجعية زينة، لا أن الفريق يعرف.
