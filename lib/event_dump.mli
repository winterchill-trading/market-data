(** Human-readable views of {!Event_log} files, behind [market-data dump]. *)

open! Core
open! Async

(** One line: UTC [recv_ts], instrument, stream, then the payload:
    {v
    2026-01-01T00:00:00.011000000Z binance:BTCUSDT trades buy 0.5 @ 100.1 id=10
    2026-01-01T00:00:00.002000000Z binance:BTCUSDT bbo 99.9 x 1 / 100.1 x 1
    2026-01-01T00:00:00.001000000Z binance:BTCUSDT l2 snapshot bids=[99.9 x 1] asks=[]
    v} *)
val line : Event.t -> string

(** Prints [line] of every event of [files], merged by [recv_ts]. *)
val print : string list -> unit Deferred.t

(** The books of every instrument with L2 updates in [files], after applying all updates
    with [recv_ts <= at], sorted by instrument. *)
val book_at : string list -> at:Time_ns.t -> (Instrument.t * L2_book.t) list Deferred.t
