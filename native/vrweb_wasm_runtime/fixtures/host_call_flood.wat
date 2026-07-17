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
    (func (export "create") (result i32) i32.const 1)
    (func (export "mount") (param i32) (result i32) i32.const 0)
    (func (export "event") (param i32) (param i32) (result i32)
      (local $i i32)
      (loop $flood
        local.get $i
        call $log-code
        local.get $i
        i32.const 1
        i32.add
        local.tee $i
        i32.const 100
        i32.lt_s
        br_if $flood)
      i32.const 0)
    (func (export "unmount") (param i32) (result i32) i32.const 0))
  (core instance $guest-instance
    (instantiate $guest (with "host" (instance $host-core))))
  (type $create-type (func (result s32)))
  (type $one-arg-type (func (param "instance" s32) (result s32)))
  (type $event-type (func (param "instance" s32) (param "code" s32) (result s32)))
  (func $create (type $create-type) (canon lift (core func $guest-instance "create")))
  (func $mount (type $one-arg-type) (canon lift (core func $guest-instance "mount")))
  (func $event (type $event-type) (canon lift (core func $guest-instance "event")))
  (func $unmount (type $one-arg-type) (canon lift (core func $guest-instance "unmount")))
  (export "create" (func $create))
  (export "mount" (func $mount))
  (export "event" (func $event))
  (export "unmount" (func $unmount)))
