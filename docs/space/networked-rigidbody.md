# Сетевой `RigidBody3D`: руководство автора

Сетевое тело остаётся обычным Godot-тегом VRWML один-к-одному. `document.physics.bind`
добавляет к существующему `<RigidBody3D>` переносимый сетевой профиль; отдельного тега и
отдельной модели ownership нет.

```html
<RigidBody3D id="ball" position="Vector3(0,2,-6)" mass="1">
  <MeshInstance3D mesh="SubResource:::BallMesh"/>
  <CollisionShape3D shape="SubResource:::BallShape"/>
</RigidBody3D>
```

```lua
local ball = assert(document.query("#ball"))
assert(document.features.require("vrweb/physics/1"))
assert(document.physics.bind(ball, "ball", {
  sample_hz = 20,
  keyframe_interval = 1.0,
  interpolation_delay = 0.10,
  auto_claim = true,
}))
```

После bind один и тот же record содержит физический state и `bindings.simulator`. Simulator
считает обычную локальную физику и публикует samples. Остальные клиенты не считают независимую
траекторию: их тело frozen и следует за интерполированным потоком. Reliable keyframes нужны
late join, sleep/wake, recovery и handoff; они не заменяют частый sample-поток.

## Передача симуляции вслед за взаимодействием

```lua
local impulse = document.values.vector3(0, 4.5, -7.5)

ball.on("activate", function()
  if not document.physics.is_local_simulator("ball") then
    document.physics.claim("ball")
  end
  document.physics.apply_impulse("ball", impulse)
end, "Взять симуляцию и бросить")
```

`claim` сразу делает тело локально-динамическим, чтобы действие не ожидало сетевой round trip.
Authority принимает или отвергает команду обычными правилами replicated state. Принятый handoff
атомарно меняет `bindings.simulator`, увеличивает `simulation_epoch` и фиксирует pose и обе
скорости. При отказе клиент возвращается к canonical proxy.

Это подходит сценарию «я бросил — мой клиент считает ближайший полёт; другой игрок поймал —
теперь считает его клиент». Для `<VRWebGrabbable>` с единственным прямым дочерним
`<RigidBody3D>` эта интеграция встроена: успешный grab назначает держателя simulator, release
снимает `holder`, но оставляет simulator бросившему. Скрипт может читать обе роли:

```lua
local item = assert(document.query("#throw-ball"))
local holder = item.call("holder", {})
local simulator = item.call("simulator", {})
```

## Решение автора через обычный reducer

Если стандартный `claim_simulation` слишком свободен, добавьте команду к тому же record. Здесь
между передачами действует cooldown по authority clock:

```lua
assert(document.physics.bind(ball, "ball", {
  auto_claim = false,
  fields = {
    claim_after_msec = { type = "int", default = 0 },
  },
  commands = {
    take_control = {
      write_rule = "anyone",
      reducer = function(event)
        local now = event.context.authority_msec or 0
        if now < (event.state.claim_after_msec or 0) then return {} end
        return {
          bindings = { simulator = event.context.actor_user_id },
          state = {
            pose = event.args.pose,
            linear_velocity = event.args.linear_velocity,
            angular_velocity = event.args.angular_velocity,
            sleeping = event.args.sleeping,
            simulation_epoch = event.state.simulation_epoch + 1,
            tick = event.args.tick,
            claim_after_msec = now + 2000,
          },
        }
      end,
    },
  },
}))

ball.on("activate", function()
  document.physics.handoff("ball", "take_control")
end, "Запросить симуляцию")
```

`handoff` сам добавляет в args текущий физический снимок. Доменный validator не позволяет
custom reducer сменить simulator без полной handoff-транзакции. Право, cooldown, lease или
игровое условие остаются решением страницы через существующие bindings и reducers — это не
отдельная Rigidbody policy.

## Частота и переносимость

`sample_hz`, `keyframe_interval` и `interpolation_delay` — настройки автора и подсказки клиенту,
не ограничения стандарта транспорта. VRWeb не запрещает автору выбрать любую частоту или объём
событий. Конкретная реализация клиента вправе фильтровать либо пропускать поток ради собственных
ресурсов, не превращая такую policy в норму VRWeb.

На wire передаются pose, linear/angular velocity, sleeping, revision, simulation epoch и tick.
Идентичность отправителя берётся из транспорта; sample принимается только от пользователя,
назначенного в `bindings.simulator`. Алгоритм физического solver и визуального сглаживания может
различаться между средами исполнения, но binding, атомарный handoff, epochs и wire-поля остаются
переносимыми. Из этого не следует бит-в-бит одинаковая траектория разных physics engines после
долгой свободной симуляции; keyframes обеспечивают их сходимость.

Полная демонстрация с обычным телом, custom reducer и grabbable-мячом:
[networked_rigidbody.html](../../test_pages/networked_rigidbody.html).
