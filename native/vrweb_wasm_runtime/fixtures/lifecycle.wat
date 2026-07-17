(component
  (type $log-code (func (param "code" s32)))
  (import "vrweb:core/host@1.0.0" (instance $host
    (export "log-code" (func (type $log-code)))))
  (alias export $host "log-code" (func $log-code))
  (core func $lower-log-code (canon lower (func $log-code)))
  (core instance $host-core
    (export "log-code" (func $lower-log-code)))

  (core module $guest
    (import "host" "log-code" (func $log-code (param i32)))
    (memory (export "memory") 1)
    (global $heap (mut i32) (i32.const 1024))
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      (local $result i32)
      global.get $heap
      local.tee $result
      local.get 3
      i32.add
      global.set $heap
      local.get $result)
    (func (export "create") (result i32)
      i32.const 1
      call $log-code
      i32.const 7)
    (func (export "mount") (param $instance i32) (result i32)
      i32.const 2
      call $log-code
      i32.const 0)
    (func (export "event") (param $instance i32) (param $envelope i32)
      (param $length i32) (result i32)
      local.get $envelope
      i32.load8_u
      call $log-code
      i32.const 0)
    (func (export "unmount") (param $instance i32) (result i32)
      i32.const 4
      call $log-code
      i32.const 0))

  (core instance $guest-instance
    (instantiate $guest
      (with "host" (instance $host-core))))
  (alias core export $guest-instance "memory" (core memory $memory))
  (alias core export $guest-instance "realloc" (core func $realloc))

  (type $create-type (func (result s32)))
  (type $one-arg-type (func (param "instance" s32) (result s32)))
  (type $event-type (func (param "instance" s32)
    (param "envelope" (list u8)) (result s32)))
  (func $create (type $create-type)
    (canon lift (core func $guest-instance "create")))
  (func $mount (type $one-arg-type)
    (canon lift (core func $guest-instance "mount")))
  (func $event (type $event-type)
    (canon lift (core func $guest-instance "event") (memory $memory) (realloc $realloc)))
  (func $unmount (type $one-arg-type)
    (canon lift (core func $guest-instance "unmount")))
  (export "create" (func $create))
  (export "mount" (func $mount))
  (export "event" (func $event))
  (export "unmount" (func $unmount)))
