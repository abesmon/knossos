(component
  (core module $hostile
    (func (export "run") (result i32)
      unreachable))
  (core instance $instance (instantiate $hostile))
  (func $run (result s32)
    (canon lift (core func $instance "run")))
  (export "run" (func $run)))
