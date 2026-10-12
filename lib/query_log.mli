(** An audit log of SQL run against a data directory: one JSON object per line in
    [<dir>/query-log.ndjson].

    {v
    {"time":"2026-01-01T00:00:00.000000000Z","user":"alice","sql":"SELECT 1"}
    v} *)

open! Core
open! Async

(** [<dir>/query-log.ndjson] *)
val path : dir:string -> string

(** One line, without the newline. *)
val entry : time:Time_ns.t -> user:string -> sql:string -> string

(** [$USER], else [$LOGNAME], else ["unknown"]. *)
val current_user : unit -> string

(** Appends one entry, creating the file if needed. *)
val append : ?time:Time_ns.t -> ?user:string -> dir:string -> string -> unit Deferred.t
