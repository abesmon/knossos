# VRWeb Maker Kit

Этот архив выпускается вместе с Knossos той же версии, но устанавливается как самостоятельный
Godot 4.6 project/addon. Knossos не требуется для сборки HTML; он нужен как reference runtime
для production preview и финальной проверки.

## Начало работы

1. Откройте этот каталог как Godot project либо скопируйте `addons/vrweb_tools` в существующий
   Godot 4.6 project.
2. Включите **VRWeb Tools** в Project Settings → Plugins.
3. Откройте `world.tscn` и соберите HTML через Scene → Export As… → VRWeb Scene.
4. Для production preview задайте executable Knossos той же версии и нажмите Build & Run.

`scripting_inline_demo.tscn` и `scripting_package_demo.tscn` показывают две формы trusted
GDScript. `compatibility.json` фиксирует совместимые версии Maker Kit, Knossos, Godot и VRWeb
vocabulary. Изменения и миграции перечисляются в общем `CHANGELOG.md` release train.

При открытии корня архива в VS Code файл `.vscode/settings.json` автоматически подключает
`schemas/vrweb-html-data.json`: для ручного HTML появляются completion и hover descriptions
strict VRWeb tags, Godot properties и допустимых enum values.

## Обновление и миграция

1. Сохраните свои scenes, modules, assets и project settings в source control.
2. Прочитайте секцию **VRWeb Maker Kit** между текущей и целевой версиями в
   `CHANGELOG.md`; breaking vocabulary/manifest changes должны содержать шаги миграции.
3. Замените только `addons/vrweb_tools` каталогом из нового архива; не заменяйте свой
   `project.godot`, scenes и assets готовым starter-ом.
4. Откройте проект Godot и выполните strict build. Для production preview используйте Knossos
   с тем же semver, который указан в `compatibility.json`.
