# CLAUDE.md

## Продукт
Sugrob — macOS-приложение: снег идёт поверх рабочего стола и копится сугробами на верхних кромках окон и на Dock. Курсором снег смахивается («варежка»), «лопатой» убирается весь сразу. Снег можно скатать в снежки и собрать из них снеговика на окне. Клики проходят сквозь снег. Управление из строки меню: пауза, снегопад (лёгкий / ровный / метель), ветер, инструмент, «Очистить».
Вдохновлено tryflake.ru. Тексты, бренд и графика у нас свои, у Flake ничего не копируем.

Референс поведения: `~/Downloads/v1c044g50000dboq9avog65h6qdtgp10.mp4` (локально, в репозиторий не коммитим). На нём сугроб лежит на верхней кромке окна Finder, на сугробе стоит снеговик, сверху падает снег. На это видео ориентируемся при отладке визуала.

## Платформа и ограничения
- Только macOS 13+. Swift 5.9 tools, SwiftPM, AppKit + Metal. Xcode-проекта нет.
- Разработка идёт на Linux, где Swift/AppKit не собрать. **Единственная проверка сборки — CI** (`.github/workflows/macos.yml` на `macos-15`). После пуша смотрим `gh run watch` / `gh pr checks`.
- Shaders: SwiftPM CLI не компилирует `.metal`. Исходник шейдера хранится строкой в Swift и собирается в рантайме через `device.makeLibrary(source:options:)`.

## Структура
- `Sources/SnowCore/` — чистая логика симуляции: частицы, ветер, пресеты, сугробы (`Drift`), снежки, снеговик, инструменты. **Не импортировать AppKit/Metal/CoreGraphics-UI.** Только Foundation и simd. Система координат: y растёт вниз (как у CG).
- `Sources/Sugrob/` — приложение:
  - `App/` — точка входа, `AppDelegate`.
  - `Overlay/` — прозрачные click-through окна, по одному на каждый `NSScreen`.
  - `Windows/` — `WindowTracker` (опрос `CGWindowListCopyWindowInfo`, диффы окон, область Dock).
  - `Render/` — Metal-рендер.
  - `Input/` — глобальные мониторы мыши.
  - `MenuBar/`, `Settings/`.
- `Tests/SnowCoreTests/` — XCTest для `SnowCore`.
- `web/` — лендинг на Vite + TS с canvas-демо снега.
- `scripts/bundle.sh` — собирает `dist/Sugrob.app` (`LSUIElement`, подпись ad-hoc).

## Команды
```bash
swift build                 # debug
swift test                  # тесты SnowCore
./scripts/bundle.sh         # dist/Sugrob.app
cd web && npm i && npm run dev   # лендинг
```

## Git
- Всё делаем через ветки `<type>/<kebab>` (`feat/snow-core`, `fix/drift-offset`) и PR в `main`. Сливаем merge commit'ом (`gh pr merge --merge --delete-branch`) только при зелёном CI.
- Conventional Commits на английском: повелительное наклонение, строчная буква, без точки, до ~60 символов. Один коммит — одно логическое изменение. CI, docs и код коммитим раздельно.
- **Никакой атрибуции Claude**: без `Co-Authored-By`, без «Generated with Claude Code» в коммитах и PR.
- `git add` с конкретными путями, не `git add .`.

## Debug-чеклист
- **Снега не видно.** Проверить, что окно оверлея прозрачное (`isOpaque = false`, `backgroundColor = .clear`), что уровень не ниже `.statusBar`, что `collectionBehavior` содержит `.canJoinAllSpaces`. И что `MTKView.layer.isOpaque = false` с clear color alpha 0.
- **Тёмные/белые ореолы вокруг снежинок или сугробов.** Окно композитит `CAMetalLayer` как premultiplied alpha: шейдер должен возвращать `rgb * a`, блендинг `.one` / `.oneMinusSourceAlpha`. Straight alpha даёт светлую кайму на тёмном фоне.
- **Клики не проходят насквозь.** Нужен `ignoresMouseEvents = true` на оверлее. Мышь читаем только через `NSEvent.addGlobalMonitorForEvents`.
- **Сугробы сдвинуты по вертикали.** У CG начало координат сверху слева, у Cocoa снизу слева. Перевод: `cocoaY = primaryScreenHeight - cgY - height`. На нескольких мониторах ось Y считается от **главного** экрана (`NSScreen.screens[0]`).
- **Сугроб на окне, которое скрыто.** Фильтровать `kCGWindowLayer == 0` и `kCGWindowAlpha > 0`, а свои окна (`ownerPID == getpid()`) исключать.
- **Сугроб Dock во всю ширину / снег сквозь системные панели.** Включить контуры (`SUGROB_DEBUG_WINDOWS=1`): голубой прямоугольник должен обнимать плитки Dock, жёлтые — панели над окнами (Spotlight, «Приложения», баннеры). В логах `tracker` видно источник рамки Dock (`accessibility` → `window` → `preferences` → `guess`) и все окна процесса Dock (layer, bounds). Точная рамка из AX только если Accessibility уже выдан (сами не запрашиваем). При autohide и в полноэкранном Space сугроба на Dock нет. Окна слоёв 1…24 — окклюдеры: снега на них нет, но они закрывают сугробы позади; почти полноэкранная панель Dock/Spotlight прячет снег на экране целиком.
- **Варежка/лопата/снежки не реагируют.** Мышь читаем через `NSEvent.addGlobalMonitorForEvents` (+ локальный монитор для своих окон). Для событий мыши разрешение Accessibility не нужно; для клавиатурных (`keyDown`) понадобились бы Accessibility / Input Monitoring. Глобальный монитор не получает события, адресованные нашему процессу, и не поглощает их: приложение под курсором тоже получает клик и drag. Категория логов `input`.
- **Иконки нет в строке меню** → вырез экрана, открыть Sugrob повторно или ⌃⌥⌘,; «Скопировать диагностику» для отчёта. Детектор (`MenuBarController.hiddenReason`, категория `menu`) сам открывает окно настроек раз за запуск.
- **Логи.** `os.Logger(subsystem: "dev.sugrob", category: ...)`; смотреть так: `log stream --predicate 'subsystem == "dev.sugrob"' --level debug`.
- **Сборка упала в CI.** `gh run view --log-failed`.
