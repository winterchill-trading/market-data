(** Periodic full L2 books kept beside an {!Event_log}, so a replay can start mid-day
    without reading the day from midnight.

    Entries live in [<root>/<venue>/<symbol>/norm/l2/_snapshots/<YYYY-MM-DD>.bin], framed
    like {!Event_log} with their own digest. {!Store.days} ignores the [_snapshots]
    directory. An entry at [at] holds the book after every L2 update received before [at]:
    replaying the entry, then the events with [recv_ts >= at], rebuilds the same book as
    replaying the whole day. *)

open! Core
open! Async

module Entry : sig
  module Stable : sig
    module V1 : sig
      type t =
        { at : Time_ns.Stable.V1.t (** an interval boundary *)
        ; book : L2_update.Stable.V1.t (** a [Snapshot] with [recv_ts = at] *)
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  type t = Stable.V1.t =
    { at : Time_ns.t
    ; book : L2_update.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

(** Hex [bin_shape] digest of {!Entry.Stable.V1.t}. *)
val digest : string

(** [<root>/<venue>/<symbol>/norm/l2/_snapshots/<YYYY-MM-DD>.bin] *)
val path : dir:string -> Instrument.t -> Date.t -> string

(** Decides when to take a snapshot, from the L2 updates of one instrument in [recv_ts]
    order. *)
module Builder : sig
  type t

  (** [interval] is the snapshot spacing, e.g. one minute; must be positive. *)
  val create : interval:Time_ns.Span.t -> t

  (** Feeds the next update. Returns the entry for the latest interval boundary crossed
      since the previous update, taken before applying this one; [None] when no boundary
      was crossed or the book has not seen a snapshot yet. *)
  val observe : t -> L2_update.t -> Entry.t option
end

(** Entries of one day, in file order. *)
val load : dir:string -> Instrument.t -> Date.t -> Entry.t list Deferred.t

(** The last entry with [at <= time] in the file of [time]'s day. *)
val find : dir:string -> Instrument.t -> Time_ns.t -> Entry.t option Deferred.t
