(** Streams market-recorder raw minute files ({!Raw_minute}) of one venue and symbol over
    a time range, all streams merged by [recv_ts].

    Memory is bounded: each stream holds at most one decompressed minute file, and the
    next one is read only once the consumer has taken every line of the previous one. *)

open! Core
module Md_stream := Stream
open! Async

module Item : sig
  type t =
    | Frame of
        { recv_ts : Time_ns.t
        ; stream : Md_stream.t
        ; frame : string
        }
    | Gap of
        { recv_ts : Time_ns.t
        (** the [recv_ts] of the stream's previous frame, or the start of the minute file
            when that is later (the disconnect is the file's first line) *)
        ; stream : Md_stream.t
        } (** an empty raw line: the recorder's connection dropped *)
  [@@deriving sexp_of, compare, equal]

  val recv_ts : t -> Time_ns.t
  val stream : t -> Md_stream.t
end

(** The directory spelling of a symbol: [/], [\\] and space become [_]. *)
val symbol_dir : string -> string

(** The streams recorded for [venue] and [symbol] under [<data_dir>/raw], in
    {!Md_stream.compare} order. *)
val streams
  :  data_dir:string
  -> venue:Venue.t
  -> symbol:string
  -> Md_stream.t list Deferred.t

(** The minute files of one series whose minute overlaps [[start, stop)], in minute order
    (a compressed file before a plain one of the same minute). *)
val minute_files
  :  data_dir:string
  -> venue:Venue.t
  -> stream:Md_stream.t
  -> symbol:string
  -> start:Time_ns.t
  -> stop:Time_ns.t
  -> Raw_minute.File.t list Deferred.t

(** The items of [files] (one series, in order), keeping those whose [recv_ts] is in
    [range] (default: all). Unreadable files and lines that do not parse are passed to
    [on_error] (default: logged with [Log.Global.error_s]), tagged with the file path, and
    skipped. *)
val of_files
  :  ?on_error:(Error.t -> unit)
  -> ?range:Time_ns.t * Time_ns.t
  -> stream:Md_stream.t
  -> Raw_minute.File.t list
  -> Item.t Pipe.Reader.t

(** Every item of [venue] and [symbol] with [recv_ts] in [[start, stop)], streams
    ([streams], default every recorded one) merged by [recv_ts]; ties go to the stream
    earlier in the list. Closing the output stops reading. *)
val read
  :  ?on_error:(Error.t -> unit)
  -> ?streams:Md_stream.t list
  -> data_dir:string
  -> venue:Venue.t
  -> symbol:string
  -> start:Time_ns.t
  -> stop:Time_ns.t
  -> unit
  -> Item.t Pipe.Reader.t
