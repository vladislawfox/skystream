# SkyStream: наш iOS-форк

Тут ведемо журнал змін нашої версії та інструкцію встановлення на власний iPhone.
Технічні пояснення й історія перевірок — у [FORK.md](FORK.md).

Стан на **27 вересня 2026 року**:

| Що | Значення |
| --- | --- |
| Наш репозиторій і основна гілка | [vladislawfox/skystream](https://github.com/vladislawfox/skystream), `main` |
| Основа | [akashdh11/skystream, тег v2.8.0](https://github.com/akashdh11/skystream/releases/tag/v2.8.0) |
| Версія застосунку | **2.8.0+10**, джерело — [pubspec.yaml](pubspec.yaml) |
| Ідентифікатор застосунку | `com.vlad.skystream` |
| Перевірений телефон | iPhone 16 Pro |
| Точка відкату перед оновленням до 2.8.0 | тег `ios-v2.7.6+7-rollback`, коміт `5d804552` |

## Зібрати й установити на цьому Mac

Цей шлях використовує вже налаштовані інструменти й підписання. Для нового Mac
спочатку виконай [початкове налаштування](#початкове-налаштування-на-новому-mac).
Виконуй блоки по черзі в одному вікні Terminal. Якщо команда завершилася помилкою,
виправ її перед наступним кроком, щоб випадково не встановити стару збірку.

### 1. Вибрати оточення та отримати код

```sh
SKYSTREAM_WORKSPACE="$HOME/Documents/petlabs/iOSApp"
source "$SKYSTREAM_WORKSPACE/.local-build/env.sh"
export PATH="$SKYSTREAM_WORKSPACE/.toolchain/flutter-3.47.5/bin:$PATH"
cd "$SKYSTREAM_WORKSPACE/skystream"
flutter --version
git status --short --branch
```

Очікуємо Flutter **3.47.5** / Dart **3.13.4**. Рядок з `export PATH` потрібен:
локальний `env.sh` сам по собі вибирає старіший Flutter 3.47.1.
`env.sh` і `.toolchain` розташовані поза репозиторієм та не завантажуються з GitHub.
`$HOME` означає домашню папку поточного користувача; якщо робочий каталог
перенесено, зміни `SKYSTREAM_WORKSPACE` на його нове розташування.

Якщо `git status` показує локальні зміни, спочатку збережи їх окремим комітом.
Для чистого робочого каталогу:

```sh
git switch main && git pull --ff-only origin main
```

### 2. Підготувати залежності та зібрати застосунок

Команди виконуються з кореня `skystream`. Дужки створюють окрему оболонку,
а `set -e` зупиняє цей блок при першій помилці.

```sh
(
  set -e
  flutter pub get --enforce-lockfile
  flutter gen-l10n
  dart run build_runner build
  (cd ios && pod install)
  flutter build ios --profile --no-pub
  codesign --verify --deep --strict build/ios/iphoneos/Runner.app
)
```

Результат: **`build/ios/iphoneos/Runner.app`**. `profile` — режим, який ми
використовували для встановлених на телефон збірок; після встановлення застосунок
можна відкривати з іконки. Перша збірка довша через завантаження залежностей і VLC.

Версія береться з `version:` у `pubspec.yaml`: `2.8.0+10` означає версію `2.8.0`
і номер збірки `10`. Для наступного зміненого білду збільшуй число після `+`
та записуй його в журнал нижче. Для разового локального білду можна додати
`--build-name=2.8.0 --build-number=11` до команди збірки; це не змінює `pubspec.yaml`.

### 3. Підключити iPhone та встановити білд

Підключи телефон кабелем, розблокуй його, підтвердь довіру до Mac і залиш екран
увімкненим. Знайди телефон у списку:

```sh
xcrun devicectl list devices
```

Скопіюй його `Identifier` і заміни текст у лапках у першому рядку:

```sh
SKYSTREAM_DEVICE_ID='ВСТАВ_IDENTIFIER_СВОГО_IPHONE'
xcrun devicectl device install app --device "$SKYSTREAM_DEVICE_ID" \
  build/ios/iphoneos/Runner.app &&
xcrun devicectl device process launch --device "$SKYSTREAM_DEVICE_ID" \
  com.vlad.skystream
```

Перевірити встановлену версію:

```sh
xcrun devicectl device info apps --device "$SKYSTREAM_DEVICE_ID" \
  --filter "bundleIdentifier == 'com.vlad.skystream'"
```

Встановлення поверх застосунку з тим самим bundle ID і командою підписання
зберігає його дані. Видаляти старий застосунок перед оновленням не потрібно.
Якщо встановлення пройшло, але запуск повідомляє про заблокований телефон,
розблокуй його й відкрий SkyStream з іконки або повтори лише команду `process launch`.

## Початкове налаштування на новому Mac

Перевірене оточення: **Apple Silicon, Xcode 27.0, Flutter 3.47.5 / Dart 3.13.4,
CocoaPods 1.17.0**. Мінімальна версія iOS у проєкті — **15.6**.

1. Установи Xcode, відкрий його й заверши початкове налаштування, включно з iOS
   platform support. У **Xcode → Settings → Accounts** додай свій Apple Account.
   Якщо командні інструменти вибирають інший Xcode, виконай
   `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.
   [Інструкція Flutter для iOS](https://docs.flutter.dev/platform-integration/ios/setup).
2. Завантаж Flutter **3.47.5** для своєї архітектури з
   [архіву SDK](https://docs.flutter.dev/install/archive), розпакуй, наприклад,
   у `$HOME/Developer/flutter-3.47.5` і додай до шляху:

   ```sh
   export PATH="$HOME/Developer/flutter-3.47.5/bin:$PATH"
   flutter precache --ios
   ```

3. Установи CocoaPods у сучасному Ruby. Якщо використовуєш Homebrew, команди нижче
   встановлюють окремий Ruby та CocoaPods у користувацький каталог.
   Додаткові варіанти — в [інструкції CocoaPods](https://guides.cocoapods.org/using/getting-started.html).

   ```sh
   brew install ruby
   export PATH="$(brew --prefix ruby)/bin:$PATH"
   gem install --user-install cocoapods -v 1.17.0
   export PATH="$(ruby -r rubygems -e 'puts Gem.user_dir')/bin:$PATH"
   pod --version
   flutter doctor -v
   ```

   Збережи відповідні рядки `export PATH` у `~/.zshrc`, щоб вони діяли в нових
   вікнах Terminal. Для iOS потрібні справні Xcode і CocoaPods; Android SDK для
   цієї збірки не потрібен.
4. Склонуй саме наш форк у вибрану папку:

   ```sh
   git clone https://github.com/vladislawfox/skystream.git
   cd skystream
   git remote add upstream https://github.com/akashdh11/skystream.git
   flutter pub get --enforce-lockfile
   flutter gen-l10n
   dart run build_runner build
   (cd ios && pod install)
   open ios/Runner.xcworkspace
   ```

5. У Xcode вибери **Runner → Signing & Capabilities**, увімкни
   **Automatically manage signing** і вибери свою **Team**. Для нашого наявного
   встановлення збережи `com.vlad.skystream` та ту саму команду підписання.
   Інший розробник має вибрати власну Team та унікальний bundle ID; тоді заміни
   bundle ID і в командах запуску/перевірки. Для запуску тестів налаштуй також
   підписання `RunnerTests`.
6. Підключи й розблокуй iPhone, підтвердь **Trust / Довіряти**. Увімкни
   **Settings → Privacy & Security → Developer Mode**, перезавантаж телефон
   і підтвердь увімкнення. Дочекайся завершення підготовки пристрою в Xcode.
   [Налаштування пристрою у Flutter](https://docs.flutter.dev/platform-integration/ios/setup#set-up-an-ios-device).
7. Повернися в Terminal до кореня цього клону та виконай кроки **2–3** вище.
   На новому Mac локальний `env.sh` зі старого Mac не потрібний.

`TorrServer.xcframework` уже є в Git, а MobileVLCKit завантажує CocoaPods через
[локальний podspec](ios/vendor/MobileVLCKit.podspec.json). Для звичайної iOS-збірки
окремо запускати `scripts/build_ios_framework.sh` не потрібно.
Зберігай локальний `ios/Podfile.lock` між збірками: він ігнорується Git.
Для повторної збірки використовуй `pod install`; `pod update` змінює залежності.

Базова збірка не потребує приватних API-ключів. Для функцій сторонніх сервісів
потрібне їхнє налаштування; зокрема власний TMDB-ключ можна вказати в Settings.

## Якщо збірка або запуск не вдалися

| Симптом | Що перевірити |
| --- | --- |
| `flutter` / `pod`: command not found | Виконай налаштування `PATH` у поточному Terminal. |
| Невідповідна версія Dart або помилки залежностей | `flutter --version` має показувати 3.47.5 / Dart 3.13.4; перевір порядок каталогів у `PATH`. |
| Немає `*.g.dart` / помилки згенерованого коду | Після `flutter pub get` виконай `flutter gen-l10n` і `dart run build_runner build`. |
| Помилка `Generated.xcconfig` / Pods | Спочатку `flutter pub get`, потім `(cd ios && pod install)` з кореня репозиторію. Відкривай `Runner.xcworkspace`. |
| `No profiles`, `requires a development team`, помилка сертифіката | Відкрий workspace у Xcode, перевір Apple Account, Team, automatic signing та вибраний iPhone. Дозволь доступ до ключа підписання, якщо macOS запитує. |
| iPhone відсутній або unavailable | Перевір кабель, довіру, Developer Mode та стан пристрою в Xcode; повтори `devicectl list devices`. |
| Встановилося, але не запускається | Розблокуй телефон. Якщо iOS просить довіряти розробнику, перевір Settings → General → VPN & Device Management. |
| Після певного часу білд перестав відкриватися | Перевір строк дії підписання у Xcode та перебудуй/перевстанови застосунок із чинним профілем. |

## Українські провайдери

Код провайдерів ведемо окремо в
[skystream-ukrainian](https://github.com/vladislawfox/skystream-ukrainian).
У SkyStream відкрий **Settings → Extensions → Add Repository** і додай:

```text
https://raw.githubusercontent.com/vladislawfox/skystream-ukrainian/main/repo.json
```

На 27.09.2026 опубліковано 15 провайдерів: UAKino, UAFlix, UASerialsPro,
KinoVezha, Eneyida, KinoTron, KlonTV, Serialno, SimpsonsUA, CikavaIdeya,
UFDub, BambooUA, DoramyWorld, Kinostrain та RezkaTV.
Оновлення `.sky` встановлюються через репозиторій розширень. Новий білд застосунку
потрібен, коли провайдер вимагає змін у самому SkyStream, як підтримка Anubis для RezkaTV.

## Журнал змін форку

Нові записи додаємо зверху. Для кожної зміни зазначаємо дату, версію/номер білду,
що змінилося для користувача, коміт і фактично виконані перевірки. Окремо
позначаємо очікувану перевірку на телефоні. Зміни лише документації не потребують
нового номера білду. Під час оновлення версії оновлюємо також таблицю на початку.

### 2026-09-27 — документація форку

- Додано цей журнал і ручну інструкцію збірки/встановлення на iPhone.
- Команди звірено з локальним SDK, Xcode та попередньою успішною збіркою 2.8.0+10.
  Для зміни документації застосунок повторно не збирався.

### 2026-09-27 — 2.8.0+10: RezkaTV

- Додано обробку браузерної перевірки Anubis у системному WebView та повтор
  початкового запиту після неї. Це дає змогу працювати новому провайдеру RezkaTV.
- Провайдер опубліковано в окремому репозиторії; перевірено каталог, пошук,
  фільм і «Стрілу», S1E15, включно з отриманням HLS-плейлистів.
- Перевірки застосунку: 1923 тести пройшли, 6 умовних пропусків, аналіз без помилок.
  Підписаний білд установлено на iPhone; автоматичний запуск зупинився через
  заблокований екран. Це ще не підтвердження перегляду RezkaTV на телефоні.
- Коміт: [00345a50](https://github.com/vladislawfox/skystream/commit/00345a50).

### 2026-09-27 — 2.8.0+9: надійніше завантаження серіалів

- Усунено зайве обмеження паралельності HLS-завантажень; збережено ліміт двох
  одночасних запитів до одного хоста.
- Помилкове завантаження залишається в Library з причиною та кнопкою Retry.
  Повторна спроба використовує готові сегменти й докачує відсутні, зокрема після
  перезапуску застосунку. Старе завдання не може видалити нове завантаження.
- Додано регресійні перевірки черги, відновлення та кнопки Retry; зміни увійшли в `main`.
- Коміти: [9248b133](https://github.com/vladislawfox/skystream/commit/9248b133),
  [7431d7e1](https://github.com/vladislawfox/skystream/commit/7431d7e1).

### 2026-09-27 — 2.8.0+8: оновлення основи

- Об'єднано upstream `v2.8.0` із нашими змінами мережі, PiP, завантажень і підписання.
- На iOS збережено регулювання гучності VLC, щоб новий upstream-контролер
  системної гучності не змінював аудіосесію під час PiP.
- Пройшли 1897 тестів застосунку, 296 тестів VLC-пакета і 9 тестів на iPhone.
  Білд установлено; користувач підтвердив, що після оновлення загалом усе працює.
- Коміт: [d1132e78](https://github.com/vladislawfox/skystream/commit/d1132e78).

### 2026-09-27 — 2.7.6+7: гучність PiP та офлайн HLS

- Зберігається остання коректна гучність, коли VLC тимчасово не може її визначити.
  Жести біля системних країв екрана не змінюють гучність плеєра.
- Замість збереження лише маленького `.m3u8` завантажуються сегменти відео,
  аудіо та інші потрібні ресурси. Розмір плейлиста більше не показується як розмір серії.
- Перевірено відтворення завантаженого HLS без мережі та збереження гучності
  при реальному вході/виході з PiP на iPhone.
- Коміт: [5d804552](https://github.com/vladislawfox/skystream/commit/5d804552),
  точка відкату — `ios-v2.7.6+7-rollback`.

### 2026-09-19 — 2.7.6+3 → +5: Picture in Picture та зображення

- Додано нативний PiP зі збереженням потоку, позиції й керування відтворенням.
- Виправлено мерехтіння/стрибки у звичайному плеєрі та тонку зелену смужку
  внизу відео у звичайному режимі й PiP.
- Пройшли тести на реальному iPhone; користувач підтвердив плавне зображення
  у +4 і прийняв виправлення зеленої смужки у +5.
- Коміти: [b8380c33](https://github.com/vladislawfox/skystream/commit/b8380c33),
  [8672eae9](https://github.com/vladislawfox/skystream/commit/8672eae9),
  [5794ab5c](https://github.com/vladislawfox/skystream/commit/5794ab5c),
  [e0e7c731](https://github.com/vladislawfox/skystream/commit/e0e7c731).

### 2026-09-17 — початкові зміни на основі 2.7.6

- Запити провайдерів і зображень на Apple переведено на нативний URLSession:
  виправлено спостережувані помилки завантаження UAKino.
- Виправлено кнопку Play у фільмах, для яких провайдер не повертає список епізодів.
- Екран наявних логів доступний у profile/release; налаштовано персональне підписання iOS.
- Пройшли перевірки мережі й деталей; користувач підтвердив роботу UAKino на iPhone.
- Коміти: [03c2c820](https://github.com/vladislawfox/skystream/commit/03c2c820),
  [33721edd](https://github.com/vladislawfox/skystream/commit/33721edd),
  [e989ade2](https://github.com/vladislawfox/skystream/commit/e989ade2),
  [9bb39324](https://github.com/vladislawfox/skystream/commit/9bb39324).

## Як надалі оновлювати основу й мати точку відкату

Перед інтеграцією нового upstream зберігаємо наші зміни комітом у `main` і пушимо
їх на GitHub. Для прийнятої збірки створюємо й пушимо окремий тег. Новий стабільний
тег upstream об'єднуємо через `git merge` в окремій гілці від нашого `main`.
Після перевірок і тесту на телефоні переносимо результат у `main` та додаємо запис
сюди. Послідовність Git-команд — у [FORK.md](FORK.md#updating-from-upstream).

Для відкату збираємо потрібний тег в окремому checkout із відповідним йому SDK;
для `ios-v2.7.6+7-rollback` це Flutter **3.47.1**. Тег зберігає вихідний код;
готовий білд може потребувати нового підписання. Відкат застосунку не відкочує
автоматично його дані, тому сумісність старої версії з ними перевіряємо окремо.
Історію спільного `main` не переписуємо через `reset --hard` / force-push.
