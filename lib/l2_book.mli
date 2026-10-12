(** An L2 order book rebuilt from {!L2_update}s: a snapshot replaces both sides, a delta
    sets the size of each listed price and a zero size removes it. *)

open! Core

type t [@@deriving sexp_of]

val empty : t

(** [false] until the first snapshot; deltas before it are applied but the book is
    incomplete. *)
val has_snapshot : t -> bool

val apply : t -> L2_update.t -> t

(** Best first: bids descending, asks ascending. [depth] limits each side. *)
val bids : ?depth:int -> t -> L2_update.Level.t list

val asks : ?depth:int -> t -> L2_update.Level.t list

(** [recv_ts] of the last update applied. *)
val last_update : t -> Time_ns.t option

(** One line per level, asks above bids, best prices nearest the middle:
    {v
      ask  100.2  4
      ask  100.1  2
      bid   99.9  1
    v} *)
val to_string_hum : ?depth:int -> t -> string
