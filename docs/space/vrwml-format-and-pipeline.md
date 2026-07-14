# VRWML: формат сцен и пайплайн аватаров

> **Решение:** не строить новый универсальный scene IR раньше времени. Первая версия VRWML
> переиспользует уже работающую симметрию `Godot scene → vrweb-теги → Godot scene`: имя класса
> становится именем тега, свойства — атрибутами, вложенность — деревом сцены. `.tscn` остаётся
> authoring-файлом, а `.vrwml` становится публичным форматом поставки.

## Главная граница

Зависимость от **class names** сама по себе не является проблемой. Важно, что означает имя:

- `LookPitchApplier` как случайное внутреннее имя скрипта Knossos — деталь реализации;
- `<LookPitchApplier>` с описанной в спецификации семантикой — публичный VRWML-класс, который
  Godot, Unity, web-клиент или другой движок реализуют каждый по-своему.

То же справедливо для `Avatar`, `UserTextureApplier`, `VoiceScaleApplier` и других необходимых
runtime-компонентов. Godot-реализация может инстанцировать соответствующий `class_name` почти
напрямую, а другой клиент держит registry `имя VRWML-класса → своя реализация`.

В Knossos такой registry всё равно понадобится: текущий `VrwebBuilder` создаёт только классы
из `ClassDB`, тогда как scripted `class_name` туда не попадает как обычный engine class.
Симметричный exporter registry должен знать `Script/Resource → public VRWML tag`, конструктор
и defaults. Это точечное расширение существующего builder/exporter, не новый форматный слой.

Поэтому на текущей стадии не требуется сначала отделять формат от Godot через большую
engine-neutral промежуточную модель. Формат может наследовать открытую node/resource-модель
Godot, если VRWML явно специфицирует используемое подмножество и семантику собственных классов.

## Форма документа

Самый дешёвый вариант — сохранить уже существующую грамматику и разрешить тот же блок как
standalone-файл:

```xml
<vrweb>
  <Avatar nameplate_height="2.1">
    <Node3D name="Head">
      <!-- меши и материалы -->
    </Node3D>
    <LookPitchApplier target_path="../Head" pitch_factor="-1.0"/>
    <VoiceScaleApplier target_path="../Head/MouthObject"/>
    <UserTextureApplier/>
  </Avatar>
</vrweb>
```

- расширение — `.vrwml`;
- MIME — `application/vrwml+xml`;
- `<vrweb>` внутри HTML и standalone `.vrwml` содержат одно и то же дерево, поэтому отдельный
  адаптер форматов не нужен;
- назначение документа определяет **контекст загрузки**, а не самозаявленный `profile`.

`mode="combine|exclusive"` нужен странице, потому что решает, смешивать ли VRWeb-дерево с
визуализацией HTML. У аватара HTML-слоя нет, поэтому `mode` ничего не сообщает. Аналогично
`profile="avatar"` не делает содержимое аватаром: недоверенный автор может написать любой
profile. `AvatarResolver` и так знает, что URI пришёл из карточки пользователя, поэтому именно
он применяет avatar-контракт и avatar-policy к результату.

Необязательные version/profile hints можно добавить позже для диагностики совместимости, но
они не являются security boundary и не нужны для первого round-trip. Metadata envelope,
namespaces и несколько сцен в одном документе также не должны блокировать миграцию.

## Какие имена становятся стандартом

VRWML vocabulary удобно делить на три группы.

### Scene classes

Текущие `Node3D`, `MeshInstance3D`, `Resource`, `ExtResource`, `StandardMaterial3D` и другие
PascalCase-теги остаются Godot-shaped базой версии 1. Спецификация фиксирует только реально
поддерживаемое подмножество. Другой клиент может реализовать аналоги или локально пропустить
неизвестный визуальный узел.

Не нужно заранее переименовывать всю математику, материалы и сценограф в абстрактные сущности.
Их стоит обобщать по результатам появления второго backend-а, а не по предположениям.

### Avatar classes

Текущее реализованное подмножество непосредственно стандартизирует роли:

- `Avatar` — корень, metadata и подключение parameter bus;
- `LookPitchApplier` — применение `LookPitch` к вращению target;
- `VoiceScaleApplier` — применение `Voice` к масштабу/видимости target;
- `UserTextureApplier` и marker resource — подстановка identity texture.

`AvatarAnimationTreeApplier` и `AvatarParamBinding` также являются публичными классами.
Прямая Godot-ссылка `animation_tree` в VRWML представляется переносимым относительным
`animation_tree_path: NodePath`, а `bindings` — массивом ссылок на ресурсы
`AvatarParamBinding(param, tree_path)`. Полный конкретный animation graph по-прежнему зависит
от поддерживаемого клиентом подмножества scene/resource classes.

Каждый класс должен описываться через наблюдаемое поведение, типы свойств, defaults и реакцию
на отсутствующий target/parameter. Спецификация не должна требовать GDScript, signals или
`AnimationTree` как внутренний механизм другого клиента.

После первого round-trip стоит оценить схлопывание частных аппликаторов в общий класс:

```xml
<AvatarParameterApplier parameter="LookPitch"
                        target="../Head"
                        property="rotation:x"
                        scale="-1.0"
                        smoothing="12.0"/>
```

Generic-класс уменьшает vocabulary, но его не надо вводить до проверки, что он действительно
покрывает текущие `LookPitch`, `Voice` и animator use cases без сложного мини-языка. Для MVP
допустимо экспортировать конкретные стандартные классы почти один-в-один из `.tscn`.

### Client extensions

Редкие компоненты, которые нужны только Knossos и ещё не имеют стабильной общей семантики, не
попадают автоматически в VRWML Standard. Они либо:

- не экспортируются с понятной диагностикой;
- объявляются как optional extension/capability;
- поставляются отдельным trusted `.vrmod`, если без кода не обойтись.

Критерий стандартизации: тег описывает результат, который нужен нескольким клиентам, а не
способ, которым Knossos сегодня достигает этого результата.

## Контракт параметров аватара

Параметр и аппликатор — разные части стандарта:

- параметр говорит, **какое состояние существует**;
- аппликатор говорит, **как конкретный аватар его отображает**.

Статусы параметров версии 1:

- **current/network** — `LookPitch`, `Grounded`, `VelocityX/Y/Z`, `VelocityMagnitude`,
  `AngularY`, `Moving`: источник сейчас вычисляет их и передаёт в state snapshot;
- **current/context** — `IsLocal`, `Voice`: параметр работает сейчас, но его истинное значение
  зависит от принимающего клиента, а не от декларации аватара; такие значения фильтруются и
  на отправке, и на приёме;
- **optional/default** — `Upright`, `VRMode`, `MuteSelf`, `AFK`, `Seated`, `InStation`,
  `AvatarVersion`: имя, тип и default стабильны, живого источника пока может не быть;
- **reserved-name** — `Viseme`, gestures/tracking/scale/eye-height и остальные имена группы C:
  зарезервировано только имя. Тип, диапазон и default не являются контрактом до перевода в
  optional/current.

Нормативная таблица типов, единиц и defaults находится в
[avatars.md](../client/avatars.md#нормативный-контракт-v1).

Стандартный параметр не означает, что каждый клиент обязан иметь соответствующий sensor:

- у параметра есть тип, диапазон и default;
- клиент публикует поддерживаемые capabilities;
- если источник отсутствует, используется default;
- аватар обязан сохранять осмысленный fallback.

Редкие VRChat-подобные параметры можно резервировать, но нельзя приписывать им тип/default и
считать поддержанными до появления реального producer/consumer. Capabilities клиента позже
смогут сообщать наличие optional input; обязательный `profile` документа для этого не нужен.

Владение параметром может меняться без изменения VRWML: новый клиент вправе перевести
network-owned параметр в local-context, начать вычислять его сам и игнорировать старое сетевое
значение. Во время compatibility window старые получатели продолжат пользоваться значением
отправителя. Текущий registry этой границы — `AvatarParams.LOCAL_CONTEXT_PARAMS`.

## Authoring и обратная загрузка

### Встроенные аватары

Для первой версии canonical authoring source остаётся `.tscn`:

1. аватар редактируется обычными средствами Godot;
2. exporter сериализует поддерживаемые классы/свойства в `.vrwml`;
3. validator загружает полученный VRWML через обычный runtime builder;
4. CI проверяет deterministic export и структурное/визуальное соответствие;
5. exported build поставляет `.vrwml`, а не требует исходный `.tscn`.

Это почти тот же путь, который уже работает для `tscn → HTML`. Нужен новый output mode
`VRWML`, а не новый exporter с нуля.

Есть две конкретные разницы с текущим world-exporter:

- сейчас exporter считает корень открытой сцены служебным holder-ом и пишет только его детей;
  для аватара корневой `<Avatar>` обязан попасть в документ;
- `get_class()` у scripted корня/аппликаторов возвращает базовые `Node3D`/`Node`, а у marker
  resource — базовый resource type; public registry должен вернуть `Avatar`,
  `LookPitchApplier`, `UserSettingsAvatarTexture` и другие стандартные имена без экспорта Script.

### Внешний VRWML в редакторе

Текущая базовая реализация намеренно простая:

1. `EditorSceneFormatImporter` регистрирует `.vrwml` как нативный импортируемый scene format;
2. importer открывает документ тем же parser/builder, что runtime;
3. применяет `AvatarVrwmlPolicy` и требует один корневой `Avatar`;
4. VRWML без внешних ресурсов открывается стандартным Godot scene-import workflow;
5. отдельная editable-copy command дожидается `ExtResource` и сохраняет локальную `.tscn`;
6. после правок `Scene → Export As… → VRWeb Scene…` снова создаёт `.vrwml`, не меняя путь
   и authoring lifecycle исходной `.tscn`.

Несохраняемый viewport preview реализован без `owner`, поэтому не загрязняет SceneTree/`.tscn`.
Semantic diff отложен до появления реального сценария частичной деградации. Exporter уже
останавливает standalone-экспорт, если встречает Script без зарегистрированного публичного
VRWML-класса: тихой потери поведения быть не должно.

### HTML как редактируемая сцена с read-only окружением

Локальный `.html/.htm` импортируется отдельным scene importer-ом. Первый `<vrweb>` становится
editable-слоем, а DOM за его пределами проходит через тот же `TopologyBuilder → SpaceLayout`,
а затем через полный `WorldGenerator`, что runtime. Поэтому editor preview содержит комнаты,
дверные проёмы, стены коридоров и все HTML-объекты. Интерактивные runtime actors не переводятся
массово в `@tool`: в preview ссылки/rich text/video становятся статическими панелями, а image —
встроенным quad с прогрессивной загрузкой настоящей текстуры после открытия сцены.
Preview хранится в import cache как служебно помеченное поддерево и становится internal после
открытия, поэтому виден во viewport, но не редактируется и не сериализуется exporter-ом.
При `mode="exclusive"` внешний HTML DOM не строится вовсе; показывается только editable
содержимое `<vrweb>`.

Обратная запись — lossless только по envelope: сырой prefix до `<vrweb>` и suffix после него
остаются неизменными, заменяется декларативный блок. Это сильнее обычного `HtmlNode.to_html()`,
который гарантирует семантический, но не текстовый round-trip. Конфликт по хэшу блока не даёт
затереть внешнюю правку. Документы без блока и блоки с editor-unsafe scripted classes можно
открыть ради procedural preview, но сохранить из частично материализованной сцены нельзя.

На первом этапе достаточно **semantic round-trip поддерживаемого подмножества**. Не нужны
sidecar-карты, сохранение исходного форматирования XML или побитовая обратимость произвольного
Godot API. Если неизвестные extensions станут реальной проблемой, lossless preservation можно
добавить позже.

Preview, полученный из внешнего URL, не должен напрямую сохраняться обратно на сервер. Для
изменения пользователь сначала делает локальную editable copy; публикация и права записи —
отдельный протокол.

## Контекст загрузки и runtime аватара

Один и тот же VRWML-документ можно попытаться загрузить как мир, аватар или editor preview.
Ожидания задаёт вызывающая сторона:

- page loader принимает дерево сцены и применяет page policy;
- avatar resolver ожидает один допустимый корень аватара и применяет avatar policy;
- editor preview показывает дерево вместе с diagnostics.

Декларация внутри файла не заменяет эти проверки. Если в аватарный URI положили целый мир,
resolver может отклонить неправильный корень, запрещённые классы и превышенные бюджеты. Если
мир спрятан детьми корректного `Avatar`, отличить «слишком сложный аватар» от «мира» формально
невозможно; это решается лимитами узлов, ресурсов, размеров и производительности, а не честностью
`profile`.

Текущий `AvatarResolver` возвращает `PackedScene`, и этот контракт можно сохранить:

1. resolver принимает внешний `.vrwml` и отклоняет другие HTTP-форматы;
2. `HtmlParser` уже принимает standalone-фрагмент `<vrweb>`, а `VrwebBuilder` уже находит его
   без обязательных `<html>/<body>`; нужен file/HTTP routing, а не второй parser;
3. resolver проверяет контекстный avatar-контракт и допустимые classes;
4. построенный корень с корректными owners упаковывается через `PackedScene.pack()` и отдаётся
   существующему `AvatarHost`; если packing окажется неудобен, достаточно маленького
   `set_avatar_node()` overload, а не нового document API;
5. built-in `vrwebavatar://N` начинает указывать на `avatars/avatar_N.vrwml`.

Локальный `.tscn` остаётся authoring source и внутренним dev fallback только для built-in
проекта; он не является значением `avatar_uri` и не поставляется внешнему клиенту. Внешний HTTP
`.tscn` отклоняется; ошибка VRWML не приводит к загрузке одноимённого `.tscn`.

Sibling manifest продолжает работать без изменения модели: для `avatar.vrwml` адрес остаётся
`avatar.manifest.json`.

## Безопасность без усложнения формата

Безопасность data-only VRWML основана на том, что class names проходят выбранную вызывающей
стороной policy до инстанцирования:

- avatar loader использует allowlist стандартных node/resource/avatar classes и свойств;
- `script`, `source_code`, callbacks, filesystem/network-классы запрещены;
- действуют бюджеты размера документа, числа/глубины узлов и внешних ресурсов;
- неизвестный класс даёт локальную диагностируемую деградацию, а не выполнение кода;
- исполняемые расширения идут отдельно через trusted `.vrmod`.

Для этого достаточно развить уже существующий `VrwebContentPolicy`; отдельная архитектура
документа не обязательна.

## Упрощённый план внедрения

Состояние на июль 2026: фазы 1–3 реализованы для двух встроенных аватаров. В фазе 4 есть
экспорт, несохраняемый preview, импорт в редактируемую `.tscn` и fail-closed diagnostics.
Структурный semantic diff исходного и повторно экспортированного документа остаётся следующей
итерацией.

### Фаза 1 — VRWML output и routing (реализовано)

- добавить standalone `.vrwml` output в `VrwebExporter` без HTML envelope;
- в avatar export включать сам корень сцены, а не только его детей;
- направлять содержимое `.vrwml` из local/HTTP resolver в существующие `HtmlParser` и
  `VrwebBuilder`;
- сделать deterministic scene → VRWML → scene round-trip test.

### Фаза 2 — avatar vocabulary (реализованное подмножество)

- описать стандартную семантику `Avatar` и текущих аппликаторов;
- добавить общий public class registry для экспорта и materialization scripted nodes/resources
  без поставки Script;
- добавить выбранные `AvatarResolver` validator и allowlist;
- зафиксировать параметры, типы, defaults и optional/reserved status.

### Фаза 3 — миграция двух аватаров (реализовано)

- экспортировать `avatar_1.tscn` и `avatar_2.tscn` в `.vrwml`;
- научить resolver собирать VRWML в `PackedScene`, не меняя API host;
- проверить `LookPitch`, `Voice`, identity texture, nameplate height и mirror layer;
- оставить `.tscn` как authoring source, но исключить его из runtime pack после стабилизации.

### Фаза 4 — editor import (частично реализовано)

- реализовано: импорт VRWML в редактируемую `.tscn` и обратный export;
- реализовано: отдельный несохраняемый preview mode и diagnostics policy rejections;
- показывать semantic diff и unsupported properties;
- только после реальных потерь решать, нужен ли более сложный lossless round-trip.

## Критерии готовности

- оба встроенных аватара поставляются и загружаются как `.vrwml`;
- их поддерживаемые `.tscn`-свойства проходят semantic round-trip;
- аппликаторы определены как VRWML-классы, а не поставляются GDScript-файлами;
- альтернативный клиент может реализовать эти class names без Godot;
- `LookPitch`, `Voice` и identity дают тот же видимый результат;
- внешний VRWML не может неявно выполнить Script;
- неизвестные классы и параметры деградируют локально и диагностируемо.

## Что пока не нужно

- универсальный engine-neutral scene IR;
- новый animation graph вместо `AnimationTree`;
- побитовый/lossless round-trip всего `.tscn`;
- XML namespaces и сложный multi-document envelope;
- обязательные `profile`/`version`, пока для них нет compatibility-потребителя;
- заранее абстрагировать каждый Godot-класс до появления второго потребителя.
