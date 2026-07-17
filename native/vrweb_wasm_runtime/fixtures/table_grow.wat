(component
  (core module $hostile
    (table 1 funcref)
    (func (export "run") (result i32)
      ref.null func
      i32.const 20000
      table.grow
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
