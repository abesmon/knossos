# Демо общего переключателя света

`vrwebresource://state_switch.html` — второй потребитель Replicated State после видео.
Страница содержит `<VRWebStateSwitch id="demo-light">`: кликабельную кнопку и светящуюся
сферу. `enabled=false` рисуется красным, `enabled=true` — зелёным. Нажатие в любом клиенте
отправляет команду `toggle` authority; canonical `DELTA` меняет цвет у всех, а late join
восстанавливается snapshot.

Компонент намеренно не использует `SAMPLE`, временные якоря или другие особенности видео.
Его схема [state_switch_schema.gd](../../scripts/network/state_switch_schema.gd) содержит один
`bool` и один reducer. Визуальный адаптер [vrweb_state_switch.gd](../../scripts/vrweb_state_switch.gd)
применяет действие optimistic и возвращается к canonical state при отрицательном ACK/timeout.

Проверка:

1. Открыть `vrwebresource://state_switch.html` в двух экземплярах в одной комнате.
2. Нажать кнопку в каждом экземпляре по очереди: оба должны показывать один цвет.
3. Открыть третий экземпляр позже: он должен получить текущий цвет snapshot’ом.
4. Закрыть первоначальный authority и продолжить переключение в оставшемся экземпляре.

Headless-регрессии: `tests/test_state_switch.tscn` проверяет составную сцену custom-тега,
а `tests/test_replicated_state.gd` — два toggle и generic revision без доменных веток Store.
