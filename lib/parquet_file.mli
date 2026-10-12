(** A Parquet file being written off the Async scheduler thread.

    Rows go to [<path>.tmp]; {!close} writes the footer and renames the file into place,
    so readers globbing [*.parquet] never see a partial file. All blocking work (encoding,
    compression, disk writes) runs through [In_thread], one call at a time per file. *)

open! Core
open! Async

type 'a t

(** Creates missing directories and starts [<path>.tmp]. *)
val create
  :  ?compression:[ `None | `Zstd ]
  -> 'a Parquet.Schema.t
  -> row_group_rows:int
  -> string
  -> 'a t Deferred.t

val path : _ t -> string

(** Appends rows; row groups are written as they fill. Do not call concurrently on one
    file. *)
val add : 'a t -> 'a list -> unit Deferred.t

val num_rows : _ t -> int

(** Writes the last row group and the footer, then renames [<path>.tmp] to [path]. *)
val close : _ t -> unit Deferred.t
