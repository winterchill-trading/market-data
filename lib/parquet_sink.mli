(** Batching Parquet writer for a live feed: one table of one instrument.

    {!add} only buffers: rows are collected into batches of [row_group_rows] and handed
    over a pipe to a separate job chain that writes them with {!Parquet_file}, off the
    scheduler thread. A slow disk therefore never blocks the caller; when more than
    [max_pending_rows] rows are waiting to be written, new batches are dropped and counted
    in {!dropped}.

    Files follow the day of the [time_source] clock (UTC) when a row is added:
    [<dir>/<venue>/<symbol>/parquet/<kind>/<YYYY-MM-DD>.parquet]. The first row of a new
    day closes the previous day's file. If the day's file already exists (a restart), the
    sink writes [<YYYY-MM-DD>.1.parquet], [.2], ... instead. A file only appears under its
    final name once closed; rows still buffered in memory are lost on a crash, and
    {!Day_close} can rebuild the day from the event log. *)

open! Core
open! Async

type 'a t

(** [time_source] defaults to the wall clock, [compression] to [`Zstd] and
    [max_pending_rows] to [16 * row_group_rows]. With [direct] (the
    {!Parquet_schemas.Direct} writer of the same table) the writer job appends rows
    through it, without allocating per row; the files are the same. *)
val create
  :  ?time_source:Time_source.t
  -> ?compression:[ `None | `Zstd ]
  -> ?max_pending_rows:int
  -> ?direct:('a Parquet.Writer.t -> 'a -> unit)
  -> 'a Parquet.Schema.t
  -> dir:string
  -> Instrument.t
  -> Parquet_kind.t
  -> row_group_rows:int
  -> 'a t

(** Buffers a row. Raises if [t] is closed. *)
val add : 'a t -> 'a -> unit

(** Writes out buffered rows, closes the current file and stops the writer job.
    Idempotent. *)
val close : _ t -> unit Deferred.t

(** Completed files, in the order they were closed. *)
val files : _ t -> string list

(** Rows dropped because too many were waiting to be written. *)
val dropped : _ t -> int

(** Rows handed to the writer job and not yet written. *)
val pending : _ t -> int
