(component
  (type $log-code (func (param "code" s32)))
  (import "vrweb:core/host@1.0.0" (instance $core
    (export "log-code" (func (type $log-code)))))

  (type $bytes-result (func (param "key" string)
    (result (result (list u8) (error string)))))
  (type $command-result (func (param "request" (list u8))
    (result (result (error string)))))
  (type $subscribe-result (func (param "key" string)
    (result (result u64 (error string)))))
  (type $unsubscribe (func (param "subscription" u64)))
  (import "vrweb:state/host@1.0.0" (instance $state
    (export "read" (func (type $bytes-result)))
    (export "command" (func (type $command-result)))
    (export "subscribe" (func (type $subscribe-result)))
    (export "unsubscribe" (func (type $unsubscribe)))))

  (type $asset-result (func (param "name" string)
    (result (result (list u8) (error string)))))
  (import "vrweb:assets/host@1.0.0" (instance $assets
    (export "lookup" (func (type $asset-result)))))

  (type $timer-start (func (param "delay-ms" u32) (param "repeat" bool)
    (result (result u64 (error string)))))
  (type $timer-cancel (func (param "timer" u64)))
  (import "vrweb:timers/host@1.0.0" (instance $timers
    (export "start" (func (type $timer-start)))
    (export "cancel" (func (type $timer-cancel)))))

  (type $input-enable (func (param "kind" string) (param "enabled" bool)
    (result (result (error string)))))
  (import "vrweb:input/host@1.0.0" (instance $input
    (export "enable" (func (type $input-enable)))))

  (type $feature-has (func (param "capability" string) (result bool)))
  (import "vrweb:features/host@1.0.0" (instance $features
    (export "has" (func (type $feature-has)))))

  (type $log-write (func (param "request" (list u8))
    (result (result (error string)))))
  (import "vrweb:log/host@1.0.0" (instance $log
    (export "write" (func (type $log-write)))))

  (core module $allocator
    (memory (export "memory") 1)
    (global $heap (mut i32) (i32.const 4096))
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

  (alias export $core "log-code" (func $log-code))
  (core func $lower-log-code (canon lower (func $log-code)))
  (core instance $core-lowered (export "log-code" (func $lower-log-code)))

  (alias export $state "read" (func $state-read))
  (alias export $state "command" (func $state-command))
  (alias export $state "subscribe" (func $state-subscribe))
  (alias export $state "unsubscribe" (func $state-unsubscribe))
  (core func $lower-state-read
    (canon lower (func $state-read) (memory $memory) (realloc $realloc)))
  (core func $lower-state-command
    (canon lower (func $state-command) (memory $memory) (realloc $realloc)))
  (core func $lower-state-subscribe
    (canon lower (func $state-subscribe) (memory $memory) (realloc $realloc)))
  (core func $lower-state-unsubscribe
    (canon lower (func $state-unsubscribe) (memory $memory) (realloc $realloc)))
  (core instance $state-lowered
    (export "read" (func $lower-state-read))
    (export "command" (func $lower-state-command))
    (export "subscribe" (func $lower-state-subscribe))
    (export "unsubscribe" (func $lower-state-unsubscribe)))

  (alias export $assets "lookup" (func $asset-lookup))
  (core func $lower-asset-lookup
    (canon lower (func $asset-lookup) (memory $memory) (realloc $realloc)))
  (core instance $assets-lowered (export "lookup" (func $lower-asset-lookup)))

  (alias export $timers "start" (func $timer-start))
  (alias export $timers "cancel" (func $timer-cancel))
  (core func $lower-timer-start
    (canon lower (func $timer-start) (memory $memory) (realloc $realloc)))
  (core func $lower-timer-cancel
    (canon lower (func $timer-cancel) (memory $memory) (realloc $realloc)))
  (core instance $timers-lowered
    (export "start" (func $lower-timer-start))
    (export "cancel" (func $lower-timer-cancel)))

  (alias export $input "enable" (func $input-enable))
  (core func $lower-input-enable
    (canon lower (func $input-enable) (memory $memory) (realloc $realloc)))
  (core instance $input-lowered (export "enable" (func $lower-input-enable)))

  (alias export $features "has" (func $feature-has))
  (core func $lower-feature-has
    (canon lower (func $feature-has) (memory $memory) (realloc $realloc)))
  (core instance $features-lowered (export "has" (func $lower-feature-has)))

  (alias export $log "write" (func $log-write))
  (core func $lower-log-write
    (canon lower (func $log-write) (memory $memory) (realloc $realloc)))
  (core instance $log-lowered (export "write" (func $lower-log-write)))

  (core module $guest
    (import "env" "memory" (memory 1))
    (import "core" "log-code" (func $log-code (param i32)))
    (import "state" "read" (func $state-read (param i32 i32 i32)))
    (import "state" "command" (func $state-command (param i32 i32 i32)))
    (import "state" "subscribe" (func $state-subscribe (param i32 i32 i32)))
    (import "state" "unsubscribe" (func $state-unsubscribe (param i64)))
    (import "assets" "lookup" (func $asset-lookup (param i32 i32 i32)))
    (import "timers" "start" (func $timer-start (param i32 i32 i32)))
    (import "timers" "cancel" (func $timer-cancel (param i64)))
    (import "input" "enable" (func $input-enable (param i32 i32 i32 i32)))
    (import "features" "has" (func $feature-has (param i32 i32) (result i32)))
    (import "log" "write" (func $log-write (param i32 i32 i32)))

    (data (i32.const 0) "vrweb:assets/1")
    (data (i32.const 32) "icon")
    (data (i32.const 48) "light")
    (data (i32.const 64) "{\22key\22:\22light\22,\22command\22:\22set\22,\22value\22:true}")
    (data (i32.const 128) "activate")
    (data (i32.const 160) "{\22level\22:\22info\22,\22message\22:\22portable fixture\22}")

    (func (export "create") (result i32)
      i32.const 0
      i32.const 14
      call $feature-has
      drop
      i32.const 32
      i32.const 4
      i32.const 512
      call $asset-lookup
      i32.const 64
      i32.const 44
      i32.const 544
      call $state-command
      i32.const 48
      i32.const 5
      i32.const 576
      call $state-read
      i32.const 48
      i32.const 5
      i32.const 608
      call $state-subscribe
      i64.const 1
      call $state-unsubscribe
      i32.const 10
      i32.const 0
      i32.const 640
      call $timer-start
      i32.const 128
      i32.const 8
      i32.const 1
      i32.const 672
      call $input-enable
      i32.const 160
      i32.const 45
      i32.const 704
      call $log-write
      i32.const 13
      call $log-code
      i32.const 1)
    (func (export "mount") (param i32) (result i32) i32.const 0)
    (func (export "event") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "unmount") (param i32) (result i32) i32.const 0))

  (core instance $guest-instance (instantiate $guest
    (with "env" (instance $allocator-instance))
    (with "core" (instance $core-lowered))
    (with "state" (instance $state-lowered))
    (with "assets" (instance $assets-lowered))
    (with "timers" (instance $timers-lowered))
    (with "input" (instance $input-lowered))
    (with "features" (instance $features-lowered))
    (with "log" (instance $log-lowered))))

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
