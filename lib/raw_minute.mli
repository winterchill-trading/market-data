(** Raw minute files as written by market-recorder: one line per venue frame,
    [<recv_ts> <frame>], with [recv_ts] in ISO 8601 UTC with microseconds
    ([2026-10-12T09:15:02.123456Z]); an empty line records a disconnect. Closed minutes
    are zstd compressed, possibly as several concatenated frames after a restart.

    {v <data_dir>/raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/<HH>-<MM>.ndjson[.zst] v}

    In the [<symbol>] directory name, [/], [\\] and space are replaced by [_]. *)

open! Core
module Md_stream := Stream
open! Async

module Line : sig
  type t =
    | Frame of
        { recv_ts : Time_ns.t
        ; payload : string
        }
    | Disconnect
  [@@deriving sexp_of, compare, equal]

  (** Parses one line, without its newline. *)
  val parse : string -> t Or_error.t
end

module File : sig
  type t =
    { venue : Venue.t
    ; stream : Md_stream.t
    ; symbol_dir : string (** the symbol as spelled in the directory name *)
    ; minute : Time_ns.t (** start of the minute the file covers *)
    ; compressed : bool
    ; path : string
    }
  [@@deriving sexp_of, compare]

  (** Parses a path ending in
      [<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/<HH>-<MM>.ndjson] or [.ndjson.zst]. *)
  val of_path : string -> t Or_error.t
end

(** Decompresses a zstd stream of one or more concatenated frames. *)
val decompress : string -> string

(** The raw lines of a minute file, without newlines, decompressing [.zst] files on the
    calling thread; raises on I/O and zstd errors. *)
val read_lines_blocking : string -> string list

(** The lines of a minute file, decompressing [.zst] files off the scheduler thread. A
    trailing line without a newline (a file still being written) is kept. *)
val read : string -> Line.t list Or_error.t Deferred.t

(** Every minute file of the UTC [date] under [<data_dir>/raw], sorted by venue, stream,
    symbol and minute (a compressed file before a plain one of the same minute). Paths
    that do not parse as minute files are ignored. *)
val files : data_dir:string -> Date.t -> File.t list Deferred.t
