# SPIC VPN Client

Кроссплатформенный клиент для коммерческого VPN‑сервиса, построенный на Flutter.  
Поддерживаются мобильные и десктопные платформы: Android, iOS, Linux, Windows (другие платформы по мере развития проекта).

> Внимание: репозиторий содержит **только клиент**. Доступ к коммерческому VPN‑сервису и реальные токены/ключи в репозитории не хранятся.

---

## Возможности

- Подключение к коммерческому VPN‑сервису через защищённый туннель.
- Единая кодовая база на Flutter для мобильных и десктопных ОС.
- Базовый интерфейс для:
  - выбора сервера;
  - подключения/отключения VPN;
  - отображения статуса соединения.
- Архитектура, позволяющая переиспользовать сетевой клиент (TrustTunnel) в других приложениях.

*(Список фич можно расширять по мере разработки.)*

---

## Поддерживаемые платформы

- Android
- iOS
- Linux (desktop)
- Windows (desktop)

Поддержка конкретных версий ОС и архитектур может отличаться и зависит от ограничений Flutter и сторонних зависимостей [web:621][web:620].

---

## Быстрый старт для разработчиков

### Требования

- Flutter SDK (актуальная стабильная версия)
- Dart SDK (идёт вместе с Flutter)
- Android Studio / VS Code / IntelliJ IDEA (по желанию)
- Для сборки:
  - Android: Android SDK + эмулятор или реальное устройство
  - iOS: Xcode + macOS (для сборки и запуска на устройстве/симуляторе)
  - Windows: установленный toolchain для Windows (MSVC)
  - Linux: необходимые dev‑пакеты для Flutter desktop

### Установка зависимостей

```bash
flutter pub get
Запуск
Android:

bash
flutter run -d android
Windows:

bash
flutter run -d windows
Linux:

bash
flutter run -d linux
iOS (на macOS):

bash
flutter run -d ios
Конфигурация VPN/секретов
Проект не должен содержать реальные токены, ключи и конфигурации для доступа к коммерческому VPN.

Рекомендуемый подход:

Локальный файл с токеном (пример):

text
lib/token_trusttunnel.txt
этот файл должен быть добавлен в .gitignore и не попадать в репозиторий.

В репозитории можно хранить только пример:

text
lib/token_trusttunnel.example.txt
с описанием формата, но без реальных значений.

Токены и ключи передаются разработчикам и пользователям по отдельным безопасным каналам.

Архитектура (кратко)
lib/ – основной код приложения на Dart/Flutter:

UI‑слой (экраны, виджеты);

логика подключения к VPN через TrustTunnel‑клиент;

вспомогательные сервисы и утилиты.

Платформенные директории:

android/, ios/, linux/, windows/, macos/ – стандартная структура Flutter, минимальные платформенные обвязки.

Подробное описание архитектуры и отдельных модулей может быть добавлено позже.

Планы
Улучшенный UI (список серверов, фильтры, избранное).

Индикация загрузки/пинга/трафика.

Логи и диагностика подключений.

Настройки протоколов/портов (если поддерживается сервером).

Локализация интерфейса.

Лицензия
Apache-2.0

Отказ от ответственности
SPIC является клиентом для подключения к стороннему коммерческому VPN‑сервису.
Автор репозитория не несёт ответственности за использование сервиса и соблюдение законодательства в конкретной юрисдикции.
## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
