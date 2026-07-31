# Baldur's Gate 3 как хост для Graph A11y Kernel — исследование выполнимости и список требований

**Статус**: черновик 1 (2026-07-29)
**Предмет**: порт архитектуры из `graph-a11y-spec.md` (RTAccess / WrathAccess / Factorio Access)
на Baldur's Gate 3, Patch 8.
**Установленная копия**: `G:\SteamLibrary\steamapps\common\Baldurs Gate 3`, билд `4.1.1.7209685`,
`modsettings.lsx` версии `4.8.0.700`, модов не установлено.

---

> **Обновление 2026-07-29**: эксперименты §9 проведены на живой игре, результаты и поправки к
> оценке — в [experiment-results.md](experiment-results.md). Главные изменения: P1 подтверждён,
> `ICommand` в BG3 не существует (P2 сузился до двух путей), задержка речевого моста измерена
> и годится, четыре пробы ждут загруженного сохранения.

## 0. Вердикт

**BG3 — жизнеспособный хост.** Из шести пунктов чек-листа §10.2 спеки пять закрываются
официальным API Script Extender'а без реверс-инжиниринга, шестой (итерация) закрывается лучше,
чем в Unity-проектах — у SE есть живой Lua-REPL в игре и горячая перезагрузка Lua-состояния.

Единственный по-настоящему отсутствующий порт — **P5 (речь)**. В Lua-песочнице SE нет ни FFI, ни
`package.loadlib`, ни сокетов, поэтому `prism.dll`-подход из RTAccess напрямую не переносится:
между Lua и Tolk нужен мост через отдельный нативный компонент. Это единственная часть проекта,
где придётся писать C++ и делать архитектурный выбор (§6).

Второй по величине структурный отличитель от Unity-хостов: **BG3 всегда клиент-сервер**, даже в
одиночной игре, и это два полностью изолированных Lua-состояния. UI и ввод живут только на клиенте,
Osiris и авторитетное состояние мира — только на сервере. Ядро графа и навигатор целиком уезжают на
клиент; всё, что меняет мир (движение, использование предметов, каст), проходит через
NetChannel-запрос на сервер. Это не блокер, но это влияет на каждый drive-path и добавляет
асинхронность туда, где в RTAccess был прямой вызов.

---

## 1. Что реально лежит в папке игры (факты)

| Путь | Что это | Зачем нам |
|---|---|---|
| `bin\bg3.exe` (102 МБ), `bin\bg3_dx11.exe` | Vulkan- и DX11-сборки | Сюда инжектится SE (`DWrite.dll`) и нативные плагины |
| `bin\Osiris.dll` | Рантайм Osiris (сюжетный VM) | SE перехватывает его ради `Osi.*` |
| `bin\SDL2.dll` | Ввод идёт через SDL2 | Отсюда `SDLScanCode` в API SE — коды клавиш будут SDL'ные, не VK |
| `Data\Gustav.pak` (12.6 ГБ), `Gustav_NavCloud.pak` (91 МБ) | Основная кампания + навигационные сетки | NavCloud — та самая AiGrid, по которой считается путь |
| `Data\Game.pak`, `Shared.pak` | UI (XAML/Noesis), скрипты, шаблоны | Здесь лежат все `.xaml`, которые придётся читать при написании screen recipes |
| `Data\Localization\English.pak` (13.6 МБ) | `.loca` — таблица `handle → текст` | Источник всех строк игры; в рантайме доступна как `Ext.Loca.GetTranslatedString` |
| `Data\Localization\Russian\Russian.pak` | Русская локализация установлена | Мод должен уметь озвучивать не только английский |
| `Data\Localization\Voice.pak` (14.3 ГБ) | Озвучка диалогов | **Диалоги уже озвучены голосом** — их не надо читать скринридером, только реплики игрока |
| `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\` | Сюда ставятся `.pak` модов | Пусто |
| `...\PlayerProfiles\Public\modsettings.lsx` | Порядок загрузки модов | Пусто (только GustavX) |
| `...\Script Extender\` | Появится после установки SE | Рабочая директория `Ext.IO.SaveFile/LoadFile` — точка файлового моста |

Важное следствие из `Voice.pak`: **BG3 полностью озвучен**. Слой доступности не должен читать
реплики NPC — он должен читать *варианты ответа игрока*, интерфейс, состояние боя и мир. Это
заметно сокращает объём работы по сравнению с WotR/Rogue Trader.

---

## 2. Технологический стек игры

- **UI** — NoesisGUI 3.1.6 (клон WPF, XAML + DependencyProperty + Binding + ICommand). Это
  ретейнед-режим с настоящим деревом визуалов и настоящими командами. Для нас это лучший из
  возможных вариантов после Unity: есть что читать (P1) и есть что вызывать (P2).
- **Игровая логика** — ECS (сущность + компоненты), полностью отражённая в API SE, плюс Osiris —
  декларативный сюжетный язык с ~2500 вызовами/запросами/событиями на сервере.
- **Звук** — Wwise; события звука дёргаются из Lua (`Ext.ClientAudio.PostEvent`) → P6 закрыт.
- **Ввод** — SDL2 → собственный `InputManager` с пользовательской раскладкой (Escape → Options →
  Shortcuts). Раскладка *редактируемая пользователем*, а `InputInputManager.InputDefinitions`
  отражён в Lua — значит стратегия §8.2 «переносить конфликтующие биндинги, а не глушить их»
  реализуема.
- **Модификация** — [BG3 Script Extender](https://github.com/Norbyte/bg3se) (Norbyte), v32 от
  21.06.2026, поддерживает Patch 8, самообновляется при запуске игры. Ставится как `DWrite.dll`
  в `bin\`.

---

## 3. Соответствие портам §2 спеки

| Порт | Статус | Чем закрывается в BG3 |
|---|---|---|
| **P1 State read** | ✅ полный | Noesis visual tree + ECS + Osiris queries + Loca |
| **P2 Action invoke** | ⚠️ 3 пути, есть дыра | `NoesisICommand:Execute`, инъекция клавиш, Osiris |
| **P3 Tick** | ✅ полный | `Ext.Events.Tick` (клиент — покадрово, сервер — ~30 Гц) |
| **P4 Key input + арбитраж** | ⚠️ механизм есть, нужна проверка | `Ext.Events.EclLuaKeyInput` + `LuaEventBase:PreventAction()` |
| **P5 Speech** | ❌ **отсутствует** | Нужен нативный мост (см. §6) |
| **P6 Sound** | ✅ | `Ext.ClientAudio.PostEvent` — родные Wwise-события UI |
| **P7 Localization** | ✅ | `Ext.Loca` + свой JSON-словарь через `Ext.IO` |
| **P8 Settings** | ✅ | [BG3 MCM](https://github.com/AtilioA/BG3-MCM) или `Ext.Vars` + JSON |
| **P9 Logging** | ✅ | `Ext.Utils.Print` в консоль SE + `Ext.IO.SaveFile` |
| **Итерация** | ✅✅ | Консоль SE = живой Lua-REPL в процессе игры; команда `reset` перезагружает Lua-состояние без перезапуска игры |

### P1 — чтение состояния

Три независимых источника, все читаются покадрово:

**1. Дерево визуалов Noesis** (клиент). Это и есть тот самый «что реально на экране»:

```lua
local root = Ext.ClientUI.GetRoot()          -- NoesisFrameworkElement
root.VisualChildrenCount                      -- обход всего дерева
root:VisualChild(i)
root:Child(i)                                 -- логические дети
root:Find("SomeName")                         -- поиск по x:Name
elem:GetProperty("Text")                      -- любое DependencyProperty по имени
elem:GetAllProperties()                       -- дискавери при написании recipe
elem:GetProperty("Visibility")                -- для A6 (parity)
elem:GetProperty("IsEnabled")
Ext.ClientUI.GetStateMachine()                -- UiUIStateMachine: какой экран активен
```

`GetAllProperties()` — главный инструмент разведки: садитесь в консоль SE, открываете нужный экран,
дампите поддерево и смотрите, что за биндинги под ним. Это заменяет dnSpy/UnityExplorer из
Unity-проектов.

**2. ECS.** Всё игровое состояние:

```lua
Ext.Entity.Get(uuid)                                      -- по GUID
Ext.Entity.GetAllEntitiesWithComponent("DisplayName")
Ext.Entity.GetEntitiesAroundPosition(pos, radius)         -- ← сканер объектов «из коробки»
entity:GetAllComponentNames()
entity:GetComponent("Health")
Ext.Entity.OnChange / OnCreate / OnDestroy                -- подписки для live watch (§7.5)
Ext.Entity.OnSystemUpdate / OnSystemPostUpdate
```

Полезные компоненты для наших целей: `DisplayName` (`.Name:Get()` → локализованная строка),
`CustomName`, `Health` (Hp/MaxHp/TemporaryHp), `Transform`, `ActionResources`, `SpellBook`,
`CanInteract`, `CanBeLooted`, `CanBeDisarmed`, `ObjectSize`, `GameObjectVisual`, `DialogState`,
`InterruptDecision`, `Stats`.

**3. Диалоговый менеджер** — прямой доступ к внутреннему состоянию диалога, минуя UI:

```lua
local mgr = Ext.Utils.GetDialogManager()      -- DlgDialogManager
mgr.Dialogs                                    -- table<int32, DlgDialogInstance>
-- в DlgDialogInstance: CurrentNode, NodeSelection[], Speakers[],
--   LocalHighlightedAnswer, HostHighlightedAnswer, State, ActiveDialog
```

Это ровно то, что нужно для A5 «читаем состояние игры, дёргаем её же обработчики» — варианты
ответа можно взять из модели, а не парсить визуалы.

**4. Локализация.** `TranslatedString:Get()` на любом поле, либо
`Ext.Loca.GetTranslatedString(handle)`. Русский/английский — автоматически по языку игры.

### P2 — вызов действий

Три пути, каждый со своей областью:

| Путь | Чем | Для чего | Риск |
|---|---|---|---|
| **Noesis ICommand** | `elem:GetProperty("Command"):Execute(param)` | Кнопки/пункты меню, у которых есть биндинг команды | Не у всех элементов есть `Command`; часть логики в code-behind |
| **Инъекция клавиш** | `Ext.ClientInput.InjectKeyPress(scancode, mods)` | Всё, что у игры забиндено на клавишу: цифры для реплик, хотбар, F1–F4, Tab, инвентарь | Зависит от пользовательской раскладки — надо читать `InputDefinitions`, а не хардкодить |
| **Osiris (сервер)** | `Osi.*` через NetChannel | Мир: движение, взаимодействие, каст, телепорт | Osiris **игнорирует предусловия** — легко «читерить» случайно |

Подтверждённые серверные вызовы (из `LaughingLeader/BG3ModdingTools/generated/Osi.lua`):

```lua
Osi.CharacterMoveTo(character, target, movementSpeed, event, moveID)
Osi.CharacterMoveToPosition(character, x, y, z, movementSpeed, event, moveID)
Osi.SteerTo(character, target, snapToTarget)
Osi.Use(character, item, useItem, isInteraction, event)
Osi.Open(item)
Osi.Pickup(character, item, event, forcePickUpOnFailure)
Osi.UseSpell(caster, spellID, target, target2, withoutMove)
Osi.UseSpellAtPosition(caster, spellID, x, y, z, withoutMove)
Osi.TeleportToPosition(...)                    -- запасной вариант, чистый чит
Osi.GetDistanceTo / GetDistanceToPosition / GetPosition / GetDisplayName
Osi.IsInCombat / CombatIsActive / CombatGetActiveEntity / CombatGetGuidFor
Osi.CombatGetInvolvedPartyMember(sCount) / CombatGetInvolvedPlayer(sCount)
Osi.OpenCharacterLootUI(looter, target)
```

**Дыра в P2**: SE не даёт инъекции мыши — есть только `InjectKeyDown/Up/Press`. Мышь нужна для
«кликнуть по точке мира» (штатное перемещение и штатное подтверждение цели заклинания).
Обходные пути, в порядке предпочтения:

1. `Ext.ClientUI.GetPickingHelper(playerId)` даёт `EclPlayerPickingHelper` с полями
   `TargetOverride: vec3?`, `Selection`, `SelectableObjects`, `WindowCursorPos`. Если
   `TargetOverride` записываемо — можно навести прицел на мировую точку без мыши, а подтверждение
   отправить клавишей. **Это первый эксперимент, который надо поставить.**
2. `InputInputManager.DeviceEventInjects` / `InputInjects` — массивы инъекции устройств отражены в
   Lua; возможно, туда пишутся мышиные события.
3. Компаньон-процесс (который всё равно нужен для речи) делает `SendInput` по экранным
   координатам. Требует проекции «мир → экран», а матриц камеры в API SE не нашлось — придётся
   либо считать самим по параметрам камеры, либо отказаться от этого пути.
4. Отказаться от мыши: перемещение через `Osi.CharacterMoveTo`, а бой — через хотбар + выбор цели
   клавишами (в BG3 цель в бою переключается с клавиатуры).

### P3 — tick

`Ext.Events.Tick:Subscribe(fn)` есть и на клиенте, и на сервере. Сервер ~30 Гц (≈33 мс), клиент —
покадрово. Из клиентского tick'а легальны все P1/P2-операции клиента. Плюс
`Ext.OnNextTick(fn)`, `Ext.Timer.WaitFor/WaitForRealtime`.

### P4 — ввод и арбитраж

```lua
Ext.Events.EclLuaKeyInput:Subscribe(function(e)
    -- e.Key: SDLScanCode, e.Modifiers: SDLKeyModifier,
    -- e.Pressed: boolean, e.Repeat: boolean
    -- e наследует LuaEventBase: CanPreventAction, PreventAction(), StopPropagation(), Stopped
end)
Ext.Events.EclLuaMouseButton / EclLuaMouseWheel / EclLuaControllerButton / EclLuaControllerAxis
```

Механизм подавления существует на уровне типа события (`LuaEventBase.PreventAction`), но
**фактическая поддержка `CanPreventAction` именно для `EclLuaKeyInput` требует эмпирической
проверки** — это второй обязательный эксперимент. Если подавление работает, §8.2 закрывается
штатно. Если нет — остаётся стратегия «переноса биндингов»: раскладка BG3 пользовательская, а
`InputInputManager.InputDefinitions` отражён в Lua, так что мод может при первом запуске сдвинуть
конфликтующие игровые биндинги и подсказки игры обновятся сами (это, кстати, вариант, который
спека и так предпочитает).

Путь §8.3 (собственный focus/submit тулкита) в Noesis существует — у элементов есть настоящий
focus и routed events. Гейт по владению ставится через `NoesisUIElement:Subscribe(eventName, cb)`
на нужных элементах, либо через очистку выделения, пока фокус у слоя.

**Клавиши, которые нельзя занимать**: Insert и CapsLock (NVDA), а также стандартные модификаторы
JAWS. Отдельно — Enter: он открывает командную строку самого SE.

### P5 — речь: не существует

В Lua-состоянии SE нет `io`, `os`, `package.loadlib`, `require` в смысле C-модулей, сокетов и FFI.
Единственные каналы наружу — `Ext.IO.SaveFile/LoadFile` (пишет в
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\`) и вывод в консоль/лог SE.
Разбор вариантов — §6.

### P6 / P7 / P8 / P9

- **P6**: `Ext.ClientAudio.PostEvent(entityHandle, "UI_Hover_Event")` — родные звуки интерфейса,
  имена Wwise-событий берутся из `SharedSoundBanks.pak`. Плюс `PlayExternalSound` для своих
  сэмплов (навигационные бипы, звук «путь заблокирован»).
- **P7**: `Ext.Loca` для игровых строк; свой словарь ролей/шаблонов — JSON через `Ext.IO`.
- **P8**: MCM даёт готовый фреймворк настроек **и биндингов с разрешением конфликтов** — под наш
  случай (десятки хоткеев) это экономит заметный кусок §7.1. Минус — внешняя зависимость.
- **P9**: `Ext.Utils.Print` (`_P`) в консоль SE + `Ext.IO.SaveFile` для трассы речи и фокуса.

---

## 4. Предлагаемая архитектура

```
┌─ BG3 process ───────────────────────────────────────────────────────────┐
│                                                                          │
│  ┌─ Server Lua state ────────────┐   ┌─ Client Lua state ─────────────┐  │
│  │ BootstrapServer.lua           │   │ BootstrapClient.lua            │  │
│  │  • Osiris listeners            │   │  • Graph A11y Kernel (порт)    │  │
│  │    (TurnStarted, CombatStarted,│   │  • Navigator + Screen manager  │  │
│  │     DialogStarted, ...)        │   │  • Screen recipes              │  │
│  │  • drive-paths в мир:          │◄──┤  • Noesis reader (P1)          │  │
│  │    Osi.CharacterMoveTo,        │NC │  • Key handler (P4)            │  │
│  │    Osi.Use, Osi.UseSpell       ├──►│  • World scanner               │  │
│  │  • ECS сервера                 │   │  • Speech queue → мост         │  │
│  └───────────────────────────────┘   └────────────┬───────────────────┘  │
│                                                    │                      │
└────────────────────────────────────────────────────┼──────────────────────┘
                                                     │  мост (§6)
                                        ┌────────────▼───────────────┐
                                        │ Нативный компонент          │
                                        │  Tolk / NVDA CC / JAWS COM  │
                                        │  → NVDA, JAWS, SAPI, Брайль │
                                        └─────────────────────────────┘
```

- **Ядро** (§3–§6 спеки, ~1700 строк) портируется на Lua 5.4 дословно. Оно чистое, без
  зависимостей — это самая безопасная часть работы.
- **NC** — `Ext.Net` NetChannel: типизированные request/reply между состояниями.
  `Ext.Net.CreateChannel(modUuid, name)`, `SetRequestHandler`, `RequestToServer(data, cb)`.
- **Screen recipes** — 80–90 % трудозатрат, как и предупреждает §10.1. Для BG3 это ≈35–50 экранов
  (см. §5.5).

Раскладка файлов мода:

```
BG3Access/
  Mods/BG3Access/
    meta.lsx
    ScriptExtender/
      Config.json                  { "RequiredVersion": 32, "ModTable": "BG3Access",
                                     "FeatureFlags": ["Lua"] }
      Lua/
        BootstrapClient.lua
        BootstrapServer.lua
        Kernel/                    -- порт §3–§6, без зависимостей от Ext
        Host/                      -- порты P1..P9
        Screens/                   -- рецепты экранов
        Locale/                    -- свои строки
```

---

## 5. Четыре заявленные цели → конкретика

### 5.1 Озвучка всего через NVDA / JAWS

Три источника текста, объединяемые announcer'ом (§6 спеки):

1. **Меню и HUD** — обход дерева Noesis, `GetProperty("Text"/"Content"/"ToolTip")`. Читается по
   рецепту экрана, а не «всё подряд»: слой владеет своим порядком обхода (A1).
2. **Игровые события** — Osiris-слушатели на сервере, пересылка на клиент: получен урон, статус
   наложен, бросок кости, кто-то вступил в бой, предмет подобран. Osiris-события подписываются
   через `Ext.Osiris.RegisterListener(name, arity, "after", handler)`.
3. **Мир** — сканер (§5.2).

Правило A6 (parity): не озвучивать то, чего зрячий сейчас не видит. В Noesis это
`Visibility != Visible` и `Opacity == 0`; в ECS — `OffStage`-компонент и туман войны.

Диалоги NPC читать **не нужно** — они озвучены. Нужны: варианты ответа игрока, результаты
проверок (`DlgDialogRoll`: Ability, Skill, DifficultyClass, Advantage), имя говорящего.

### 5.2 Сканер объектов + автопередвижение

Готовый примитив:

```lua
local me   = Ext.Entity.Get(Osi.GetHostCharacter())          -- сервер
local pos  = me.Transform.Transform.Translate
local near = Ext.Entity.GetEntitiesAroundPosition(pos, 30.0)
```

Дальше — фильтрация и категоризация по компонентам, ровно как object tracker в
[Stardew Access](https://github.com/stardew-access/stardew-access):

| Категория | Признак |
|---|---|
| Враги / нейтралы / союзники | `IsCharacter` + attitude через Osiris |
| Интерактивные | `CanInteract`, `ObjectInteraction` |
| Контейнеры / лут | `CanBeLooted` |
| Двери, рычаги, ловушки | `CanBeDisarmed`, root template type |
| Предметы на земле | `IsItem` |
| Выходы, вейпоинты, точки перехода | триггеры |

Озвучка позиции: дистанция + направление относительно **камеры** (не мировых осей), по
циферблату — «сундук, 8 метров, на 2 часа». Это проверенная схема из Factorio Access.

Проверка достижимости до объявления «можно идти»:

```lua
local path = Ext.Level.BeginPathfindingImmediate(entity, targetPos)
local ok   = Ext.Level.FindPath(path)
Ext.Level.ReleasePath(path)
```

плюс `Ext.Level.RaycastClosest` для «есть ли препятствие по прямой» и
`Ext.Level.GetHeightsAt(x, z)` для перепадов высот.

Перемещение — `Osi.CharacterMoveTo(me, targetGuid, "Run", "MoveDone")` /
`Osi.CharacterMoveToPosition(...)`. Событие завершения приходит именованным колбэком в `_Event`,
его ловим Osiris-слушателем и озвучиваем «дошёл» / «не дошёл».

**Оговорка про честность игры**: `Osi.CharacterMoveTo` — это скриптовое перемещение. Вне боя оно
эквивалентно клику мышью. В бою оно может не списать очки перемещения корректно. Для боя
предпочтителен либо `TargetOverride` из picking helper + штатное подтверждение, либо явная
пометка режима как «упрощённого».

### 5.3 Выбор ответов в диалогах

Чтение — из модели, минуя UI:

```lua
local mgr = Ext.Utils.GetDialogManager()
for id, inst in pairs(mgr.Dialogs) do
    inst.CurrentNode                -- DlgNodeData
    inst.NodeSelection              -- DlgNodeSelectionInfo[] : { LineId, Node }
    inst.LocalHighlightedAnswer     -- int8, текущее подсвеченное
    inst.Speakers                   -- EntityHandle[]
end
```

Текст реплики достаётся через `DlgTaggedText` → `TranslatedString:Get()`. Проверки навыка видны
заранее в `DlgDialogRoll` — можно объявлять «[Убеждение, СЛ 15] …», что даже зрячим полезно.

Выбор — инъекция цифровой клавиши, соответствующей индексу (в BG3 реплики выбираются цифрами),
либо `Execute` на `ICommand` кнопки ответа. Первый путь надёжнее и не зависит от вёрстки.

### 5.4 Бой

Что читаем:

- **Очередь ходов** — `Osi.CombatGetActiveEntity(combatGuid)`,
  `Osi.CombatGetInvolvedPartyMembersCount/InvolvedPartyMember`, событие `TurnStarted`.
- **Ресурсы действия** — `ActionResourcesComponent.Resources` (действие, бонусное действие,
  перемещение, ячейки заклинаний).
- **Здоровье/статусы** — `HealthComponent` (Hp, MaxHp, TemporaryHp, IsInvulnerable) + статусы.
- **Доступные заклинания** — `SpellBookComponent.Spells`, `SpellBookPreparesComponent.PreparedSpells`.
- **Цели** — сканер §5.2, отфильтрованный по враждебности и досягаемости, с дистанцией.
- **Прерывания** (реакции) — `InterruptDecisionComponent`, отдельный модальный экран: они
  требуют ответа по таймеру и без озвучки просто теряются.
- **Боевой лог** — `EsvCombatLogCombatLogSystem`, `TranslatedFSString` в записях → готовая
  озвучка попаданий/промахов/бросков.

Что вызываем: хотбар клавишами (штатно, все правила игры соблюдаются) + выбор цели; либо
`Osi.UseSpell(caster, spellID, target)` как упрощённый путь — но он игнорирует предусловия и
ресурсы, так что это режим «ассист», а не основной.

### 5.5 Список экранов (черновая оценка объёма)

Главное меню · загрузка/сохранение · настройки · **создание персонажа** (самый тяжёлый, 10+
под-экранов) · HUD исследования · хотбар · инвентарь · экипировка · книга заклинаний ·
подготовка заклинаний · лист персонажа · левел-ап · журнал квестов · карта · вейпоинты ·
диалог · торговля · лут-контейнер · разделение стека · крафт/алхимия · лагерь и сундук лагеря ·
долгий/короткий отдых · боевой HUD · очередь ходов · выбор цели · прерывания/реакции ·
броски кубика · мультиклассирование · романы/одобрение · книги и записки · тюториалы.

≈35–50 рецептов. Это и есть основной объём проекта.

---

## 6. Проблема P5: как дотянуться до NVDA/JAWS

Четыре варианта, оценка по надёжности/задержке/сложности.

### Вариант A — компаньон-процесс + файловый мост (рекомендую для v1)

Lua пишет реплику в файл через `Ext.IO.SaveFile("a11y/speech.txt", json)`; отдельный EXE следит за
директорией `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\a11y\` через
`ReadDirectoryChangesW` и отдаёт текст в Tolk.

- **+** Пишется за день. Не может уронить игру. Легко отлаживается. Не требует C++ в игре.
- **+** Тот же процесс может делать `SendInput` — закрывает дыру с мышью (§3, P2).
- **−** Задержка ~10–40 мс (приемлемо, но заметно на быстром переборе списка).
- **−** Файловая запись каждые несколько миллисекунд при быстрой навигации — надо буферизовать и
  схлопывать (announcer'у это и так свойственно, §6.2).
- **−** Пользователю нужно запускать второй процесс (решается автозапуском/трей-приложением).

Протокол: JSON-строки `{"seq":N,"text":"...","interrupt":true}`. `seq` монотонный — компаньон
отбрасывает устаревшие, это даёт корректный `interrupt` по провенансу (A7).

### Вариант B — нативный DLL-плагин (целевое решение для v2)

DLL, загружаемая
[Yet Another BG3 Native Mod Loader](https://github.com/MolotovCherry/Yet-Another-BG3-Native-Mod-Loader)
(инжектит из `bin\NativeMods\`, экспортируемая функция `Init`), которая линкует Tolk и вешается на
канал от Lua. Три подварианта связи:

- **B1** — DLL следит за тем же файлом, что в варианте A. Задержка та же, но нет второго процесса.
- **B2** — DLL перехватывает вывод консоли/лога SE и ловит строки с префиксом `[[A11Y]]`,
  печатаемые через `_P()`. Задержка околонулевая, реализация — один хук. Костыльно, но работает.
- **B3** — DLL находит `lua_State` SE и регистрирует нативную функцию `A11y.Speak`. Идеальная
  задержка и идеальный API, но это самая хрупкая часть: привязка к внутренностям SE, ломается
  на его обновлениях. Альтернатива — форк bg3se с добавленным `Ext.A11y` и PR к Norbyte.

Пример существующего нативного мода для BG3 на C++ — [BG3WASD](https://github.com/Ch4nKyy/BG3WASD)
(CMake + vcpkg + MSVC 2022), годится как скелет проекта.

### Вариант C — только SAPI/WinRT, без скринридера

Отбрасывается как основной: пользователь теряет свой голос, скорость, брайль и словари NVDA.
Нужен только как fallback, когда скринридер не запущен — Tolk это и так умеет.

### Вариант D — `Ext.ClientAudio.PlayExternalSound`

Синтезировать WAV снаружи и проигрывать движком. Не годится для интерактивной навигации
(задержка синтеза), но полезно для коротких неречевых сигналов: «стена», «путь найден»,
«новая цель». Стоит взять как дополнение к A/B, не вместо.

**Рекомендация**: A на прототип и всю раннюю разработку (мост абстрагирован за одним интерфейсом
`Speech.Speak(text, interrupt)`), переход на B1/B3 когда задержка начнёт мешать.

---

## 7. Полный список того, что понадобится

### 7.1 Обязательные зависимости рантайма

| Что | Версия/источник | Роль |
|---|---|---|
| Baldur's Gate 3 | Patch 8, build 4.1.1.7209685 | ✅ установлена |
| BG3 Script Extender | v32+, `github.com/Norbyte/bg3se` | Всё API мода; ставится как `bin\DWrite.dll`, самообновляется |
| Tolk | `github.com/dkager/tolk` (LGPL-3.0), x64 | Абстракция над NVDA/JAWS/SAPI/брайлем |
| nvdaControllerClient64.dll | из поставки Tolk | Канал в NVDA |
| jfwapi / JAWS COM | из поставки Tolk | Канал в JAWS |
| BG3 MCM *(опц.)* | `github.com/AtilioA/BG3-MCM` | Настройки + биндинги с разрешением конфликтов |
| Yet Another BG3 NML *(для вар. B)* | `github.com/MolotovCherry/Yet-Another-BG3-Native-Mod-Loader` | Загрузка нативной DLL |

### 7.2 Инструменты разработки

- **BG3 Modder's Multitool** (ShinyHobo) — распаковка `.pak`, конвертация `.lsf`/`.lsx`/`.loca`,
  сборка мода в `.pak` одним drag-and-drop.
- **LSLib / `divine.exe`** (Norbyte) — то же из командной строки, для CI-сборки.
- **BG3 Mod Manager** — порядок загрузки, установка `.pak` при тестировании.
- **`ExtIdeHelpers.lua`** — 1 МБ аннотаций для всего API SE. Генерируется прямо из игры командой
  `Ext.Debug.GenerateIdeHelpers()`, лежит в
  `github.com/Norbyte/bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua`.
  **Это основная документация**, а не `API.md`.
- **VS Code + Lua Language Server** (sumneko) — автодополнение по IdeHelpers.
- **BG3 Mod Helper** — расширение VS Code под BG3 (шаблоны meta.lsx, сборка pak).
- **Visual Studio 2022 + CMake + vcpkg** — только если идём в вариант B.
- **`generated/Osi.lua`** из `LaughingLeader/BG3ModdingTools` — полный справочник по ~2500
  Osiris-функциям.
- **`bg3.norbyte.dev`** — поиск по игровым данным (заклинания, статусы, шаблоны).
- **NVDA + JAWS** для тестов; NVDA Speech Viewer и лог-трасса вместо ушей на ранних этапах.
- Отдельный **чистый профиль игры** и **тестовые сейвы** на каждый экран (бой, диалог, торговля,
  левел-ап) — иначе итерация утонет в перепрохождении.

### 7.3 Настройки запуска

- `--skip-launcher` в параметрах запуска Steam — лаунчер Larian на CEF нечитаем скринридером и
  является первым же барьером.
- `ScriptExtenderSettings.json`: `"CreateConsole": true`, `"DeveloperMode": true`,
  `"EnableLuaDebugger": true` (порт 9998).

### 7.4 Знания и данные, которые придётся добыть

- **Схема XAML-экранов игры** — распаковать `Game.pak`/`Shared.pak`, найти `.xaml` нужного экрана,
  понять имена элементов и биндингов. Это делается один раз на экран и является основным
  содержанием каждого рецепта.
- **Карта Wwise-событий UI** — чтобы P6 звучал по-родному.
- **Список Osiris-событий** (не вызовов) — они не в `Osi.lua`, их придётся собирать из
  `docs.baldursgate3.game` и из распакованного сюжетного кода.
- **Соответствие `SDLScanCode` ↔ пользовательская раскладка BG3** — читать
  `InputInputManager.InputDefinitions`, не хардкодить.

### 7.5 Код, который надо написать

| Слой | Объём | Источник |
|---|---|---|
| Ядро графа (§3–§6) | ~1700 строк | Порт из C# в Lua, дословно |
| Тесты соответствия | ~100 тестов | Перевод существующего набора |
| Порты P1–P9 | ~1–2 тыс. строк | С нуля под BG3 |
| Navigator / арбитраж / screen manager | ~1–2 тыс. строк | По §7–§9 спеки |
| Рецепты экранов | 35–50 шт. | С нуля, 80–90 % работы |
| Мировой слой (сканер, навигация, бой) | — | С нуля; аналогов в WotR/RT нет, там не было world layer такого масштаба |
| Речевой мост (C++/C#) | ~300–800 строк | С нуля |

---

## 8. Дорожная карта

**Ф0. Разведка (1–2 дня).** Поставить SE, включить консоль, выполнить эксперименты из §9. Только
после них план перестанет быть гипотезой.

**Ф1. Вертикальный срез «речь + один экран» (1–2 недели).** Мост речи по варианту A. Обход дерева
Noesis. Главное меню озвучено и навигируемо стрелками. Критерий: главное меню и загрузка сейва
проходятся вслепую.

**Ф2. Ядро (1–2 недели).** Порт §3–§6 + тесты. Критерий: тесты соответствия зелёные.

**Ф3. Навигатор и арбитраж (1 неделя).** §7–§9. Критерий: слой владеет клавиатурой, игра под ним
не срабатывает на захваченные аккорды, модальные экраны эксклюзивны.

**Ф4. Мировой слой (2–4 недели).** Сканер, категории, циферблат, проверка пути, автоход. Критерий:
пролог (Наутилоид) проходится до первой боёвки вслепую.

**Ф5. Диалоги (1 неделя).** Критерий: диалог с Ласаэль проходится вслепую, включая проверку навыка.

**Ф6. Бой (2–3 недели).** Очередь ходов, ресурсы, цели, хотбар, прерывания, боевой лог. Критерий:
первый бой выигрывается вслепую.

**Ф7. Остальные экраны (долго).** Инвентарь → лист персонажа → левел-ап → карта → торговля →
создание персонажа (последним, он самый сложный и нужен один раз за прохождение — на старте можно
обойтись готовым пресетом).

---

## 9. Что надо проверить эмпирически (до начала кодирования)

Список экспериментов в консоли SE. Каждый — потенциальный блокер или развилка архитектуры.

1. **Подавление клавиш.** В хендлере `EclLuaKeyInput` проверить `e.CanPreventAction` и вызвать
   `e:PreventAction()`. Реагирует ли игра на клавишу? → Определяет, идём мы по §8.2 «подавление»
   или §8.2 «перенос биндингов».
2. **`TargetOverride` в picking helper.** Записать `vec3` в
   `Ext.ClientUI.GetPickingHelper(0).TargetOverride` и посмотреть, сместился ли прицел. → Решает
   судьбу мышиной дыры в P2.
3. **`ICommand:Execute`.** Найти в дереве Noesis кнопку главного меню, взять `GetProperty("Command")`,
   вызвать `Execute(nil)`. → Определяет, есть ли у нас «правильный» P2 для UI.
4. **Полнота дерева.** Продампить `GetRoot()` рекурсивно на 3–4 разных экранах. Виден ли текст?
   Виден ли HUD? Не скрыт ли он за отдельными Noesis-«вью», не подключёнными к корню.
5. **Стоимость обхода.** Замерить `Ext.Utils.MicrosecTime()` вокруг полного обхода дерева на самом
   тяжёлом экране (инвентарь). Спека требует immediate-mode перестроения каждый кадр — надо
   убедиться, что это укладывается в бюджет.
6. **Задержка файлового моста.** Замерить полный путь `SaveFile` → компаньон → Tolk → NVDA.
7. **`GetEntitiesAroundPosition`.** Стоимость вызова с радиусом 30 м в густой локации, и полнота:
   попадают ли туда предметы на земле и двери, или только персонажи.
8. **Клиентский доступ к `GetDialogManager`.** Он в `Ext.Utils`, но диалог — серверная сущность.
   Проверить, что на клиенте видны варианты ответа, иначе придётся гонять их через NetChannel.
9. **`reset` при живой сессии.** Проверить, что горячая перезагрузка Lua не рвёт подписки Noesis и
   не крашит игру — от этого зависит скорость всей разработки.
10. **Выживание после обновления SE.** SE самообновляется молча при запуске игры; проверить, как
    мод переживает смену версии API.

---

## 10. Риски

| Риск | Оценка | Смягчение |
|---|---|---|
| Подавление клавиш не работает | Средняя | Стратегия переноса биндингов через `InputDefinitions` |
| Нет инъекции мыши | Высокая | `TargetOverride`, иначе Osiris-перемещение + `SendInput` из компаньона |
| Часть UI не отражена в дереве Noesis | Средняя | Дублирующее чтение из ECS/viewmodel там, где визуалы молчат |
| Патч игры ломает SE и мод | Высокая, но управляемая | SE обновляется быстро; держать `RequiredVersion` и деградировать мягко |
| Задержка речи на быстрой навигации | Средняя | Схлопывание в announcer'е (§6.2) + переход на вариант B |
| Osiris-действия ломают правила игры в бою | Высокая | Не использовать `Osi.UseSpell` как основной путь; идти через хотбар |
| Объём рецептов экранов | Высокая | Приоритет по игровому пути; создание персонажа — в последнюю очередь |
| Мультиплеер | Низкая | Мод чисто клиентский на уровне UI; серверную часть держать безвредной |

---

## 11. Источники

**Script Extender и API**
- [Norbyte/bg3se](https://github.com/Norbyte/bg3se) — сам SE
- [Docs/API.md](https://github.com/Norbyte/bg3se/blob/main/Docs/API.md) — документация API v30
- [ExtIdeHelpers.lua](https://github.com/Norbyte/bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua) — полные аннотации типов
- [Релизы SE](https://github.com/Norbyte/bg3se/releases) — v32, Patch 8
- [Lua Scripting (DeepWiki)](https://deepwiki.com/Norbyte/bg3se/4-lua-scripting)
- [Getting Started with Script Extender](https://wiki.bg3.community/en/Tutorials/ScriptExtender/GettingStarted)
- [Dear ImGui в BG3SE](https://wiki.bg3.community/Tutorials/ScriptExtender/ImGui-and-You/Dear-ImGui)

**Osiris и данные игры**
- [Osi.lua — полный список функций](https://github.com/LaughingLeader/BG3ModdingTools/blob/master/generated/Osi.lua)
- [CharacterMoveTo](https://docs.baldursgate3.game/index.php?title=CharacterMoveTo), [UseSpell](https://docs.baldursgate3.game/index.php?title=UseSpell)
- [Scripting: Introduction to Osiris](https://docs.baldursgate3.game/Scripting:_Introduction_to_Osiris)
- [Extending UI (Larian)](https://docs.baldursgate3.game/index.php?title=Extending_UI), [UI](https://docs.baldursgate3.game/index.php?title=UI)
- [NoesisGUI](https://www.noesisengine.com/)

**Инструменты и фреймворки**
- [BG3 Modders Multitool](https://github.com/ShinyHobo/BG3-Modders-Multitool/wiki/Packaging-Mod-Files)
- [Modding:Packaging mods (bg3.wiki)](https://bg3.wiki/wiki/Modding:Packaging_mods), [Unpacking and Converting](https://bg3.wiki/wiki/Guide:Unpacking_and_Converting_Files)
- [BG3-MCM](https://github.com/AtilioA/BG3-MCM), [MCM на Nexus](https://www.nexusmods.com/baldursgate3/mods/9162)
- [Yet Another BG3 Native Mod Loader](https://github.com/MolotovCherry/Yet-Another-BG3-Native-Mod-Loader)
- [BG3WASD](https://github.com/Ch4nKyy/BG3WASD) — образец нативного C++-мода
- [BG3 Mod Helper (VS Code)](https://wiki.bg3.community/Tools/bg3-mod-helper)

**Речь**
- [dkager/tolk](https://github.com/dkager/tolk), [документация](https://github.com/dkager/tolk/blob/master/docs/README.md)
- [UniversalSpeech](https://pypi.org/project/universalspeech/)

**Прецеденты**
- [stardew-access](https://github.com/stardew-access/stardew-access) — object tracker, tile viewer, auto-walk; Tolk на Windows
- [PvZA11y](https://github.com/CG8516/PvZA11y) — NVDA/JAWS/SAPI поверх немодифицируемой игры

**Контекст доступности BG3**
- [Baldur's Gate 3 accessibility review — Can I Play That?](https://caniplaythat.com/2023/08/31/baldurs-gate-3-accessibility-review/)
- [No accessibility for legally blind players — Steam](https://steamcommunity.com/app/1086940/discussions/0/3978428732559974373/)
- [Как отключить лаунчер](https://www.pcgamer.com/baldurs-gate-3-disable-launcher/)
