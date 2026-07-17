# VRWeb Maker Kit

Этот архив выпускается вместе с Knossos той же версии, но устанавливается как самостоятельный
Godot 4.6 project/addon. Knossos не требуется для сборки HTML; он нужен как reference runtime
для production preview и финальной проверки.

## Начало работы

1. Откройте этот каталог как Godot project либо скопируйте `addons/vrweb_tools` в существующий
   Godot 4.6 project.
2. Включите **VRWeb Tools** в Project Settings → Plugins.
3. Откройте `world.tscn` и соберите HTML через Scene → Export As… → VRWML Scene.
4. Для production preview задайте executable Knossos той же версии и нажмите Build & Run.

Исполняемое поведение поставляется как WebAssembly component; Godot scripts authoring-проекта
не публикуются. `compatibility.json` фиксирует совместимые версии Maker Kit, Knossos, Godot и
локальной VRWML policy. Изменения формата перечисляются в общем `CHANGELOG.md` release train.

Для поведения добавьте `VrwebWasmComponent`, выберите готовый `.vrmod` и задайте module id/export
из его manifest. Build проверит и скопирует package в `dist/modules/<sha256>.vrmod`, но не станет
исполнять его внутри Godot. Проверка исполнения выполняется кнопкой **Build & Run in Knossos**.

Если установлен VRWeb TypeScript adapter, кнопка **Add VRWeb Script** создаёт source component и
template. Укажите путь к `build.mjs` в `vrweb/maker/javascript_adapter_script`; Build & Run
инкрементально соберёт `.vrmod`, но не опубликует `.ts`. Prebuilt workflow не требует Node/npm.

При открытии корня архива в VS Code файл `.vscode/settings.json` автоматически подключает
`schemas/vrweb-html-data.json`: для ручного HTML появляются completion и hover descriptions
тегов локальной strict policy, Godot properties и допустимых enum values.

## Обновление и миграция

1. Сохраните свои scenes, modules, assets и project settings в source control.
2. Прочитайте секцию **VRWeb Maker Kit** между текущей и целевой версиями в
   `CHANGELOG.md`; breaking policy/manifest changes должны содержать шаги миграции.
3. Замените только `addons/vrweb_tools` каталогом из нового архива; не заменяйте свой
   `project.godot`, scenes и assets готовым starter-ом.
4. Откройте проект Godot и выполните strict build. Для production preview используйте Knossos
   с тем же semver, который указан в `compatibility.json`.
