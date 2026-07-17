(component
  (core module $hostile
    (func (export "run") (result i32)
      (loop $forever
        br $forever)
      i32.const 0))
  (core instance $instance (instantiate $hostile))
  (func $run (result s32)
    (canon lift (core func $instance "run")))
  (export "run" (func $run)))
