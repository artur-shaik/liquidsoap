module Future = Moonpool.Fut

type t = unit Future.t

let make = Future.spawn_on_current_runner
let process = Future.await
