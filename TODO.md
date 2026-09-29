# ayTELE — خارطة الميزات العميقة (TODO)

> آخر تحديث: 2026-09-29 · الهدف: تيليگرام iOS **12.9.4** (build 34639) · الفرع: `ci-test`
>
> كل معلومة بهالملف **متحقق منها** من: بايناري تيليگرام 12.9.4 (`*AppAssassin.ipa`)، سكيمة TL بالمشروع (`api_sources/`)، AorusGram، وTGExtra.
> اللي ما انتحقق منه مكتوب عليه **«⚠️ يُتحقق على الجهاز»**.

---

## 📊 الملخص

| # | الميزة | الأولوية | المخاطرة | المسار المقترح | الحالة |
|---|---|---|---|---|---|
| 1 | **زر تحميل الستوري** | 🔴 لازم | 🟡 متوسطة | TL أولاً ← ثم زر بالعارض | ⏳ |
| 2 | حفظ الوسائط المؤقتة / العرض لمرة واحدة | 🟠 عالية | 🟡 متوسطة | اختبار التوگل الموجود ← ثم TL | ⏳ |
| 3 | ميزة «العين» (شوف بصمت + زر كشف) | 🟠 عالية | 🟢 منخفضة (رسائل) · 🟡 (قصص) | طابور إيصالات + إعادة إرسال ObjC | ⏳ |
| 4 | (إضافي) إخفاء عدّاد مشاهدة القصص | 🟢 سهلة | 🟢 منخفضة | TL (نفس نمط FunctionHandler) | ⏳ |

**مفتاح المخاطرة:** 🟢 طبقة TL / واجهتنا فقط — مستحيل شاشة سودة · 🟡 يلمس بيانات تيليگرام أو عقدة واجهة · 🔴 حقن داخل عارض Swift.

---

## 🛡️ قواعد عدم الكسر (تنطبق على كل ميزة)

1. **كل ميزة خلف توگل، افتراضياً OFF** — مطفّي = التلي نفس الأصل بالضبط.
2. **ترتيب المسارات:** طبقة TL أولاً (مثبتة، ما تلمس الرسم) ← واجهتنا (UIAlertController/شاشاتنا) ← وآخر شي حقن بعارض تيليگرام.
3. **صفر `force unwrap`** بكود reflection؛ كل وصول لعقدة/خاصية داخل `@try` أو `guard`.
4. **ميزة وحدة لكل build** — تنبني بـ CI، تنجرّب على الجهاز، بعدين الجاية.
5. لا نغيّر `pts`/`pts_count` بأي رد (نفس مبدأ `AYDeletedFilter`) — وإلا تيليگرام يسوي refetch.
6. قبل أي هوك جديد: نتأكد الكلاس موجود بالبايناري (`strings | grep _TtC...`) ونسجّله هنا.

---

## 🔬 نتائج البحث (مرجع ثابت)

### أرقام دوال TL (من `Api38` بالمشروع)
| الدالة | constructor | نوع الرد | موجود بالكود؟ |
|---|---|---|---|
| `stories.readStories` | `-1521034552` | `Vector<int>` | ✅ `kStoriesReadStories` |
| `stories.incrementStoryViews` | `-1308456197` | `Bool` | ❌ |
| `stories.activateStealthMode` | `1471926630` | `Updates` | ❌ (Premium فقط) |
| `stories.getPeerStories` | `743103056` | `stories.PeerStories` | — |
| `stories.getStoriesByID` | `1467271796` | `stories.Stories` | — |
| `messages.readHistory` | `238054714` | `messages.AffectedMessages` | ✅ `kMessagesReadHistory` |
| `channels.readHistory` | `-871347913` | `Bool` | ✅ `kChannelsReadHistory` |
| `messages.readMessageContents` | `916930423` | `messages.AffectedMessages` | ✅ |
| `channels.readMessageContents` | `-357180360` | `Bool` | ✅ |

### أعلام TL (flags) ذات صلة
- `storyItem#79b26a24` (`2041735716`) — `noforwards` = **flags.10** (علم منطقي بدون حقل). `parse_storyItem` بـ `Api26.swift` **ما يمسحه حالياً** (بعكس الرسائل اللي يمسح `noforwards` bit 26 بـ `Api15.swift:151`).
- `messageMediaPhoto` / `messageMediaDocument` — `ttl_seconds` = **flags.2** (حقل Int32)، متحقق من `Api16.swift` (`parse_messageMediaPhoto` / `parse_messageMediaDocument`).

### كلاسات عارض القصص (ObjC-visible، قابلة للهوك)
- `_TtCC20StoryContainerScreen30StoryItemSetContainerComponent4View` — الحاوية الرئيسية (UIView ← `layoutSubviews`).
- `_TtCC20StoryContainerScreen25StoryItemContentComponent4View` — محتوى الستوري.
- `_TtC20StoryContainerScreen18StoryItemImageView` — عرض الصورة (UIView).
- `_TtCC20StoryContainerScreen21StoryActionsComponent4View` — شريط الأزرار.
- المكوّن يحمل closure اسمه `markAsSeen` (مؤكد من AorusGram) — مسار تيليگرام نفسه لتعليم الستوري «مشاهد».

### الشبكة (ObjC — بدون جدار Swift) ✨
- `MTRequest` و`MTRequestMessageService` **كلاسات ObjC مُصدّرة** بـ `MtProtoKitFramework` وفيها: `setPayload:metadata:shortMetadata:responseParser:` · `setCompleted:` · `addRequest:`.
- **النتيجة:** نگدر **نعيد إرسال** أي طلب TL محفوظ من ObjC مباشرة → هذا يفك «جدار الإرسال» لحالة الإيصالات.

### ملفات الميديا (Postbox media box)
- أسماء الموارد: `telegram-cloud-document-…` · `telegram-cloud-document-size-…` · `telegram-cloud-photo-size-…` داخل مجلد `media`.
- ⚠️ يُتحقق على الجهاز: المسار الكامل (`<container>/telegram-data/account-<id>/postbox/media/`) — وخصوصاً مع `CloneFix` اللي يحوّل app-group لمجلد محلي.

### مراجع خارجية
- **AorusGram:** عنده «تنزيل القصص»، `AorusStealthCodec`، `saveStorySource(engine:item:peerId:id:)` — Swift داخلي، نستأنس بالمنطق فقط.
- **TGExtra:** طبقة TL ObjC شبيهة بـ ayTELE (`TLStoryItem`, `TLStoriesStealthMode`, `IncrementStoryViews`) — يأكد إن حجب القصص يصير بطبقة TL.

---

## 1) 🔴 زر تحميل الستوري — **لازم نسويه**

**الهدف:** تنزيل صورة/فيديو أي ستوري للاستوديو.

### المرحلة A — فتح الحفظ الأصلي بطبقة TL (🟢 منخفضة)
- بـ `parse_storyItem` (`Api26.swift`) امسح **bit 10** من `flags` بعد القراءة، بنفس نمط `Api15.swift:151`، ومربوط بتوگل (مثل `kDisableForwardRestriction` أو توگل جديد `kStoryAllowSave`).
- النتيجة المتوقعة: يرجع خيار **«حفظ بالاستوديو»** الأصلي بقائمة الستوري حتى للقصص المحمية.
- ⚠️ يُتحقق على الجهاز: هل تيليگرام يطلب **Premium** لحفظ قصص الغير؟ إذا نعم → ننتقل للمرحلة B.
- ⚠️ حدّ معروف: الردود تمر بـ `TLParser` بس لما (`kDisableForwardRestriction` أو `keepDeleted` أو `editHistory`) مفعّل؛ وتحديثات `updateStory` المدفوعة تمر بـ `parseMessage` مو `TLParser`.

### المرحلة B — زر خاص بعارض القصص (🟡)
1. هوك `layoutSubviews` على `StoryItemSetContainerComponent.View` وإضافة زر ⬇️ (subview مالنا، مثل شارات `DeletedBadge.xm`).
2. **صورة:** نسحب الصورة المعروضة من `StoryItemImageView` (أبسط وأأمن).
3. **فيديو:** نوصل لـ `media` عبر reflection على `component` → معرّف المورد → ملف بالـ media box → `PHPhotoLibrary`.
4. حفظ بـ `PHPhotoLibrary` (يحتاج `NSPhotoLibraryAddUsageDescription` — موجود أصلاً بتيليگرام).

### معايير القبول
- [ ] صورة ستوري تنحفظ بالاستوديو.
- [ ] فيديو ستوري ينحفظ كامل (مو جزء partial).
- [ ] التوگل OFF = العارض بالضبط مثل الأصل.
- [ ] ما يطلع أي إيصال مشاهدة إضافي بسبب التحميل.

---

## 2) 🟠 حفظ الوسائط المؤقتة / العرض لمرة واحدة

### الخطوة 0 — اختبار الموجود أولاً (بدون كود)
- شغّل **«تعطيل إيصال مشاهدة الوسائط»** (`kDisableReadMessageContents`، بقسم وضع الشبح) وافتح رسالة عرض-لمرة.
- سجّل: تنفتح؟ تبقى بعد الإغلاق؟ يوصل المرسِل إشعار؟ → النتيجة تحدد الخطوة الجاية.

### المسار A — مسح `ttl_seconds` بطبقة TL (🟡)
- بـ `parse_messageMediaPhoto` / `parse_messageMediaDocument` امسح **bit 2** بعد القراءة → الوسيط يصير عادي دائم وقابل للحفظ.
- ⚠️ الرسائل الجديدة المدفوعة تمر بـ `parseMessage` (بدون إعادة تسلسل)؛ تعميمها يحتاج reserialize لكل التحديثات = مخاطرة أعلى. نبدأ بالردود (RPC) بس.
- ⚠️ المحادثات السرية (encrypted) خارج النطاق.

### المسار B — زر حفظ بعارض الوسيط
- بعد المسار A، نفس منطق زر الستوري (صورة من العارض / ملف من media box).

---

## 3) 🟠 ميزة «العين» — شوف بصمت + زر كشف

**السلوك المتفق عليه:** الإيصالات محجوبة افتراضياً؛ زر العين **يكشف يدوياً** إنك شفت عنصر/محادثة محددة.

### المعمارية (بدون جدار Swift)
1. **طابور إيصالات:** بـ `Hooks.xm` لما نحجب `messages.readHistory` / `channels.readHistory` / `stories.readStories`، نحفظ **`payload` الكامل + مرجع ضعيف لـ `MTRequestMessageService`** بقاموس مفتاحه الـ peer (آخر `max_id` يكفي).
2. **الكشف:** زر العين ← ننشئ `MTRequest` جديد من ObjC بنفس الـ payload ← `setCompleted:` ← `addRequest:` على نفس الـ service.
3. **منع الحلقة:** علم bypass (static/associated) يخلي `setPayload` hook ما يحجب الطلب المُعاد.
4. **تعدد الحسابات:** الـ service محفوظ مع كل عنصر بالطابور، فكل كشف يروح لحسابه الصحيح.

### الواجهة
- **الرسائل (🟢):** خيار **«👁️ كشف القراءة»** بقائمة الضغطتين بإصبعين الموجودة (`AYMessageActionHandler`) — UIAlertController مالنا، آمن 100%.
- **القصص (🟡):** زر 👁️ بـ `StoryItemSetContainerComponent.View` (نفس هوك زر التحميل).

### معايير القبول
- [ ] مع الحجب: الطرف الثاني ما يشوف «مقروء/مشاهد».
- [ ] بعد الكشف: يشوفها مقروءة/مشاهدة فوراً.
- [ ] الطلب المُعاد ما ينحجب مرة ثانية ولا يدخل حلقة.

---

## 4) 🟢 (إضافي) إخفاء عدّاد مشاهدة القصص

- حجب `stories.incrementStoryViews` (`-1308456197`، رد `Bool` ← `boolTrue()`) بـ `FunctionHandler.m`، مربوط بـ `kDisableStoriesReadReceipt` أو توگل جديد.
- ⚠️ يُتحقق: متى تيليگرام يرسله بالضبط (قنوات/عام).
- ملاحظة: `stories.activateStealthMode` هو «الوضع الخفي» الرسمي لكنه **Premium فقط** — ما نعتمد عليه.

---

## 🧪 بروتوكول الاختبار على الجهاز (لكل build)

1. تشغيل التلي: يقلع بدون كراش (وخصوصاً مع `CloudKitGuard`).
2. التوگل **OFF**: الميزة ما تبين نهائياً.
3. التوگل **ON**: السيناريو الأساسي يشتغل.
4. حساب ثاني (أو صديق) يتأكد من جهة الطرف الآخر (مقروء/مشاهد/إشعار).
5. أي كراش → ملف `.ips` يندز فوراً ونحلله قبل أي ميزة جديدة.

---

## ✅ اننجز (مرجع)

- إيصال مشاهدة الوسائط الصامت (voice / video-note / view-once) — صار بقسم وضع الشبح.
- بيانات الميديا (أبعاد / GPS) بشاشة المعلومات + نسخ بضغطتين.
- حارس كراش CloudKit للتثبيت الجانبي (`CloudKitGuard.xm` — فحص الصلاحية بـ SecTask).
- تتبّع لغة الجهاز (افتراضي عربي) + تصميم داكن بألوان تيليگرام + مدخل من صف «الدعم».
