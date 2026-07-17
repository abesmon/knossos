(component
  (core module $answer-module
    (func (export "answer") (result i32)
      i32.const 42))
  (core instance $answer-instance (instantiate $answer-module))
  (func $answer (result s32)
    (canon lift (core func $answer-instance "answer")))
  (export "answer" (func $answer)))
