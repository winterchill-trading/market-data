(** An order book message: a full snapshot or a delta of changed price levels. In a delta
    a level with zero size removes that price. *)

open! Core

module Level : sig
  module Stable : sig
    module V1 : sig
      type t =
        { price : Price.Stable.V1.t
        ; size : Size.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal, quickcheck, fields]
    end
  end

  type t = Stable.V1.t =
    { price : Price.t
    ; size : Size.t
    }
  [@@deriving bin_io, sexp, compare, equal, fields]
end

module Kind : sig
  module Stable : sig
    module V1 : sig
      type t =
        | Snapshot
        | Delta
      [@@deriving bin_io, sexp, compare, equal, quickcheck, enumerate]
    end
  end

  type t = Stable.V1.t =
    | Snapshot
    | Delta
  [@@deriving bin_io, sexp, compare, equal, enumerate]
end

module Stable : sig
  module V1 : sig
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t
      ; recv_ts : Time_ns.Stable.V1.t
      ; kind : Kind.Stable.V1.t
      ; bids : Level.Stable.V1.t list (** best (highest) first in a snapshot *)
      ; asks : Level.Stable.V1.t list (** best (lowest) first in a snapshot *)
      }
    [@@deriving bin_io, sexp, compare, equal, quickcheck, fields]
  end
end

type t = Stable.V1.t =
  { instrument : Instrument.t
  ; exch_ts : Time_ns.t
  ; recv_ts : Time_ns.t
  ; kind : Kind.t
  ; bids : Level.t list
  ; asks : Level.t list
  }
[@@deriving bin_io, sexp, compare, equal, fields]
