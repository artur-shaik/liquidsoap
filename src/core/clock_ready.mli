type t

val make : (unit -> unit) -> t
val process : t -> unit
val clock_pool : Moonpool.Ws_pool.t
