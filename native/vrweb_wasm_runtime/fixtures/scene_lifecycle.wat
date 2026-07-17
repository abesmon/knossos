(component
  (type $query (func
    (param "target" u64)
    (param "request" (list u8))
    (result (result (list u8) (error string)))))
  (import "vrweb:scene/host@1.0.0" (instance $scene
    (export "query" (func (type $query)))))
  (type $has (func (param "capability" string) (result bool)))
  (import "vrweb:features/host@1.0.0" (instance $features
    (export "has" (func (type $has)))))

  (core module $allocator
    (memory (export "memory") 1)
    (global $heap (mut i32) (i32.const 1024))
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      (local $result i32)
      global.get $heap
      local.tee $result
      local.get 3
      i32.add
      global.set $heap
      local.get $result))
  (core instance $allocator-instance (instantiate $allocator))
  (alias core export $allocator-instance "memory" (core memory $memory))
  (alias core export $allocator-instance "realloc" (core func $realloc))
  (alias export $scene "query" (func $query))
  (core func $lower-query
    (canon lower (func $query) (memory $memory) (realloc $realloc)))
  (core instance $scene-core (export "query" (func $lower-query)))
  (alias export $features "has" (func $has))
  (core func $lower-has
    (canon lower (func $has) (memory $memory) (realloc $realloc)))
  (core instance $features-core (export "has" (func $lower-has)))

  (core module $guest
    (import "env" "memory" (memory 1))
    (import "host" "query" (func $query (param i64 i32 i32 i32)))
    (import "features" "has" (func $has (param i32 i32) (result i32)))
    (data (i32.const 0) "{\22op\22:\22root\22}")
    (data (i32.const 16) "vrweb:scene/1")
    (func (export "create") (result i32)
      i64.const 0
      i32.const 0
      i32.const 13
      i32.const 64
      call $query
      i32.const 16
      i32.const 13
      call $has
      drop
      i32.const 1)
    (func (export "mount") (param i32) (result i32) i32.const 0)
    (func (export "event") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "unmount") (param i32) (result i32) i32.const 0))
  (core instance $guest-instance (instantiate $guest
    (with "env" (instance $allocator-instance))
    (with "host" (instance $scene-core))
    (with "features" (instance $features-core))))
  (type $create-type (func (result s32)))
  (type $one-arg-type (func (param "instance" s32) (result s32)))
  (type $event-type (func (param "instance" s32)
    (param "envelope" (list u8)) (result s32)))
  (func $create (type $create-type) (canon lift (core func $guest-instance "create")))
  (func $mount (type $one-arg-type) (canon lift (core func $guest-instance "mount")))
  (func $event (type $event-type)
    (canon lift (core func $guest-instance "event") (memory $memory) (realloc $realloc)))
  (func $unmount (type $one-arg-type) (canon lift (core func $guest-instance "unmount")))
  (export "create" (func $create))
  (export "mount" (func $mount))
  (export "event" (func $event))
  (export "unmount" (func $unmount)))
