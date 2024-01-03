type t = unit -> unit

let make fn = fn
let process fn = fn ()
