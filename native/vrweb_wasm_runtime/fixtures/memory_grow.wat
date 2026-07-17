(component
  (core module $hostile
    (memory 1)
    (func (export "run") (result i32)
      i32.const 1024
      memory.grow
      i32.const -1
      i32.eq
      if
        unreachable
      end
      i32.const 1))
  (core instance $instance (instantiate $hostile))
  (func $run (result s32)
    (canon lift (core func $instance "run")))
  (export "run" (func $run)))
