# Система аватаров (VRChat-style)

> Аватар **отделён** от контроллера игрока, как в системе аватаров VRChat. Источник
> вычисляет набор именованных **параметров-сигналов** и кладёт их в шину; аватар (модель +
> аниматор + скрипт-драйвер) сам решает, как эти сигналы отобразить. Источник и аватар не
> знают друг о друге — связаны только контрактом параметров. Один сигнал разные аватары
> трактуют по-разному.

## Зачем

Раньше визуал «другого игрока» был зашит в `remote_player.tscn` (капсула + квад лица), а
наклон взгляда (`pitch`) жёстко интерпретировался скриптом. Чтобы аватар можно было менять
независимо от контроллера и сети, между ними введён слой параметров. Теперь добавить новый
сигнал или новую модель аватара — это локальное изменение, не затрагивающее остальное.

## Поток данных

```
[AvatarParameterSource на Player] --вычисляет--> AvatarParameters (локальная шина)
        |                                               |
   snapshot()                                  (будущий локальный/mirror-аватар)
        |
  NetworkManager.send_state(pos, yaw, snapshot)  --RPC dict-->  state_received(id,pos,yaw,params)
                                                                       |
                              RemotePlayersView --> RemotePlayer.set_state(pos,yaw,params)
                                                                       |
                                            AvatarHost.apply_params(params) -> шина
                                                                       |
                              Avatar (корень) раздаёт шину -> Applier'ы
                                                                       |
                       Applier на сигнал/в _process читает состояние и применяет его
                       (копирует в AnimationTree, крутит кость, наклоняет квад…)
```

## Ключевая идея: хранилище + аппликаторы (модель VRChat)

Аватар **развязан** на две роли:

- **Корень-хранилище** (`Avatar`) — просто держит шину параметров и раздаёт её, **никакой
  логики анимации**.
- **Аппликаторы** — дочерние узлы, которые читают состояние и что-то делают. Аппликатор это
  любой узел с методом `bind_params(params)` («утиный» интерфейс — корень не знает их классов).

Главный аппликатор — универсальный `AvatarAnimationTreeApplier`: он просто **копирует**
параметры в `AnimationTree` по таблице привязок. Это ровно модель VRChat: состояние уезжает в
аниматор, а вся анимация («смотрю вверх/вниз», «бег», «прыжок») живёт в дереве блендов и
переходов. **Такому аватару не нужен код** — только модель, `AnimationTree` и узел-аппликатор
с заполненными `bindings` в инспекторе. Кастомный скрипт-аппликатор остаётся возможен (для
не-скелетных трюков, как накладка лица), но это лишь один из путей, а не обязательный.

## Компоненты

| Узел/класс | Файл | Роль |
|---|---|---|
| `AvatarParams` | [actors/avatar/avatar_params.gd](../actors/avatar/avatar_params.gd) | Контракт: имена параметров (`StringName`), версия, дефолты |
| `AvatarParameters` | [actors/avatar/avatar_parameters.gd](../actors/avatar/avatar_parameters.gd) | Шина (состояние): `set_value`/`get_value`/`apply`/`snapshot` + сигнал `changed` |
| `Avatar` | [actors/avatar/avatar.gd](../actors/avatar/avatar.gd) | Корень-хранилище: `bind(params)` раздаёт шину аппликаторам; `apply_identity`; `nameplate_height` |
| `AvatarApplier` | [actors/avatar/appliers/avatar_applier.gd](../actors/avatar/appliers/avatar_applier.gd) | База аппликатора: `bind_params`, сигнал `changed`, виртуальный `_apply` |
| `AvatarAnimationTreeApplier` | [actors/avatar/appliers/avatar_animation_tree_applier.gd](../actors/avatar/appliers/avatar_animation_tree_applier.gd) | **Универсальный** аппликатор: копирует параметры в `AnimationTree` по `bindings` (без кода) |
| `AvatarParamBinding` | [actors/avatar/appliers/avatar_param_binding.gd](../actors/avatar/appliers/avatar_param_binding.gd) | Resource: одна строка `параметр → путь свойства в AnimationTree` |
| `LookPitchApplier` | [actors/avatar/appliers/look_pitch_applier.gd](../actors/avatar/appliers/look_pitch_applier.gd) | Общий кастомный аппликатор: вращает узел по LookPitch × `pitch_factor` |
| `UserSettingsAvatarTexture` | [actors/avatar/user_settings_avatar_texture.gd](../actors/avatar/user_settings_avatar_texture.gd) | Resource-маркер: положи в любой текстурный слот — туда уедет текстура игрока |
| `UserTextureApplier` | [actors/avatar/appliers/user_texture_applier.gd](../actors/avatar/appliers/user_texture_applier.gd) | Generic: при identity подменяет все маркеры во всех мешах на текстуру игрока |
| `AvatarParameterSource` | [actors/avatar/avatar_parameter_source.gd](../actors/avatar/avatar_parameter_source.gd) | Продюсер: считает сигналы игрока из `CharacterBody3D` |
| `AvatarHost` | [actors/avatar/avatar_host.gd](../actors/avatar/avatar_host.gd) | Крепление: владеет шиной, монтирует/меняет аватар, кормит параметрами |
| `AvatarResolver` | [actors/avatar/avatar_resolver.gd](../actors/avatar/avatar_resolver.gd) | Резолвит `avatar_uri` (`vrwebavatar://N` / внешний URL) в `PackedScene` |
| Бандл-пак `avatar_1` | [avatars/avatar_1.tscn](../avatars/avatar_1.tscn) | Дефолт: капсула + квад лица; `LookPitchApplier` (factor 0.35) + `UserTextureApplier` |
| Бандл-пак `avatar_2` | [avatars/avatar_2.tscn](../avatars/avatar_2.tscn) | Тот же `LookPitchApplier`, но factor −1.0: полный поворот головы-узла |

`RemotePlayer` — носитель аватара: тело делегировано `AvatarHost`, а неймплейт и речевой бабл
(UI поверх любого аватара) остались на корне.

> **Почему шина живёт на `AvatarHost`, а не на корне аватара.** Хост переживает смену аватара
> (и приём сетевых параметров во время неё), поэтому держит шину сам и передаёт ссылку корню
> через `bind`. Для аппликаторов точка входа к состоянию — корень аватара (`get_params()`) или
> переданная в `bind_params` шина.

## Контракт параметров

Имена и типы выровнены по [встроенным параметрам аниматора VRChat](https://creators.vrchat.com/avatars/animator-parameters/).
Все имена — константы в `AvatarParams`, чтобы источники и аватары не расходились.

### A. Вычисляются и передаются сейчас

| Имя | Тип | Источник | Описание |
|---|---|---|---|
| `LookPitch` | Float (рад) | `Player.look_pitch()` | Наклон взгляда. Наш сигнал — у VRChat голова через трекинг |
| `IsLocal` | Bool | продюсер/хост | true на своём аватаре, false на чужих капсулах |
| `Grounded` | Bool | `is_on_floor()` | Касается ли земли |
| `VelocityX/Y/Z` | Float (м/с) | `velocity` в локальных осях | X — вбок, Y — вверх, Z — вперёд(−)/назад(+) |
| `VelocityMagnitude` | Float | derived | Модуль скорости |
| `AngularY` | Float (рад/с) | дельта `yaw` | Угловая скорость поворота корпуса |
| `Moving` | Bool | derived | `VelocityMagnitude > MOVING_EPSILON`. Наша добавка сверх VRChat |

### B. Заложены в контракт с дефолтами (пока статичны)

`Upright` (1.0), `Voice` (0.0 — [голос отложен](multiplayer.md)), `VRMode` (0 — десктоп),
`MuteSelf`, `AFK`, `Seated`, `InStation`, `AvatarVersion` (= `AvatarParams.VERSION` — версия
нашего контракта; аватар может проверить и не ломаться на чужой версии).

Оживают, когда появится их источник (приседания → `Upright`, микрофон → `Voice`, VR →
`VRMode`/`TrackingType`). Аватар уже сейчас может на них завязываться — будет читать дефолт.

### C. Резерв имён (forward-compat, не производятся)

`Viseme`, `GestureLeft/Right(+Weight)`, `TrackingType`, `Earmuffs`, `IsOnFriendsList`,
`PreviewMode`, `IsAnimatorEnabled`, `Scale*`, `EyeHeight*` — нет соответствующих инпутов/
систем (VR-контроллеры, lip-sync, скейл аватара). Имена объявлены, чтобы при появлении
функций не плодить расхождений.

## Как добавить параметр

1. Объявить имя-константу в `AvatarParams` (нужную группу) и дефолт в `defaults()`, если он
   читается.
2. Начать его вычислять в продюсере [avatar_parameter_source.gd](../actors/avatar/avatar_parameter_source.gd)
   (`params.set_value(...)`). Снимок автоматически уедет по сети — сигнатура RPC не меняется.
3. Использовать его в аватаре: либо строкой `bindings` в `AvatarAnimationTreeApplier`, либо в
   кастомном аппликаторе (`_apply`).

## Как написать свой аватар

Корень всегда один и тот же — `Avatar` (скрипт [avatar.gd](../actors/avatar/avatar.gd), без
наследования). Различается только наполнение: модель + аппликаторы.

### Вариант А — без кода, через AnimationTree (предпочтительно)

1. Сцена: корень `Avatar`, внутри — модель (Skeleton/меши), `AnimationPlayer` с анимациями
   (`смотрю вверх`, `смотрю вниз`, `бег`…), `AnimationTree` с деревом блендов/переходов.
2. Добавить узел со скриптом `AvatarAnimationTreeApplier`, выставить `animation_tree` и в
   `bindings` строки `параметр → путь свойства дерева`:
   - `LookPitch → parameters/look/blend_position` (BlendSpace1D «вверх↔вниз»);
   - `Grounded → parameters/conditions/grounded` (условие перехода в прыжок/падение);
   - `VelocityMagnitude → parameters/run/blend_amount` (бленд idle↔run).
3. Всё. Никакого GDScript: состояние само копируется в дерево, анимацию рисуем в редакторе.

### Вариант B — кастомный аппликатор (не-скелетные трюки)

1. Сцена: корень `Avatar`, нужные узлы (квад/кость/спрайт).
2. Узел со скриптом `extends AvatarApplier`, переопределить `_apply(pname, value)` —
   реагировать на нужные параметры. Сглаживать самому (lerp в `_process`); состояние приходит
   ~15 Гц. Пример общего и настраиваемого:
   [LookPitchApplier](../actors/avatar/appliers/look_pitch_applier.gd) — вращает заданный узел
   по `LookPitch × pitch_factor` (Default и Head — это он же с factor 0.35 и −1.0).
   Чисто-идентичностный аппликатор не обязан слушать шину — достаточно метода
   `apply_identity(nick, face)` на узле (`extends Node`), его корень тоже раздаёт.

В обоих вариантах: задать `nameplate_height` на корне и подключить аватар —
`AvatarHost.set_avatar(preload("...tscn"))` или экспортом `avatar_scene`. Аппликаторов на
одном аватаре может быть несколько (вращение + текстура игрока + AnimationTree для тела) —
корень раздаёт шину/идентичность всем.

## Текстура игрока (лицо) — маркер `UserSettingsAvatarTexture`

Лицо/аватарку игрока **не привязываем к конкретному мешу**. Вместо этого есть Resource-маркер
[UserSettingsAvatarTexture](../actors/avatar/user_settings_avatar_texture.gd) (наследник
`Texture2D`): кладёшь его в **любой текстурный слот любого материала** аватара (albedo,
emission… — в любом месте дерева), задав ему `default_texture` (что показывать до прихода
лица). Узел-аппликатор [UserTextureApplier](../actors/avatar/appliers/user_texture_applier.gd)
при `apply_identity` обходит все меши аватара, находит все слоты с этим маркером и подменяет их
на текстуру игрока (уникальным материалом на экземпляр). Так одно «лицо» автоматически
попадает во все нужные места (лицо, бейдж, баннер…), и ни аватару, ни аппликатору не нужно
знать, где именно они расположены.

Подключение в сцене: материалу выставить `albedo_texture` = под-ресурс
`UserSettingsAvatarTexture` (с `default_texture`), и добавить узел `UserTextureApplier`
(`extends Node`) — больше ничего. Пример — `avatar_1` (бывший DefaultAvatar).

> В `.tscn` под-ресурс маркера объявляется нативным типом — `[sub_resource type="Texture2D"]`
> с `script = ExtResource(...)` (не `type="Resource"`), иначе Godot не присвоит его в слот.

## Выбор аватара: идентификатор + резолвер

Каждый игрок выбирает аватар **идентификатором-строкой** (`Settings.avatar_uri`), который
уезжает другим в [карточке идентичности](multiplayer.md) рядом с ником и лицом. Принимающая
сторона резолвит его в сцену через [AvatarResolver](../actors/avatar/avatar_resolver.gd) и
ставит капсуле (`RemotePlayersView._apply_avatar` → `RemotePlayer.set_avatar`). Схемы:

| URI | Что значит |
|---|---|
| `vrwebavatar://N` | Аватар №N из **бандл-пака** `res://avatars/avatar_N.tscn` (грузится синхронно). N — 1,2,3…; если N больше числа аватаров в паке — список **закольцовывается** по модулю. |
| `http(s)://…tscn` | **Внешний** аватар: качаем байты, кладём в `user://avatar_cache/`, грузим как `PackedScene`. Самодостаточные сцены/ресурсы (или ссылающиеся только на ресурсы приложения) — ок. |

**Бандл-пак** `res://avatars/` — это аватары, идущие с приложением; их можно добавлять,
называя `avatar_1.tscn`, `avatar_2.tscn`, … подряд (число считается пробами `ResourceLoader`).
Дефолт — `vrwebavatar://1` (он же дефолт `AvatarHost`). Резолвер асинхронный (внешний URL
качается), в колбэке капсула перепроверяется (жива и аватар не сменился), повторный монтаж
того же аватара пропускается.

## Точки расширения

- **Сеть.** Пакет состояния — `send_state(pos, yaw, params: Dictionary)`
  ([network_manager.gd](../scripts/network_manager.gd)). Новые сигналы идут в `params` без
  правки сигнатуры RPC.
- **Локальный источник.** `AvatarParameterSource` — единственное место, где «рождаются»
  сигналы игрока. Будущий локальный/зеркальный аватар может читать ту же шину
  (`Player.avatar_snapshot()` / источник напрямую).
- **UI выбора аватара.** Экран настроек ([scenes/settings.gd](../scenes/settings.gd)) имеет
  поле «Адрес аватара» с кнопкой «✕» (сброс к дефолту `vrwebavatar://1`): правит
  `Settings.avatar_uri`, сохранение рассылает новую карточку пирам. Дальше можно добавить
  визуальный выбор номера из пака (превью) вместо ручного ввода.

## Известные риски

- **Доверие к сети.** `apply_params` принимает словарь от пира как есть. Сейчас параметры
  влияют только на анимацию (визуал), но при росте набора стоит валидировать типы/диапазоны
  на приёме, как уже делается для чата (`MAX_CHAT_CHARS`).
- **Внешний аватар = выполнение чужого кода.** `vrwebavatar://N` безопасен (только ресурсы
  приложения), но `http(s)://…tscn` инстанцирует скачанную сцену: она может нести скрипты/
  произвольные классы — это тот же принятый риск, что и у VRWeb-страниц
  ([vrweb ClassDB risk]). До выхода на реальные/недоверенные URL источник аватаров должен быть
  доверенным; sandbox для внешних сцен — отдельная задача.
